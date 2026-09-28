//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Plain-text editor over real files: new / open / save through the standard
/// panels. Document state lives in the module so the section keeps the buffer
/// across open/close.
@MainActor
@Observable
final class EditorState {
    var text = ""
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    private(set) var lastError: String?

    func markEdited() { isDirty = true }

    func newDocument() {
        text = ""
        fileURL = nil
        isDirty = false
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .yaml, .xml, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            isDirty = false
            lastError = nil
        } catch {
            lastError = "open failed: \(error.localizedDescription)"
        }
    }

    func saveDocument() {
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsOtherFileTypes = true
            panel.nameFieldStringValue = "untitled.txt"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            isDirty = false
            lastError = nil
        } catch {
            lastError = "save failed: \(error.localizedDescription)"
        }
    }

    var displayName: String {
        fileURL?.lastPathComponent ?? "untitled"
    }
}

struct EditorAppView: View {
    @Environment(\.theme) private var theme
    @Bindable var state: EditorState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            TextEditor(text: $state.text)
                .font(.system(size: theme.baseSize, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: state.text) { _, _ in state.markEdited() }
            Divider().opacity(0.4)
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolbarButton("doc.badge.plus", "New") { state.newDocument() }
            toolbarButton("folder", "Open…") { state.openDocument() }
            toolbarButton("square.and.arrow.down", "Save") { state.saveDocument() }
            Spacer()
            HStack(spacing: 5) {
                if state.isDirty {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                }
                Text(state.displayName)
                    .font(theme.font(11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolbarButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var footer: some View {
        HStack {
            if let error = state.lastError {
                Text(error)
                    .font(theme.font(9))
                    .foregroundStyle(theme.errorColor)
            }
            Spacer()
            Text("\(state.text.count) chars · \(state.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

@MainActor
final class EditorAppModule: AppModule {
    let id = "editor"
    let name = "Editor"
    let icon = "square.and.pencil"
    private let state = EditorState()

    func makeView() -> AnyView {
        AnyView(EditorAppView(state: state))
    }

    func snapshot() async -> AppSnapshot {
        let head = String(state.text.prefix(2000))
        return AppSnapshot(summary: "Editor: \(state.displayName)\(state.isDirty ? " (unsaved)" : "")\n\(head)")
    }
}

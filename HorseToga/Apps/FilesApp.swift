//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

/// File manager: browses the real filesystem. Double-click opens folders here
/// and files in their default app. State lives in the module so the section
/// keeps its place across open/close.
@MainActor
@Observable
final class FilesState {
    private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    private(set) var entries: [FileEntry] = []
    var selection: URL?
    private(set) var error: String?

    struct FileEntry: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int?
        let modified: Date?
    }

    func loadIfNeeded() {
        if entries.isEmpty { load() }
    }

    func load() {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            entries = urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return FileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory ?? false,
                    size: values?.fileSize,
                    modified: values?.contentModificationDate
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            error = nil
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    func navigate(to url: URL) {
        directory = url.standardizedFileURL
        selection = nil
        load()
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent)
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            navigate(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }
}

struct FilesAppView: View {
    @Environment(\.theme) private var theme
    let state: FilesState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            if let error = state.error {
                SurfaceEmptyState(icon: "exclamationmark.triangle", message: error)
            } else if state.entries.isEmpty {
                SurfaceEmptyState(icon: "folder", message: "empty folder")
            } else {
                list
            }
            Divider().opacity(0.4)
            footer
        }
        .onAppear { state.loadIfNeeded() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { state.goUp() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Up one level")
            Text(displayPath)
                .font(theme.font(11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button { state.load() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.selection ?? state.directory])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.entries) { entry in
                    FileRow(entry: entry, isSelected: state.selection == entry.url)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { state.open(entry) }
                        .onTapGesture { state.selection = entry.url }
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.entries.count) items")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            if state.selection != nil {
                Text("double-click to open")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = state.directory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct FileRow: View {
    @Environment(\.theme) private var theme
    let entry: FilesState.FileEntry
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(theme.font(11))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let modified = entry.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
            Text(entry.isDirectory ? "—" : sizeLabel)
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                    ? AnyShapeStyle(theme.accent.opacity(0.14))
                    : hovering ? AnyShapeStyle(theme.textPrimary.opacity(0.04)) : AnyShapeStyle(Color.clear))
        )
        .onHover { hovering = $0 }
    }

    private var sizeLabel: String {
        guard let size = entry.size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

@MainActor
final class FilesAppModule: AppModule {
    let id = "files"
    let name = "Files"
    let icon = "folder"
    private let state = FilesState()

    func makeView() -> AnyView {
        AnyView(FilesAppView(state: state))
    }

    func snapshot() async -> AppSnapshot {
        let names = state.entries.prefix(60).map { $0.isDirectory ? $0.name + "/" : $0.name }
        return AppSnapshot(summary: "Files browsing \(state.directory.path):\n" + names.joined(separator: "\n"))
    }
}

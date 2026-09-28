//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

/// Chat history: every conversation the archive has seen, searchable and
/// grouped by recency on the left, full transcript on the right. Reopen drops
/// a chat back into the workspace as a live tile — with its session handle,
/// so stateful CLIs resume where they left off.
///
/// Holds selection + the actions the list can take, so the view's clicks and
/// the keymap's ⌘Y keyboard driving both go through one place.
@MainActor
@Observable
final class HistoryState {
    var query = ""
    var selectedID: ConversationID?
    var confirmingDelete = false

    private var archive: ConversationArchive { AppServices.shared.archive }

    /// The list as shown, newest first — the exact order arrow keys walk.
    var visibleRecords: [ConversationRecord] { archive.matching(query) }

    /// With no explicit pick, the first row stands in as selected — so ⌘Y lands
    /// on a chat and ⌘⌫ has a target before any arrow key is pressed.
    var selected: ConversationRecord? {
        let records = visibleRecords
        return records.first { $0.id == selectedID } ?? records.first
    }

    /// Walk selection by `delta` rows, clamped to the ends of the list.
    func move(_ delta: Int) {
        let records = visibleRecords
        guard !records.isEmpty else { return }
        let current = records.firstIndex { $0.id == selectedID } ?? 0
        selectedID = records[max(0, min(records.count - 1, current + delta))].id
    }

    // MARK: - Actions

    func reopen(_ record: ConversationRecord) {
        let store = AppServices.shared.workspaces
        if !store.reveal(record.id) {
            store.adopt(ConversationRunner(viewModel: record.makeViewModel()))
        }
        AppServices.shared.apps.closeSection()
    }

    func reopenSelected() {
        if let record = selected { reopen(record) }
    }

    /// The list's delete button: arm on the first press, remove on the second.
    func confirmDelete(_ record: ConversationRecord) {
        if confirmingDelete {
            remove(record)
        } else {
            confirmingDelete = true
        }
    }

    /// ⌘⌫ from the keyboard: delete straight away and slide selection to the
    /// neighbour so the user can keep pruning without reaching for the mouse.
    func deleteSelected() {
        if let record = selected { remove(record) }
    }

    private func remove(_ record: ConversationRecord) {
        let records = visibleRecords
        let index = records.firstIndex { $0.id == record.id }
        archive.delete(record.id)
        confirmingDelete = false
        if let index {
            // The row that shifts up into this slot is the next chat; past the
            // end, fall back to the new last row.
            let remaining = records.filter { $0.id != record.id }
            selectedID = (remaining.indices.contains(index) ? remaining[index] : remaining.last)?.id
        } else {
            selectedID = nil
        }
    }
}

struct HistoryAppView: View {
    @Environment(ConversationArchive.self) private var archive
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(\.theme) private var theme

    @Bindable var state: HistoryState
    /// Read-only view model rebuilt from the selected record; TranscriptView
    /// renders it exactly like a live tile would.
    @State private var preview: ConversationViewModel?
    /// Search takes focus on open so ⌘Y lands ready to type; arrows and ⌘⌫ are
    /// intercepted window-side, so they still steer the list from here.
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            detail
        }
        // Each ⌘Y opens fresh: selection snaps back to the first (most recent)
        // chat, search takes focus, so the whole list is keyboard-ready at once.
        .onAppear {
            state.selectedID = filtered.first?.id
            state.confirmingDelete = false
            searchFocused = true
            syncPreview()
        }
        .onChange(of: selected?.id) { state.confirmingDelete = false; syncPreview() }
        .onChange(of: selected?.updatedAt) { syncPreview() }
    }

    // MARK: - Data

    private var filtered: [ConversationRecord] { state.visibleRecords }

    private var selected: ConversationRecord? { state.selected }

    private var sections: [(title: String, records: [ConversationRecord])] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var buckets: [(String, [ConversationRecord])] = [("Today", []), ("Yesterday", []), ("This week", []), ("Earlier", [])]
        for record in filtered {
            let index: Int
            if calendar.isDateInToday(record.updatedAt) { index = 0 }
            else if calendar.isDateInYesterday(record.updatedAt) { index = 1 }
            else if record.updatedAt > weekAgo { index = 2 }
            else { index = 3 }
            buckets[index].1.append(record)
        }
        return buckets.filter { !$0.1.isEmpty }.map { (title: $0.0, records: $0.1) }
    }

    private func isLive(_ record: ConversationRecord) -> Bool {
        store.runner(for: record.id) != nil
    }

    private func providerName(_ record: ConversationRecord) -> String {
        providers.provider(record.providerID)?.displayName ?? record.providerID.description
    }

    private func syncPreview() {
        preview = selected?.makeViewModel()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(10)
            if filtered.isEmpty {
                SurfaceEmptyState(
                    icon: "clock.arrow.circlepath",
                    message: archive.records.isEmpty ? "no history yet — chats land here once you've talked" : "no matches"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(sections, id: \.title) { section in
                                Text(section.title.uppercased())
                                    .font(theme.font(9, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                ForEach(section.records) { record in
                                    HistoryRow(
                                        record: record,
                                        provider: providerName(record),
                                        isLive: isLive(record),
                                        isSelected: selected?.id == record.id
                                    ) { state.selectedID = record.id }
                                    .id(record.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    // Keep the keyboard-driven selection in view as it walks the list.
                    .onChange(of: selected?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 320)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            TextField("search history", text: $state.query)
                .textFieldStyle(.plain)
                .font(theme.font(11))
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Text("\(archive.records.count)")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.textPrimary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let record = selected, let preview {
            VStack(spacing: 0) {
                detailHeader(record)
                Divider().opacity(0.4)
                TranscriptView(viewModel: preview, fontSize: theme.baseSize - 0.5)
                    .id(record.id)
            }
        } else {
            SurfaceEmptyState(icon: "bubble.left.and.text.bubble.right", message: "select a chat")
        }
    }

    private func detailHeader(_ record: ConversationRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(theme.font(13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(meta(record))
                    .font(theme.font(10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if isLive(record) {
                Text("open")
                    .font(theme.font(9, weight: .medium))
                    .foregroundStyle(theme.successColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.successColor.opacity(0.12)))
            }
            Button { state.confirmDelete(record) } label: {
                Text(state.confirmingDelete ? "delete?" : "delete")
                    .font(theme.font(10, weight: .medium))
                    .foregroundStyle(state.confirmingDelete ? theme.errorColor : theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.textPrimary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Delete from history (⌘⌫)")
            Button { state.reopen(record) } label: {
                HStack(spacing: 5) {
                    Image(systemName: isLive(record) ? "arrow.up.forward.square" : "arrow.uturn.forward")
                        .font(.system(size: 9, weight: .bold))
                    Text(isLive(record) ? "show" : "reopen")
                        .font(theme.font(10, weight: .semibold))
                }
                .foregroundStyle(theme.backgroundColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .help(isLive(record) ? "Jump to its tile" : "Continue this chat in a new tile")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func meta(_ record: ConversationRecord) -> String {
        var parts = [
            providerName(record),
            "\(record.messageCount) messages",
            record.updatedAt.formatted(date: .abbreviated, time: .shortened),
        ]
        if let directory = record.workingDirectory {
            parts.append(directory.lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}

private struct HistoryRow: View {
    @Environment(\.theme) private var theme

    let record: ConversationRecord
    let provider: String
    let isLive: Bool
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(theme.successColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(record.title)
                        .font(theme.font(11, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(record.updatedAt.formatted(.relative(presentation: .named)))
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                }
                HStack(spacing: 6) {
                    Text(record.preview)
                        .font(theme.font(10))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(provider)
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(theme.textPrimary.opacity(0.06)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                        ? AnyShapeStyle(theme.accent.opacity(0.14))
                        : hovering ? AnyShapeStyle(theme.textPrimary.opacity(0.04)) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

final class HistoryAppModule: AppModule {
    let id = "history"
    let name = "History"
    let icon = "clock.arrow.circlepath"
    private let state = HistoryState()

    func makeView() -> AnyView {
        AnyView(HistoryAppView(state: state))
    }

    func snapshot() async -> AppSnapshot {
        let records = AppServices.shared.archive.records
        let lines = records.prefix(40).map {
            "\($0.updatedAt.formatted(date: .numeric, time: .shortened))  \($0.title) (\($0.messageCount) messages)"
        }
        return AppSnapshot(summary: "History: \(records.count) past chats\n" + lines.joined(separator: "\n"))
    }
}

extension HistoryAppModule: SectionKeyHandler {
    /// ⌘Y drives the whole list from the keyboard: arrows pick, ↩ reopens,
    /// ⌘⌫ deletes. These beat the focused search field because the window-level
    /// keymap sees them first.
    func handleSectionKey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        switch (modifiers, keyCode) {
        case ([], 126): state.move(-1); return true                   // ↑
        case ([], 125): state.move(1); return true                    // ↓
        case ([], 36), ([], 76): state.reopenSelected(); return true  // ↩ / keypad ↩
        case ([.command], 51): state.deleteSelected(); return true    // ⌘⌫
        default: return false
        }
    }
}

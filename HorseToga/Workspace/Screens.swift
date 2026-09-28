//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

// Screens persistence + the bottom-left screens dock. Home and every numbered
// screen auto-persist (tree, view mode, title, transcript snapshots) and come
// back at launch with their sessions alive. Nothing is ever "saved" by hand.

nonisolated struct ScreenRecord: Codable, Identifiable, Sendable {
    var id: Int // 0 = Home, 1...9
    var tree: TileTree
    var viewMode: WorkspaceViewMode
    var title: String
    var createdAt: Date
    /// Transcript snapshots of every session in the tree, so a screen restores
    /// even for chats the archive never kept (sessions nobody spoke to yet).
    var records: [ConversationRecord]? = []
}

nonisolated struct ScreensFile: Codable, Sendable {
    var version = 1
    var activeIndex = 0
    var screens: [ScreenRecord]
}

/// Pre-Screens on-disk shape (views.json, frozen "saved views"). Imported once.
private nonisolated struct LegacySavedView: Codable {
    var tree: TileTree
    var viewMode: WorkspaceViewMode
    var title: String
    var records: [ConversationRecord]?
}

extension ConversationRecord {
    /// Snapshot of a live conversation, empty transcripts included.
    @MainActor
    init(snapshotOf vm: ConversationViewModel) {
        self.init(
            id: vm.id,
            title: vm.title,
            providerID: vm.providerID,
            model: vm.model,
            handle: vm.handle,
            workingDirectory: vm.workingDirectory,
            createdAt: vm.createdAt,
            updatedAt: Date(),
            entries: vm.entries,
            usage: vm.usage
        )
    }
}

@MainActor
@Observable
final class ScreenStore {
    let fileURL: URL
    let legacyURL: URL
    /// Brief confirmation after ⌘S on a numbered screen (screens auto-save).
    var savedFlash = false

    private weak var store: WorkspaceStore?
    private var pendingWrite: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    nonisolated static var defaultDirectory: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/com.jasonchan.horsetoga")
    }

    init(directory: URL = ScreenStore.defaultDirectory) {
        fileURL = directory.appending(path: "screens.json")
        legacyURL = directory.appending(path: "views.json")
    }

    /// Wire continuous persistence: every store mutation schedules a write.
    func attach(to store: WorkspaceStore) {
        self.store = store
        store.onChange = { [weak self] in self?.scheduleWrite() }
    }

    /// Immediate synchronous write — durable even if the main actor is later
    /// blocked (e.g. a modal) before a debounced write can fire.
    func writeNow() { persist() }

    /// Restore at launch (or import the legacy views.json once), then attach.
    func load(into store: WorkspaceStore, archive: ConversationArchive) {
        self.store = store            // so persist() can run during migration, before attach
        defer { attach(to: store) }
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(ScreensFile.self, from: data) {
            for record in file.screens {
                guard let screen = store.screen(forSlot: record.id) else { continue }
                screen.title = record.title
                store.restore(
                    into: screen,
                    tree: record.tree,
                    viewMode: record.viewMode,
                    snapshots: record.records ?? [],
                    archive: archive
                )
            }
            store.switchTo(index: min(max(file.activeIndex, 0), store.screens.count - 1))
            return
        }
        migrateLegacy(into: store, archive: archive)
    }

    private func migrateLegacy(into store: WorkspaceStore, archive: ConversationArchive) {
        guard let data = try? Data(contentsOf: legacyURL),
              let views = try? JSONDecoder().decode([LegacySavedView].self, from: data)
        else { return }
        for (offset, view) in views.prefix(WorkspaceStore.maxNumberedScreens).enumerated() {
            guard let screen = store.screen(forSlot: offset + 1) else { continue }
            screen.title = view.title
            store.restore(
                into: screen,
                tree: view.tree,
                viewMode: view.viewMode,
                snapshots: view.records ?? [],
                archive: archive
            )
        }
        store.switchTo(index: 0)
        try? FileManager.default.moveItem(at: legacyURL, to: legacyURL.appendingPathExtension("migrated"))
        persist()   // durable immediately; migration only happens once
    }

    func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Synchronous write of anything still pending — call at quit.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        persist()
    }

    /// ⌘S on a numbered screen: nothing to do but say so.
    func flashSaved() {
        scheduleWrite()
        savedFlash = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.savedFlash = false
        }
    }

    /// Everything on disk comes from this: tree + mode + snapshots of every
    /// live session. Titles are derived here (first chat's title) and written
    /// back so the dock and palette stay current.
    func snapshot(from store: WorkspaceStore) -> ScreensFile {
        let screens = store.screens.map { screen -> ScreenRecord in
            let records = store.sessionIDs(in: screen.tree).compactMap { id in
                store.runner(for: id).map { ConversationRecord(snapshotOf: $0.viewModel) }
            }
            let title = records.first?.title
                ?? (screen.tree.isEmpty ? "" : "\(screen.tree.leafIDs.count) tiles")
            if screen.title != title { screen.title = title }
            return ScreenRecord(
                id: screen.id,
                tree: screen.tree,
                viewMode: screen.viewMode,
                title: title,
                createdAt: screen.createdAt,
                records: records
            )
        }
        return ScreensFile(activeIndex: store.activeIndex, screens: screens)
    }

    private func persist() {
        guard let store else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot(from: store)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Bottom-left capsule beside the app dock: ⌂ Home, one numbered tile per
/// screen, and "+" for a new one. Click to switch, right-click to close.
struct ScreensDock: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ScreenStore.self) private var screens
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            tile(isActive: store.active.isHome, help: "Home — ⌘0") {
                store.switchTo(slot: 0)
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 11, weight: .medium))
            }
            ForEach(store.numberedScreens) { screen in
                let isActive = store.active.id == screen.id
                tile(isActive: isActive, help: "\(screen.title.isEmpty ? "empty" : screen.title) — ⌘\(screen.id)") {
                    store.switchTo(slot: screen.id)
                } label: {
                    Text("\(screen.id)")
                        .font(theme.font(11, weight: .semibold))
                }
                .contextMenu {
                    Button("Close screen \(screen.id)", role: .destructive) {
                        store.closeScreen(screen.id)
                    }
                }
            }
            if store.nextFreeSlot != nil {
                tile(isActive: false, help: "New screen — ⌘N") {
                    store.newScreen()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.textPrimary.opacity(0.05)))
    }

    private func tile<Label: View>(
        isActive: Bool,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let color: AnyShapeStyle = isActive
            ? AnyShapeStyle(screens.savedFlash ? theme.successColor : theme.accent)
            : AnyShapeStyle(theme.textTertiary)
        return Button(action: action) {
            label()
                .foregroundStyle(color)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? theme.textPrimary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .dockTooltip(help, alignment: .topLeading)
    }
}

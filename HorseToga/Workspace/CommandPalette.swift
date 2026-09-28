//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// ⌘K command palette: fuzzy-search every command and shortcut in the app,
/// run the selected one with ↩. The keymap drives ↑/↓/↩/⎋ while it's open so
/// the search field keeps normal typing.
struct PaletteCommand {
    let title: String
    let key: String?
    let subtitle: String?
    let action: () -> Void

    init(_ title: String, key: String? = nil, subtitle: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.subtitle = subtitle
        self.action = action
    }
}

@MainActor
@Observable
final class CommandPaletteStore {
    private unowned let services: AppServices

    /// What the palette lists: every command, (⌘⇧↩) every past chat, an inline
    /// field for renaming the focused chat, an inline field for broadcasting one
    /// prompt to every open chat, or an inline field for comparing one prompt
    /// across a fresh chat per connected agent.
    enum Mode {
        case commands
        case history
        case rename
        case broadcast
        case compare
    }

    var visible = false
    var mode: Mode = .commands
    var query = "" {
        didSet { selectionIndex = 0 }
    }
    var selectionIndex = 0
    /// The chat being renamed while `mode == .rename`.
    private var renameTargetID: ConversationID?

    init(services: AppServices) {
        self.services = services
    }

    var filtered: [PaletteCommand] {
        let all = mode == .history ? buildHistory() : buildCommands()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(q)
                || ($0.key ?? "").lowercased().contains(q)
                || ($0.subtitle ?? "").lowercased().contains(q)
        }
    }

    var placeholder: String {
        switch mode {
        case .history: "Search past chats…"
        case .rename: "Rename this chat…"
        case .broadcast: "Type a prompt to send to all chats…"
        case .compare: "Type a prompt to compare across your connected agents…"
        case .commands: "Search commands…"
        }
    }

    var searchIcon: String {
        switch mode {
        case .rename: "pencil"
        case .broadcast: "paperplane"
        case .compare: "rectangle.split.2x2"
        case .commands, .history: "magnifyingglass"
        }
    }

    /// The footer hint shown while an inline-entry mode (rename / broadcast) is open.
    var inlineHint: String {
        switch mode {
        case .rename:
            return "Press ↩ to save · ⎋ to cancel"
        case .broadcast:
            let count = broadcastRunners.count
            return "Press ↩ to send to \(count) open \(count == 1 ? "chat" : "chats") · ⎋ to cancel"
        case .compare:
            let count = connectedProviderIDs.count
            return count == 0
                ? "No connected agents yet — sign in to an agent first · ⎋ to cancel"
                : "Press ↩ to compare across \(count) connected \(count == 1 ? "agent" : "agents") · ⎋ to cancel"
        case .commands, .history:
            return ""
        }
    }

    var emptyMessage: String {
        switch mode {
        case .history:
            services.archive.records.isEmpty ? "no history yet — chats land here once you've talked" : "no matching chats"
        case .commands:
            "no matching commands"
        case .rename, .broadcast, .compare:
            ""
        }
    }

    /// Providers you're set up for right now — a completed sign-in or a stored
    /// API key, and a runnable binary. The targets of a comparison.
    var connectedProviderIDs: [ProviderID] {
        services.providers.providers
            .map(\.id)
            .filter { services.providers.setupRequirement(for: $0, probing: false) == nil }
    }

    func toggle() {
        if visible { close() } else { open() }
    }

    func open() {
        mode = .commands
        query = ""
        selectionIndex = 0
        visible = true
    }

    /// ⌘⇧↩: the history picker — pull any past chat into the workspace.
    func openHistory() {
        mode = .history
        query = ""
        selectionIndex = 0
        visible = true
    }

    func close() {
        visible = false
    }

    func moveSelection(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectionIndex = (selectionIndex + delta + count) % count
    }

    func runSelected() {
        if mode == .rename {
            commitRename()
            return
        }
        if mode == .broadcast {
            commitBroadcast()
            return
        }
        if mode == .compare {
            commitCompare()
            return
        }
        let list = filtered
        guard list.indices.contains(selectionIndex) else {
            close()
            return
        }
        let command = list[selectionIndex]
        close()
        command.action()
    }

    /// The chat in the focused tile, if the focused tile is a session.
    var focusedSessionRunner: ConversationRunner? {
        let store = services.workspaces
        guard let focused = store.active.focused,
              case .session(let id)? = store.active.tree.surface(of: focused)
        else { return nil }
        return store.runner(for: id)
    }

    /// Switch the open palette into inline rename, prefilled with the title.
    func beginRename() {
        guard let runner = focusedSessionRunner else { return }
        renameTargetID = runner.viewModel.id
        mode = .rename
        query = runner.viewModel.title
        selectionIndex = 0
        visible = true
    }

    private func commitRename() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renameTargetID, !name.isEmpty,
           let runner = services.workspaces.runner(for: id) {
            runner.viewModel.title = name
            services.archive.save(runner.viewModel) // persist the new title
            services.workspaces.markDirty()
        }
        renameTargetID = nil
        close()
    }

    /// The live chats shown by the active screen — the targets of a broadcast.
    /// Every view mode projects the same tree, so this is "the open chats in the
    /// current view" regardless of tiles/canvas/inbox/tracker/rookery.
    var broadcastRunners: [ConversationRunner] {
        let store = services.workspaces
        return store.sessionIDs(in: store.active.tree).compactMap { store.runner(for: $0) }
    }

    /// Switch the open palette into broadcast entry: one prompt, sent to every
    /// open chat when the user hits ↩.
    func beginBroadcast() {
        mode = .broadcast
        query = ""
        selectionIndex = 0
        visible = true
    }

    private func commitBroadcast() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runners = broadcastRunners
        close()
        guard !text.isEmpty else { return }
        let providers = services.providers
        for runner in runners {
            guard let provider = providers.provider(runner.viewModel.providerID) ?? providers.defaultProvider
            else { continue }
            runner.send(text, via: provider) // no-ops on chats mid-stream, like the composer
        }
    }

    /// Switch the open palette into compare entry: one prompt, sent to a fresh
    /// chat per connected agent, all laid out equal-size on a new screen.
    func beginCompare() {
        mode = .compare
        query = ""
        selectionIndex = 0
        visible = true
    }

    private func commitCompare() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = connectedProviderIDs
        close()
        guard !text.isEmpty, !ids.isEmpty else { return }
        let providers = services.providers
        let runners = services.workspaces.openComparison(providerIDs: ids)
        for runner in runners {
            guard let provider = providers.provider(runner.viewModel.providerID) else { continue }
            runner.send(text, via: provider)
        }
    }

    /// Every keyboard shortcut, for the empty Home screen's reference list: all
    /// keyed commands from the catalog (which already includes the dock-app
    /// shortcuts), plus ⌘K itself and the numbered-screen jump. Derived from the
    /// real registry so it can never drift out of sync with the actual keymap.
    var homeShortcuts: [PaletteCommand] {
        let store = services.workspaces
        var rows = buildCommands().filter { $0.key != nil }
        rows.append(PaletteCommand("Command palette", key: "⌘K") { [weak self] in self?.toggle() })
        rows.append(PaletteCommand("Jump to screen 1–9", key: "⌘1–9") { store.switchTo(slot: 1) })
        return rows
    }

    /// The full catalog. Built on demand so it always reflects current apps,
    /// view modes, and workspaces.
    private func buildCommands() -> [PaletteCommand] {
        let store = services.workspaces
        let providers = services.providers
        let apps = services.apps
        let themes = services.themes
        let panel = services.panel
        let modelPicker = services.modelPicker

        var commands: [PaletteCommand] = [
            PaletteCommand("New session", key: "⌘↩") {
                store.newSession(providerID: providers.defaultProviderID)
            },
            PaletteCommand("New chat with a random agent", subtitle: "picks a random agent you're connected to") {
                // Opening the picker and resolving it happen in the same main-actor
                // tick, so no picker is ever drawn — the chat just lands on a random
                // connected agent.
                store.newSession(providerID: providers.defaultProviderID)
                modelPicker.selectRandomReady { providers.setupRequirement(for: $0) == nil }
            },
            PaletteCommand("Compare across agents", subtitle: "send one prompt to every connected agent, side by side") { [weak self] in
                self?.beginCompare()
            },
            PaletteCommand("Browse chat history", key: "⌘⇧↩") { [weak self] in
                self?.openHistory()
            },
        ]
        let openChats = broadcastRunners.count
        if openChats > 0 {
            commands.append(PaletteCommand(
                "Send to all chats",
                subtitle: "broadcast one prompt to \(openChats) open \(openChats == 1 ? "chat" : "chats") in this view"
            ) { [weak self] in
                self?.beginBroadcast()
            })
        }
        if let runner = focusedSessionRunner {
            commands.append(PaletteCommand(
                "Rename chat",
                subtitle: "rename “\(runner.viewModel.title)”"
            ) { [weak self] in
                self?.beginRename()
            })
        }
        commands += [
            PaletteCommand("Save Home as a screen", key: "⌘S") { store.promoteHome() },
            PaletteCommand("New screen", key: "⌘N") { store.newScreen() },
            PaletteCommand("Go to Home", key: "⌘0") { store.switchTo(slot: 0) },
            PaletteCommand("Next screen", key: "⌘]") { store.nextScreen() },
            PaletteCommand("Previous screen", key: "⌘[") { store.previousScreen() },
            PaletteCommand("Close screen", key: "⌘⇧W") { store.closeActiveScreen() },
            PaletteCommand("Split right", key: "⌘D") {
                store.newSession(providerID: providers.defaultProviderID, orientation: .horizontal)
            },
            PaletteCommand("Split down", key: "⌘⇧D") {
                store.newSession(providerID: providers.defaultProviderID, orientation: .vertical)
            },
            PaletteCommand("Close tile", key: "⌘W") { store.closeFocusedTile() },
            PaletteCommand("Zoom tile", key: "⌘⇧F") { store.toggleZoom() },
            PaletteCommand("Summon launcher", key: "⌥Space") { panel.toggle() },
            PaletteCommand("Theme switcher", key: "⌘T") { themes.toggleSwitcher() },
            PaletteCommand("Cycle view mode", key: "⌘⇧V") { store.cycleViewMode() },
            PaletteCommand("Cycle dock apps", key: "⌘⇧C") {
                apps.cycleSection(in: AppDockShortcut.allCases.map(\.appID))
            },
            PaletteCommand("Move focus", key: "⌘⌥←↑↓→") { store.moveFocus(.right) },
            PaletteCommand("Swap tiles", key: "⌃⌘←↑↓→") { store.swapFocused(.right) },
            PaletteCommand("Resize tile", key: "⌃⌥←↑↓→") { store.resizeFocused(.right) },
        ]
        let updater = services.updater
        commands.append(PaletteCommand("Check for updates") { updater.checkForUpdates() })
        for mode in WorkspaceViewMode.allCases {
            commands.append(PaletteCommand("View: \(mode.label)") { store.setViewMode(mode) })
        }
        for id in apps.modules.map({ $0.id }) {
            if let module = apps.module(id) {
                commands.append(PaletteCommand(
                    "Open \(module.name)",
                    key: AppDockShortcut.forApp(id)?.label
                ) { apps.toggleSection(id) })
            }
        }
        for screen in store.numberedScreens {
            let title = screen.title.isEmpty ? "empty" : screen.title
            commands.append(PaletteCommand("Screen \(screen.id): \(title)", key: "⌘\(screen.id)") {
                store.switchTo(slot: screen.id)
            })
        }
        return commands
    }

    /// Past chats, newest first. ↩ reveals the live tile if it's still open,
    /// otherwise reopens the record as a new tile (with its session handle).
    private func buildHistory() -> [PaletteCommand] {
        let store = services.workspaces
        let providers = services.providers
        return services.archive.records
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                let provider = providers.provider(record.providerID)?.displayName ?? record.providerID.description
                let isLive = store.runner(for: record.id) != nil
                return PaletteCommand(
                    record.title,
                    key: isLive ? "open" : record.updatedAt.formatted(.relative(presentation: .named)),
                    subtitle: "\(provider) · \(record.messageCount) messages · \(record.preview)"
                ) {
                    if !store.reveal(record.id) {
                        store.adopt(ConversationRunner(viewModel: record.makeViewModel()))
                    }
                }
            }
    }
}

struct CommandPaletteView: View {
    @Environment(CommandPaletteStore.self) private var palette
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var palette = palette
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: palette.searchIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                TextField(palette.placeholder, text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(theme.font(13))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .onSubmit { palette.runSelected() }
                Text("esc")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().opacity(0.4)
            if palette.mode == .rename || palette.mode == .broadcast || palette.mode == .compare {
                Text(palette.inlineHint)
                    .font(theme.font(11))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else if palette.filtered.isEmpty {
                Text(palette.emptyMessage)
                    .font(theme.font(11))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.filtered.enumerated()), id: \.offset) { index, command in
                                row(command, isSelected: index == palette.selectionIndex)
                                    .id(index)
                                    .onTapGesture {
                                        palette.selectionIndex = index
                                        palette.runSelected()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: palette.selectionIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }
        }
        .frame(width: 460)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 110)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(theme.font(11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let key = command.key {
                Text(key)
                    .font(theme.font(10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(theme.accent.opacity(0.14)) : AnyShapeStyle(Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

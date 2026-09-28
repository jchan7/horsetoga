//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Composition root. Everything long-lived hangs off this, and every SwiftUI root
/// (panel, workspace window, settings) receives it through the ONE `injectAppEnvironment`
/// below so surfaces can never diverge in what they see.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let hotKeys = CarbonHotKeyCenter()
    let providers = ProviderRegistry()
    let workspaces = WorkspaceStore()
    let usage = UsageStore()
    let apps = AppRegistry()
    let themes = ThemeStore()
    let modelPicker = ModelPickerStore()
    let archive = ConversationArchive()
    let updater = Updater()
    let providerSetup = ProviderSetupCoordinator()
    private(set) lazy var workspaceWindow = WorkspaceWindowController(services: self)
    private(set) lazy var panel = PanelController(services: self)
    private(set) lazy var commandPalette = CommandPaletteStore(services: self)
    private(set) lazy var accountSignIn = AccountSignIn()
    let screens = ScreenStore()

    private init() {}

    func start() {
        themes.start()
        archive.load()
        workspaces.onNewSession = { [weak self] runner in
            guard let self else { return }
            let recentModels = archive.records.map {
                RecentModelSelection(providerID: $0.providerID, model: $0.model)
            }
            modelPicker.openForNewChat(
                for: runner.viewModel,
                providers: providers,
                archiveSelections: recentModels
            )
        }
        modelPicker.onSelection = { [weak self] providerID in
            self?.providerSetup.request(providerID)
        }
        // Title changes and finished runs persist the screen layout too.
        ConversationRunner.persist = { [archive, screens] vm in
            archive.save(vm)
            screens.scheduleWrite()
        }
        screens.load(into: workspaces, archive: archive)
        updater.start()
        apps.register(UsageAppModule())
        apps.register(FilesAppModule())
        apps.register(HistoryAppModule())
        apps.register(ProvidersAppModule())
        panel.onSubmit = { [weak self] text in
            self?.panelSubmit(text)
        }
        panel.onExpand = { [weak self] in
            self?.panelExpand()
        }
        do {
            try hotKeys.register(.defaultSummon) { [weak self] in
                self?.panel.toggle()
            }
        } catch {
            NSLog("HorseToga: hotkey registration failed: \(error)")
        }
        Task { await providers.refreshHealth() }
    }

    private func panelSubmit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // An existing panel session keeps talking to ITS agent, not the default.
        let sessionProvider = (panel.state.session?.viewModel.providerID).flatMap { providers.provider($0) }
        guard let provider = sessionProvider ?? providers.defaultProvider else { return }
        if panel.state.session == nil {
            panel.state.session = ConversationRunner(
                viewModel: ConversationViewModel(providerID: provider.id)
            )
        }
        panel.state.session?.send(text, via: provider)
        panel.state.text = ""
    }

    /// ⌘↩ in the panel: the running session moves into a workspace tile
    /// mid-stream. Unsent input goes with it and sends from the tile.
    private func panelExpand() {
        let pendingText = panel.state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if panel.state.session == nil, !pendingText.isEmpty {
            panelSubmit(pendingText)
        }
        workspaceWindow.show()
        if let session = panel.state.session {
            workspaces.adopt(session)
            panel.state.session = nil
        }
        panel.hide()
    }

    func shutdown() {
        // Last snapshot of everything still live, then make sure it hits disk.
        for runner in workspaces.runners.values { archive.save(runner.viewModel) }
        if let session = panel.state.session { archive.save(session.viewModel) }
        screens.flush()
        archive.flush()
        ProcessRegistry.shared.killAll()
    }
}

extension View {
    /// Single choke point for app-wide environment. Panel and window both call this;
    /// a store injected here is visible to every surface, or to none.
    @MainActor
    func injectAppEnvironment(_ services: AppServices) -> some View {
        ThemedRoot { self }
            .environment(services.workspaces)
            .environment(services.providers)
            .environment(services.usage)
            .environment(services.apps)
            .environment(services.themes)
            .environment(services.modelPicker)
            .environment(services.archive)
            .environment(services.updater)
            .environment(services.commandPalette)
            .environment(services.accountSignIn)
            .environment(services.providerSetup)
            .environment(services.screens)
    }
}

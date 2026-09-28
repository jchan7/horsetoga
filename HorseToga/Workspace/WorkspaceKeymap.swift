//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit

/// Single source of truth for the bottom app dock's shortcuts and hover labels.
nonisolated enum AppDockShortcut: CaseIterable {
    case usage
    case files
    case history
    case providers

    var appID: String {
        switch self {
        case .usage: "usage"
        case .files: "files"
        case .history: "history"
        case .providers: "providers"
        }
    }

    var label: String {
        switch self {
        case .usage: "⌘U"
        case .files: "⌘⇧E"
        case .history: "⌘Y"
        case .providers: "⌘⇧P"
        }
    }

    private var keyCode: UInt16 {
        switch self {
        case .usage: 32     // U
        case .files: 14     // E
        case .history: 16   // Y
        case .providers: 35 // P
        }
    }

    private var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .usage, .history: [.command]
        case .files, .providers: [.command, .shift]
        }
    }

    func matches(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
        self.modifiers == modifiers && self.keyCode == keyCode
    }

    static func forApp(_ id: String) -> Self? {
        allCases.first { $0.appID == id }
    }
}

/// Hardcoded v1 tiling keybinds; migrates into the rebindable ShortcutBindings
/// registry (task: commands + shortcuts). Kept as one table so the migration is
/// mechanical.
@MainActor
enum WorkspaceKeymap {

    /// Digit row keycodes 1...9.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private static func arrowDirection(_ keyCode: UInt16) -> MoveDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 126: .up
        case 125: .down
        default: nil
        }
    }

    /// Returns true if the event was consumed.
    static func handle(_ event: NSEvent, store: WorkspaceStore, services: AppServices) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.keyCode

        // New chats open this automatically. Keep every selection action at the
        // window level so it works even before the prompt field has appeared.
        let modelPicker = services.modelPicker
        if modelPicker.visible {
            switch (mods, key) {
            case ([], 126): modelPicker.moveSelection(-1); return true // ↑
            case ([], 125): modelPicker.moveSelection(1); return true  // ↓
            case ([], 48): modelPicker.moveSelection(1); return true   // tab
            case ([.shift], 48): modelPicker.moveSelection(-1); return true // ⇧tab
            case ([], 36), ([], 76): modelPicker.select(); return true // ↩ / keypad ↩
            case ([], 53): modelPicker.close(); return true            // ⎋
            case ([], 15): // r → a random option you're connected to
                modelPicker.selectRandomReady { services.providers.setupRequirement(for: $0) == nil }
                return true
            default:
                if mods.isEmpty, let digit = digitKeyCodes[key] {
                    modelPicker.select(at: digit - 1)
                }
                return true // modal: never type or run commands behind it
            }
        }

        // Theme switcher owns the keyboard while visible.
        let themes = services.themes
        if themes.switcherVisible {
            switch (mods, key) {
            case ([], 126): themes.switcherMove(-1); return true // ↑
            case ([], 125): themes.switcherMove(1); return true  // ↓
            case ([], 36): themes.commitSwitcher(); return true  // ↩
            case ([], 53): themes.revertSwitcher(); return true  // ⎋
            case ([.command], 17): themes.revertSwitcher(); return true // ⌘T again
            default: return true // swallow everything else while open
            }
        }

        // Command palette (⌘K): arrows/enter/esc are ours; typing reaches the
        // search field; other ⌘-shortcuts are swallowed so they can't fire
        // behind the palette (except clipboard editing keys).
        let palette = services.commandPalette
        if palette.visible {
            switch (mods, key) {
            case ([], 126): palette.moveSelection(-1); return true // ↑
            case ([], 125): palette.moveSelection(1); return true  // ↓
            case ([], 36): palette.runSelected(); return true      // ↩
            case ([], 53): palette.close(); return true            // ⎋
            case ([.command], 40): palette.close(); return true    // ⌘K again
            default:
                if mods.contains(.command), ![0, 7, 8, 9].contains(Int(key)) { // allow ⌘A/X/C/V
                    return true
                }
                return false
            }
        }

        // An open app section (dock app) owns dismissal keys, then gets first
        // crack at everything else — before any focused view inside it — so an
        // app can drive itself entirely from the keyboard.
        if let sectionID = services.apps.activeSectionID {
            if mods.isEmpty, key == 53 { // ⎋
                services.apps.closeSection()
                return true
            }
            if mods == [.command], key == 13 { // ⌘W closes the section, not a tile
                services.apps.closeSection()
                return true
            }
            if let handler = services.apps.module(sectionID) as? SectionKeyHandler,
               handler.handleSectionKey(modifiers: mods, keyCode: key) {
                return true
            }
        }

        // Inbox / tracker: ⇧⇥ hands the keyboard to the list/board, arrows walk
        // it, and ⇥ / ↩ drop back into the open chat's composer.
        let browseMode = store.active.viewMode
        if browseMode == .inbox || browseMode == .tracker {
            switch (mods, key) {
            case ([.shift], 48): // ⇧⇥ → browse the list/board
                store.browseFocused = true
                return true
            case ([], 48), ([], 36), ([], 76): // ⇥ / ↩ → back to the chat
                if store.browseFocused { store.browseFocused = false; return true }
            case ([], 123), ([], 124), ([], 125), ([], 126): // arrows
                if store.browseFocused, let direction = arrowDirection(key) {
                    if browseMode == .inbox {
                        if direction == .up { store.moveInboxSelection(-1) }
                        else if direction == .down { store.moveInboxSelection(1) }
                    } else {
                        store.moveTrackerSelection(direction)
                    }
                    return true
                }
            default:
                break
            }
        }

        if mods == [.command, .shift], key == 8 { // ⌘⇧C cycles dock apps
            services.apps.cycleSection(in: AppDockShortcut.allCases.map(\.appID))
            return true
        }

        if let shortcut = AppDockShortcut.allCases.first(where: {
            $0.matches(modifiers: mods, keyCode: key)
        }) {
            services.apps.toggleSection(shortcut.appID)
            return true
        }

        switch (mods, key) {
        case ([.command], 17): // ⌘T theme switcher
            themes.toggleSwitcher()
            return true

        case ([.command, .shift], 36): // ⌘⇧↩ history picker
            palette.openHistory()
            return true

        case ([.command], 36): // ⌘↩ new session
            store.newSession(providerID: services.providers.defaultProviderID)
            return true

        case ([.command], 2): // ⌘D split right
            store.newSession(providerID: services.providers.defaultProviderID, orientation: .horizontal)
            return true

        case ([.command, .shift], 2): // ⌘⇧D split down
            store.newSession(providerID: services.providers.defaultProviderID, orientation: .vertical)
            return true

        case ([.command], 13): // ⌘W close tile; an empty numbered screen closes itself;
            // an empty Home falls through so the window closes.
            guard !store.active.tree.isEmpty || !store.active.isHome else { return false }
            store.closeFocusedTile()
            return true

        case ([.command, .shift], 13): // ⌘⇧W close the current screen
            store.closeActiveScreen()
            return true

        case ([.command, .shift], 3): // ⌘⇧F zoom
            store.toggleZoom()
            return true

        case ([.command, .shift], 9): // ⌘⇧V cycle view mode
            store.cycleViewMode()
            return true

        case ([.command], 40): // ⌘K command palette
            palette.toggle()
            return true

        case ([.command], 1): // ⌘S: on Home, promote into a numbered screen; elsewhere confirm
            if store.active.isHome {
                store.promoteHome()
            } else {
                services.screens.flashSaved()
            }
            return true

        case ([.command], 45): // ⌘N new screen
            store.newScreen()
            return true

        case ([.command], 29): // ⌘0 Home
            store.switchTo(slot: 0)
            return true

        case ([.command], 33): // ⌘[ previous screen
            store.previousScreen()
            return true

        case ([.command], 30): // ⌘] next screen
            store.nextScreen()
            return true

        default:
            break
        }

        if let direction = arrowDirection(key) {
            switch mods {
            case [.command, .option]:
                store.moveFocus(direction)
                return true
            case [.command, .control]:
                store.swapFocused(direction)
                return true
            case [.control, .option]:
                store.resizeFocused(direction)
                return true
            default:
                break
            }
        }

        if mods == .command, let digit = digitKeyCodes[key] { // ⌘1…9 go to screen
            store.switchTo(slot: digit)
            return true
        }

        return false
    }
}

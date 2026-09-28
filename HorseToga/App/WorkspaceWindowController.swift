//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

/// The "OS" window. AppKit-owned (not a SwiftUI scene) so the panel and hotkeys can
/// summon it programmatically without scene plumbing.
@MainActor
final class WorkspaceWindowController {
    private weak var services: AppServices?
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(services: AppServices) {
        self.services = services
    }

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        installKeyMonitorIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Tiling keybinds are intercepted at the window level so they win over any
    /// focused text view inside a tile.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let services = self.services,
                  event.window === self.window else { return event }
            return WorkspaceKeymap.handle(event, store: services.workspaces, services: services)
                ? nil
                : event
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.title = "HorseToga"
        win.minSize = NSSize(width: 720, height: 480)
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("HorseTogaWorkspace")
        if let services {
            win.contentView = NSHostingView(
                rootView: WorkspaceRootView().injectAppEnvironment(services)
            )
        }
        return win
    }
}

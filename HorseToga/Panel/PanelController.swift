//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

@Observable
@MainActor
final class PanelState {
    var text = ""
    /// The panel's live session. Survives dismiss/summon; migrates into a workspace
    /// tile on expand (task: sessions-in-tiles).
    var session: ConversationRunner?
}

/// Owns the CommandPanel: summon/dismiss, multi-monitor positioning, focus handoff,
/// and top-anchored growth as SwiftUI content changes height.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelWidth: CGFloat = 680
    private static let initialHeight: CGFloat = 68

    private let panel: CommandPanel
    private unowned let services: AppServices
    let focus = PanelFocus()
    let state = PanelState()
    var onSubmit: ((String) -> Void)?
    var onExpand: (() -> Void)?

    /// Screen Y of the panel's top edge, fixed at summon so growth extends downward.
    private var topAnchorY: CGFloat = 0

    init(services: AppServices) {
        self.services = services
        self.panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.initialHeight)
        )
        super.init()
        panel.delegate = self
        let root = PanelRootView(controller: self, state: state, focus: focus)
            .injectAppEnvironment(services)
        panel.contentView = NSHostingView(rootView: root)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        state.text = ""
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(focus.textView)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Called from SwiftUI (onGeometryChange) as content height changes.
    func setContentHeight(_ height: CGFloat) {
        guard panel.isVisible else { return }
        let h = max(height, Self.initialHeight)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = topAnchorY - h
        frame.size.height = h
        panel.setFrame(frame, display: true)
    }

    private func position() {
        // The screen under the mouse, NOT NSScreen.main (that's the key window's screen).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = panel.frame.height
        topAnchorY = visible.maxY - visible.height * 0.18
        let frame = NSRect(
            x: visible.midX - Self.panelWidth / 2,
            y: topAnchorY - height,
            width: Self.panelWidth,
            height: height
        )
        panel.setFrame(frame, display: false)
    }

    // Click anywhere else (panel loses key) dismisses, Raycast-style.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

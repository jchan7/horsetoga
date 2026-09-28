//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit

/// The launcher surface. Non-activating: it becomes KEY (accepts typing) while the
/// previous app stays ACTIVE and frontmost, so dismissing needs no focus restoration.
final class CommandPanel: NSPanel {
    // Titleless windows refuse key status by default; this override is load-bearing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false        // NSPanel defaults true; the panel would vanish
        isReleasedWhenClosed = false     // defaults true for code-created windows: UAF on re-show
        becomesKeyOnlyIfNeeded = false   // we drive key status explicitly on summon
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        worksWhenModal = true
    }

    /// In a non-active app the main menu doesn't own key equivalents, so ⌘C/V/X/A/Z
    /// die unless routed by hand through the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            let selector: Selector? = switch event.charactersIgnoringModifiers {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        } else if mods == [.command, .shift], event.charactersIgnoringModifiers == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

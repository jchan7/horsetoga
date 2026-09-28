//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

// HorseToga apps are first-class tile surfaces with an AI-VISIBILITY CONTRACT:
// every app can describe its current state to a model (snapshot) and expose
// typed actions (tools). Sessions consume snapshots as context; CLI agents will
// reach tools through the MCP bridge. This is what makes "use HorseToga's browser
// instead of Safari" mean something: the model sees structure, not pixels.

nonisolated struct AppSnapshot: Sendable {
    /// Human/model-readable description of current state (page text, note body, ...).
    var summary: String
    /// Optional structured form.
    var json: String?
}

nonisolated struct AppTool: Sendable {
    var name: String
    var description: String
    /// JSON Schema for the input object.
    var inputSchemaJSON: String
    var run: @Sendable ([String: String]) async throws -> String
}

@MainActor
protocol AppModule: AnyObject {
    var id: String { get }
    var name: String { get }
    /// SF Symbol name for tile chrome and pickers.
    var icon: String { get }
    func makeView() -> AnyView
    func snapshot() async -> AppSnapshot
    var tools: [AppTool] { get }
}

extension AppModule {
    var tools: [AppTool] { [] }
    func snapshot() async -> AppSnapshot {
        AppSnapshot(summary: "\(name): no state exposed")
    }
}

/// An open app section can claim keyboard events before they reach any focused
/// view inside it — arrow-key selection, ⌘⌫ to delete, ↩ to act on the choice.
/// The workspace keymap offers events here first (after the global ⎋ / ⌘W
/// dismissal keys) while this app is the frontmost section.
@MainActor
protocol SectionKeyHandler: AnyObject {
    /// `modifiers` is already masked to ⌘⌥⇧⌃. Return true to consume the event.
    func handleSectionKey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool
}

@MainActor
@Observable
final class AppRegistry {
    private(set) var modules: [any AppModule] = []

    /// The app whose full-window section is open (dock click / ⌘U). Sections sit
    /// above the workspace and below the bottom bar; one at a time, like a
    /// frontmost app on the macOS desktop.
    var activeSectionID: String?

    func register(_ module: any AppModule) {
        guard self.module(module.id) == nil else { return }
        modules.append(module)
    }

    func module(_ id: String) -> (any AppModule)? {
        modules.first { $0.id == id }
    }

    func toggleSection(_ id: String) {
        activeSectionID = activeSectionID == id ? nil : id
    }

    func openSection(_ id: String) {
        guard module(id) != nil else { return }
        activeSectionID = id
    }

    func closeSection() {
        activeSectionID = nil
    }

    /// Move to the next registered app in a caller-defined dock order.
    /// With no dock app open, cycling starts at the first item.
    func cycleSection(in orderedIDs: [String]) {
        let available = orderedIDs.filter { module($0) != nil }
        guard !available.isEmpty else { return }
        guard let activeSectionID,
              let index = available.firstIndex(of: activeSectionID)
        else {
            self.activeSectionID = available[0]
            return
        }
        self.activeSectionID = available[(index + 1) % available.count]
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Testing
@testable import HorseToga

@Suite("Screens")
@MainActor
struct ScreensTests {
    private func storeWithHomeSessions(_ count: Int) -> WorkspaceStore {
        let store = WorkspaceStore()
        for _ in 0..<count { store.newSession(providerID: .claudeCLI) }
        return store
    }

    @Test("⌘S on Home promotes its layout into screen 1 and empties Home")
    func promoteFromHome() {
        let store = storeWithHomeSessions(2)
        let screen = store.promoteHome()
        #expect(screen?.id == 1)
        #expect(store.home.tree.isEmpty)
        #expect(store.active.id == 1)
        #expect(store.active.tree.leafIDs.count == 2)
        #expect(store.runners.count == 2) // nothing released: streams keep going
    }

    @Test("every new-session path requests the model picker")
    func newSessionRequestsModelPicker() {
        let store = WorkspaceStore()
        var requestedID: ConversationID?
        store.onNewSession = { requestedID = $0.viewModel.id }

        let runner = store.newSession(providerID: .claudeCLI)

        #expect(requestedID == runner.viewModel.id)
    }

    @Test("promote is a no-op on an empty Home and on numbered screens")
    func promoteNoOps() {
        let empty = WorkspaceStore()
        #expect(empty.promoteHome() == nil)
        let store = storeWithHomeSessions(1)
        store.promoteHome()
        store.newSession(providerID: .claudeCLI) // on screen 1
        #expect(store.promoteHome() == nil)
        #expect(store.screens.count == 2)
    }

    @Test("new screens take the next free slot; nil after nine")
    func newScreenTakesNextFreeSlot() {
        let store = WorkspaceStore()
        #expect(store.newScreen()?.id == 1)
        #expect(store.newScreen()?.id == 2)
        store.closeScreen(1)
        #expect(store.newScreen()?.id == 1)
        for _ in 0..<7 { store.newScreen() }
        #expect(store.numberedScreens.count == 9)
        #expect(store.newScreen() == nil)
        #expect(store.nextFreeSlot == nil)
    }

    @Test("closing screens keeps activeIndex valid and releases hidden sessions")
    func closeScreenKeepsActiveIndexValid() {
        let store = WorkspaceStore()
        store.newScreen() // 1
        store.newScreen() // 2
        store.newSession(providerID: .claudeCLI) // lives on 2
        let shared = store.newSession(providerID: .claudeCLI)
        store.newScreen() // 3, active
        store.adopt(shared) // also visible on 3
        #expect(store.active.id == 3)
        store.closeActiveScreen()
        #expect(store.active.id == 2)
        #expect(store.runners.count == 2) // shared survives: still shown on 2
        store.closeScreen(2)
        #expect(store.active.id == 1)
        #expect(store.runners.isEmpty) // both hidden everywhere now
        store.closeScreen(0)
        #expect(store.screens.first?.isHome == true) // Home can't close
    }

    @Test("⌘W on an empty numbered screen closes the screen")
    func emptyNumberedScreenClosesOnCloseTile() {
        let store = storeWithHomeSessions(1)
        store.promoteHome()
        store.closeFocusedTile() // last tile
        #expect(store.active.id == 1)
        #expect(store.active.tree.isEmpty)
        store.closeFocusedTile() // empty screen closes
        #expect(store.active.isHome)
        #expect(store.numberedScreens.isEmpty)
        store.closeFocusedTile() // Home stays put
        #expect(store.screens.count == 1)
    }

    @Test("⌘] and ⌘[ wrap around")
    func navigationWraps() {
        let store = WorkspaceStore()
        store.newScreen()
        store.newScreen()
        store.switchTo(slot: 0)
        store.nextScreen()
        #expect(store.active.id == 1)
        store.nextScreen()
        store.nextScreen()
        #expect(store.active.isHome)
        store.previousScreen()
        #expect(store.active.id == 2)
    }

    @Test("screens file round-trips with snapshots")
    func screensFileRoundTrip() throws {
        let store = storeWithHomeSessions(2)
        store.promoteHome()
        let screens = ScreenStore(directory: FileManager.default.temporaryDirectory)
        let file = screens.snapshot(from: store)
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ScreensFile.self, from: data)
        #expect(decoded.activeIndex == 1)
        #expect(decoded.screens.map(\.id) == [0, 1])
        #expect(decoded.screens[1].tree.leafIDs.count == 2)
        #expect(decoded.screens[1].records?.count == 2)
    }

    @Test("restore revives sessions from snapshots and drops unknown leaves")
    func restoreRevivesFromSnapshot() {
        let store = WorkspaceStore()
        let vm = ConversationViewModel(providerID: .claudeCLI)
        vm.entries = [TranscriptEntry(kind: .user("hi"))]
        let record = ConversationRecord(snapshotOf: vm)
        var tree = TileTree()
        tree.insert(.session(record.id), splitting: nil, bounds: store.layoutBounds)
        tree.insert(.session(ConversationID()), splitting: nil, bounds: store.layoutBounds)
        store.restore(into: store.home, tree: tree, viewMode: .inbox, snapshots: [record], archive: ConversationArchive())
        #expect(store.home.tree.leafIDs.count == 1)
        #expect(store.runner(for: record.id)?.viewModel.entries.count == 1)
        #expect(store.home.viewMode == .inbox)
    }

    @Test("legacy views.json is imported once as numbered screens")
    func legacyMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "horsetoga-screens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore()
        var tree = TileTree()
        tree.insert(.app("usage"), splitting: nil, bounds: store.layoutBounds)
        let treeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tree))
        let legacy: [[String: Any]] = [["tree": treeJSON, "viewMode": "tiles", "title": "Legacy", "records": []]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: dir.appending(path: "views.json"))

        let screens = ScreenStore(directory: dir)
        screens.load(into: store, archive: ConversationArchive())
        #expect(store.numberedScreens.map(\.id) == [1])
        #expect(store.screens[1].title == "Legacy")
        #expect(store.screens[1].tree.leafIDs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "views.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "views.json.migrated").path))
    }
}

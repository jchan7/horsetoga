//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation

/// How a screen presents its tiles. Every mode is a projection of the SAME
/// tile tree — switching modes never touches sessions, only how they render.
nonisolated enum WorkspaceViewMode: String, CaseIterable, Codable, Sendable {
    case tiles
    case inbox
    case tracker
    case canvas
    case rookery

    var label: String {
        switch self {
        case .tiles: "Tiles"
        case .canvas: "Canvas"
        case .inbox: "Inbox"
        case .tracker: "Tracker"
        case .rookery: "Rookery"
        }
    }

    var icon: String {
        switch self {
        case .tiles: "square.split.2x2"
        case .canvas: "square.on.square.dashed"
        case .inbox: "tray.full"
        case .tracker: "list.bullet.rectangle"
        case .rookery: "snowflake"
        }
    }
}

/// One screen: Home (id 0, the scratch space you always return to) or a
/// numbered screen (1…9). A tile tree + focus + zoom state + view mode.
@MainActor
@Observable
final class WorkspaceModel: Identifiable {
    let id: Int // 0 = Home, 1...9 numbered
    var tree: TileTree
    var focused: TileID?
    /// Temporarily maximized tile (⌘⇧F). Layout is preserved underneath.
    var zoomed: TileID?
    var viewMode: WorkspaceViewMode
    /// Auto-derived from the first chat; shown in the dock tooltip and palette.
    var title: String
    let createdAt: Date

    var isHome: Bool { id == 0 }

    init(
        id: Int,
        tree: TileTree = TileTree(),
        viewMode: WorkspaceViewMode = .tiles,
        title: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tree = tree
        self.viewMode = viewMode
        self.title = title
        self.createdAt = createdAt
    }

    /// Leaves in stable tree order, paired with their surfaces — the shared
    /// enumeration every non-tiles view renders from.
    var surfaceItems: [(id: TileID, surface: SurfaceKind)] {
        tree.leafIDs.compactMap { id in
            tree.surface(of: id).map { (id, $0) }
        }
    }
}

/// Home + numbered screens + the session registry. Sessions are OWNED here,
/// not by tiles: a tile is just a view onto a ConversationRunner, which is what
/// lets streams survive tile moves, screen switches, and panel handoff.
/// Switching screens never releases anything; only closing does.
@MainActor
@Observable
final class WorkspaceStore {
    static let maxNumberedScreens = 9

    /// Always sorted by id; screens[0] is Home.
    private(set) var screens: [WorkspaceModel]
    // NOTE: no clamping didSet here — under @Observable the property is computed,
    // so a self-assignment in didSet recurses forever (stack overflow). `active`
    // clamps on read and switchTo(index:) validates instead.
    var activeIndex = 0
    private(set) var runners: [ConversationID: ConversationRunner] = [:]

    /// Reference layout bounds for orientation decisions and neighbor queries.
    /// Updated by the view layer on resize.
    var layoutBounds = CGRect(x: 0, y: 0, width: 1240, height: 780)

    /// Auto-persist hook (installed by ScreenStore): fires after every layout
    /// mutation so screens are saved continuously, never explicitly.
    var onChange: (() -> Void)?
    /// App-level presentation hook. Keeping it here means every new-session path
    /// (shortcut, palette, empty state, inbox, split) gets the same model picker.
    var onNewSession: ((ConversationRunner) -> Void)?

    /// Freeform positions of tiles on the Canvas view, in canvas coordinates.
    /// Kept per session so dragging a chat sticks while you pan and zoom around.
    var canvasPositions: [TileID: CGPoint] = [:]

    /// Master-detail views (inbox, tracker): true when the list/board owns the
    /// keyboard (⇧⇥ to enter it, arrows to move), false when the open chat's
    /// composer does (⇥ / ↩ to return). Reset on mode/session changes so it never
    /// lingers into tiles.
    var browseFocused = false

    init() {
        screens = [WorkspaceModel(id: 0)]
    }

    var active: WorkspaceModel {
        screens[min(max(activeIndex, 0), screens.count - 1)]
    }

    var home: WorkspaceModel { screens[0] }

    var numberedScreens: [WorkspaceModel] { screens.filter { !$0.isHome } }

    func runner(for id: ConversationID) -> ConversationRunner? {
        runners[id]
    }

    func markDirty() {
        onChange?()
    }

    // MARK: - Session lifecycle

    /// New session tile in the active screen, splitting the focused tile.
    @discardableResult
    func newSession(providerID: ProviderID, orientation: SplitOrientation? = nil) -> ConversationRunner {
        let vm = ConversationViewModel(providerID: providerID)
        let runner = ConversationRunner(viewModel: vm)
        runners[vm.id] = runner
        let tileID = active.tree.insert(
            .session(vm.id),
            splitting: active.focused,
            orientation: orientation,
            bounds: layoutBounds
        )
        active.focused = tileID
        browseFocused = false
        markDirty()
        onNewSession?(runner)
        return runner
    }

    /// Compare: a fresh chat per provider, laid out as an equal-size grid on its
    /// own screen (the current one is reused only if already empty). Sending the
    /// shared prompt is left to the caller, which holds the provider objects.
    @discardableResult
    func openComparison(providerIDs: [ProviderID]) -> [ConversationRunner] {
        guard !providerIDs.isEmpty else { return [] }
        if !active.tree.isEmpty { newScreen() } // no free slot → falls back to the current screen
        var created: [ConversationRunner] = []
        var leaves: [TileNode] = []
        for providerID in providerIDs {
            let vm = ConversationViewModel(providerID: providerID)
            let runner = ConversationRunner(viewModel: vm)
            runners[vm.id] = runner
            created.append(runner)
            leaves.append(.leaf(id: TileID(), surface: .session(vm.id)))
        }
        active.tree.root = TileTree.grid(of: leaves)
        active.focused = active.tree.leafIDs.first
        browseFocused = false
        markDirty()
        return created
    }

    /// Adopt an existing runner (panel handoff, history reopen) into the active screen.
    func adopt(_ runner: ConversationRunner) {
        let id = runner.viewModel.id
        guard runners[id] == nil else { return }
        runners[id] = runner
        let tileID = active.tree.insert(.session(id), splitting: active.focused, bounds: layoutBounds)
        active.focused = tileID
        markDirty()
    }

    /// Open (or focus) an app tile in the active screen.
    func openApp(_ appID: String) {
        let frames = active.tree.frames(in: layoutBounds)
        for (tileID, _) in frames {
            if active.tree.surface(of: tileID) == .app(appID) {
                active.focused = tileID
                return
            }
        }
        let tileID = active.tree.insert(.app(appID), splitting: active.focused, bounds: layoutBounds)
        active.focused = tileID
        markDirty()
    }

    /// ⌘W. On an already-empty numbered screen this closes the screen itself
    /// (closing the last tab closes the window); Home just stays empty.
    func closeFocusedTile() {
        if active.tree.isEmpty {
            if !active.isHome { closeActiveScreen() }
            return
        }
        guard let focused = active.focused else { return }
        let surface = active.tree.surface(of: focused)
        // Pick the next focus before mutating.
        let next = active.tree.neighbor(of: focused, direction: .left, bounds: layoutBounds)
            ?? active.tree.leafIDs.first { $0 != focused }
        active.tree.remove(focused)
        if active.zoomed == focused { active.zoomed = nil }
        active.focused = next
        if case .session(let convID) = surface {
            releaseHidden([convID])
        }
        markDirty()
    }

    /// Session ids shown by a tree.
    func sessionIDs(in tree: TileTree) -> [ConversationID] {
        tree.leafIDs.compactMap { tileID in
            if case .session(let id) = tree.surface(of: tileID) { return id }
            return nil
        }
    }

    private func isVisible(_ id: ConversationID) -> Bool {
        screens.contains { screen in
            screen.tree.leafIDs.contains { screen.tree.surface(of: $0) == .session(id) }
        }
    }

    /// Persist + cancel + drop every given session that no tile on any screen
    /// still shows. The ONLY place sessions are released.
    private func releaseHidden(_ ids: [ConversationID]) {
        for id in ids where !isVisible(id) {
            guard let runner = runners[id] else { continue }
            ConversationRunner.persist?(runner.viewModel)
            runner.cancel()
            runners[id] = nil
        }
    }

    /// Replace a screen's layout with a saved one. Sessions that are no longer
    /// live are revived from the archive (newest) or the view's own snapshots;
    /// ones with neither are dropped. Sessions the swap hides everywhere are
    /// released (they stay in history).
    func restore(
        into screen: WorkspaceModel,
        tree saved: TileTree,
        viewMode: WorkspaceViewMode,
        snapshots: [ConversationRecord] = [],
        archive: ConversationArchive
    ) {
        let previous = sessionIDs(in: screen.tree)
        var tree = saved
        for tileID in tree.leafIDs {
            guard case .session(let id) = tree.surface(of: tileID) else { continue }
            if runners[id] != nil { continue }
            let record = archive.records.first(where: { $0.id == id })
                ?? snapshots.first(where: { $0.id == id })
            if let record {
                runners[id] = ConversationRunner(viewModel: record.makeViewModel())
            } else {
                tree.remove(tileID)
            }
        }
        screen.tree = tree
        screen.viewMode = viewMode
        screen.zoomed = nil
        screen.focused = tree.leafIDs.first
        releaseHidden(previous)
        markDirty()
    }

    /// Bring the tile showing this conversation to the front, whichever screen
    /// it lives in. False if no tile shows it.
    @discardableResult
    func reveal(_ id: ConversationID) -> Bool {
        for (index, screen) in screens.enumerated() {
            if let tile = screen.tree.leafIDs.first(where: { screen.tree.surface(of: $0) == .session(id) }) {
                switchTo(index: index)
                screen.focused = tile
                return true
            }
        }
        return false
    }

    // MARK: - Screens

    func index(of slot: Int) -> Int? {
        screens.firstIndex { $0.id == slot }
    }

    func switchTo(index: Int) {
        guard screens.indices.contains(index) else { return }
        activeIndex = index
        if active.focused == nil || !active.tree.contains(active.focused!) {
            active.focused = active.tree.leafIDs.first
        }
        markDirty()
    }

    /// ⌘0…⌘9. No-op for a slot that doesn't exist.
    func switchTo(slot: Int) {
        if let index = index(of: slot) { switchTo(index: index) }
    }

    /// ⌘] — wraps from the last screen back to Home.
    func nextScreen() {
        switchTo(index: (activeIndex + 1) % screens.count)
    }

    /// ⌘[ — wraps from Home to the last screen.
    func previousScreen() {
        switchTo(index: (activeIndex - 1 + screens.count) % screens.count)
    }

    /// Smallest unused slot in 1…9, nil when all are taken.
    var nextFreeSlot: Int? {
        (1...Self.maxNumberedScreens).first { index(of: $0) == nil }
    }

    /// The screen for a slot, created empty if it doesn't exist yet (used by
    /// restore-at-launch). Does not switch.
    @discardableResult
    func screen(forSlot slot: Int) -> WorkspaceModel? {
        if let index = index(of: slot) { return screens[index] }
        guard (0...Self.maxNumberedScreens).contains(slot) else { return nil }
        let screen = WorkspaceModel(id: slot)
        insertSorted(screen)
        return screen
    }

    /// ⌘N: a new empty screen in the next free slot, switched to.
    @discardableResult
    func newScreen() -> WorkspaceModel? {
        guard let slot = nextFreeSlot else { return nil }
        let screen = WorkspaceModel(id: slot)
        insertSorted(screen)
        switchTo(slot: slot)
        return screen
    }

    /// ⌘S on Home: move Home's layout and live sessions into a new numbered
    /// screen and switch to it. Home is left empty. Runners are untouched, so
    /// streams keep going. Nil when not on Home, Home is empty, or no slot is free.
    @discardableResult
    func promoteHome() -> WorkspaceModel? {
        guard active.isHome, !home.tree.isEmpty, let slot = nextFreeSlot else { return nil }
        let screen = WorkspaceModel(id: slot, tree: home.tree, viewMode: home.viewMode, title: home.title)
        screen.focused = home.focused
        screen.zoomed = home.zoomed
        home.tree = TileTree()
        home.focused = nil
        home.zoomed = nil
        home.title = ""
        insertSorted(screen)
        switchTo(slot: slot)
        return screen
    }

    /// ⌘⇧W / right-click: remove a numbered screen. Its chats stay in history
    /// (and alive if another screen shows them). Lands on the previous screen.
    func closeScreen(_ slot: Int) {
        guard slot != 0, let index = index(of: slot) else { return }
        let ids = sessionIDs(in: screens[index].tree)
        let newIndex: Int
        if activeIndex > index {
            newIndex = activeIndex - 1
        } else if activeIndex == index {
            newIndex = max(index - 1, 0)
        } else {
            newIndex = activeIndex
        }
        screens.remove(at: index)
        activeIndex = min(newIndex, screens.count - 1)
        releaseHidden(ids)
        if active.focused == nil || !active.tree.contains(active.focused!) {
            active.focused = active.tree.leafIDs.first
        }
        markDirty()
    }

    func closeActiveScreen() {
        closeScreen(active.id)
    }

    private func insertSorted(_ screen: WorkspaceModel) {
        screens.append(screen)
        screens.sort { $0.id < $1.id }
    }

    // MARK: - Focus / arrangement

    func moveFocus(_ direction: MoveDirection) {
        guard let focused = active.focused else {
            active.focused = active.tree.leafIDs.first
            return
        }
        if let next = active.tree.neighbor(of: focused, direction: direction, bounds: layoutBounds) {
            active.focused = next
        }
    }

    func swapFocused(_ direction: MoveDirection) {
        guard let focused = active.focused,
              let neighbor = active.tree.neighbor(of: focused, direction: direction, bounds: layoutBounds)
        else { return }
        active.tree.swap(focused, neighbor)
        markDirty()
    }

    func resizeFocused(_ direction: MoveDirection) {
        guard let focused = active.focused else { return }
        let delta: Double = (direction == .left || direction == .up) ? -0.05 : 0.05
        active.tree.adjustRatio(around: focused, delta: delta)
        markDirty()
    }

    func toggleZoom() {
        guard let focused = active.focused else { return }
        active.zoomed = active.zoomed == focused ? nil : focused
    }

    func setViewMode(_ mode: WorkspaceViewMode) {
        active.viewMode = mode
        browseFocused = false
        // Every non-tiles view leans on a selection; make sure one exists.
        if active.focused == nil || !active.tree.contains(active.focused!) {
            active.focused = active.tree.leafIDs.first
        }
        markDirty()
    }

    func cycleViewMode() {
        let all = WorkspaceViewMode.allCases
        let index = all.firstIndex(of: active.viewMode) ?? 0
        setViewMode(all[(index + 1) % all.count])
    }

    /// Inbox list navigation: walk the selection up/down the conversation list.
    func moveInboxSelection(_ delta: Int) {
        let items = active.surfaceItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == active.focused } ?? 0
        active.focused = items[max(0, min(items.count - 1, current + delta))].id
        markDirty()
    }

    /// The tracker board's columns in display order, each holding its tile IDs —
    /// mirrors TrackerView's lane grouping so arrow-key nav matches the layout.
    /// Lanes: 0 New · 1 Running · 2 Failed · 3 Done · 4 Apps (only if occupied).
    func trackerColumns() -> [[TileID]] {
        func laneIndex(_ surface: SurfaceKind) -> Int {
            switch surface {
            case .app: return 4
            case .session(let id):
                guard let vm = runners[id]?.viewModel else { return 3 }
                switch vm.status {
                case .connecting, .streaming, .runningTool: return 1
                case .failed: return 2
                case .idle: return vm.hasContent ? 3 : 0
                }
            }
        }
        var columns: [[TileID]] = Array(repeating: [], count: 5)
        for item in active.surfaceItems { columns[laneIndex(item.surface)].append(item.id) }
        if columns[4].isEmpty { columns.removeLast() } // Apps hides when empty
        return columns
    }

    /// Tracker board navigation: ↑/↓ within a lane, ←/→ to the nearest occupied
    /// lane (keeping the row where possible).
    func moveTrackerSelection(_ direction: MoveDirection) {
        let columns = trackerColumns()
        guard columns.contains(where: { !$0.isEmpty }) else { return }
        guard let (col, row) = position(of: active.focused, in: columns) else {
            active.focused = columns.first { !$0.isEmpty }?.first
            markDirty()
            return
        }
        switch direction {
        case .up where row > 0: active.focused = columns[col][row - 1]
        case .down where row < columns[col].count - 1: active.focused = columns[col][row + 1]
        case .left: active.focused = nearestColumnCard(from: col, step: -1, row: row, in: columns) ?? active.focused
        case .right: active.focused = nearestColumnCard(from: col, step: 1, row: row, in: columns) ?? active.focused
        default: break
        }
        markDirty()
    }

    private func position(of id: TileID?, in columns: [[TileID]]) -> (col: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.firstIndex(where: { $0 == id }) { return (c, r) }
        }
        return nil
    }

    private func nearestColumnCard(from col: Int, step: Int, row: Int, in columns: [[TileID]]) -> TileID? {
        var c = col + step
        while c >= 0 && c < columns.count {
            if !columns[c].isEmpty { return columns[c][min(row, columns[c].count - 1)] }
            c += step
        }
        return nil
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

// The tiling model: a binary split tree, Hyprland-dwindle style. Pure value type
// so every operation is unit-testable without UI.

nonisolated struct TileID: Hashable, Codable, Sendable {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

nonisolated enum SurfaceKind: Hashable, Codable, Sendable {
    case session(ConversationID)
    case app(String) // AppModule id
}

nonisolated enum SplitOrientation: String, Codable, Sendable {
    case horizontal // children side by side
    case vertical   // children stacked
}

nonisolated enum MoveDirection: Sendable {
    case left, right, up, down
}

nonisolated indirect enum TileNode: Codable, Sendable {
    case leaf(id: TileID, surface: SurfaceKind)
    case split(orientation: SplitOrientation, ratio: Double, first: TileNode, second: TileNode)
}

nonisolated struct TileTree: Codable, Sendable {
    var root: TileNode?

    // MARK: - Queries

    var leafIDs: [TileID] {
        guard let root else { return [] }
        var out: [TileID] = []
        Self.collectLeaves(root) { id, _ in out.append(id) }
        return out
    }

    var isEmpty: Bool { root == nil }

    func surface(of id: TileID) -> SurfaceKind? {
        guard let root else { return nil }
        var found: SurfaceKind?
        Self.collectLeaves(root) { leafID, surface in
            if leafID == id { found = surface }
        }
        return found
    }

    func contains(_ id: TileID) -> Bool { surface(of: id) != nil }

    /// Frames for every leaf laid out in `bounds`, gaps applied by the view layer.
    func frames(in bounds: CGRect) -> [TileID: CGRect] {
        guard let root else { return [:] }
        var out: [TileID: CGRect] = [:]
        Self.layout(root, in: bounds, into: &out)
        return out
    }

    /// An equal-area grid of `leaves` as a balanced split tree — used by Compare.
    /// ≤3 tiles sit in a single row; otherwise they fill ⌈√n⌉ equal columns, each
    /// an equal vertical stack. Every tile is the same size when n fits the grid
    /// (2, 4, 6, 9…) and as close as a binary tree allows otherwise.
    static func grid(of leaves: [TileNode]) -> TileNode? {
        guard leaves.count > 1 else { return leaves.first }
        let columnCount = leaves.count <= 3 ? leaves.count : Int(Double(leaves.count).squareRoot().rounded(.up))
        var columns: [[TileNode]] = Array(repeating: [], count: columnCount)
        for (offset, leaf) in leaves.enumerated() { columns[offset % columnCount].append(leaf) }
        let columnNodes = columns.compactMap { equalSplit($0, orientation: .vertical) }
        return equalSplit(columnNodes, orientation: .horizontal)
    }

    /// Nest `nodes` into equal fractions along `orientation` (first gets 1/n, the
    /// rest split the remainder equally, so every node ends up the same size).
    private static func equalSplit(_ nodes: [TileNode], orientation: SplitOrientation) -> TileNode? {
        guard let first = nodes.first else { return nil }
        guard nodes.count > 1, let rest = equalSplit(Array(nodes.dropFirst()), orientation: orientation)
        else { return first }
        return .split(orientation: orientation, ratio: 1.0 / Double(nodes.count), first: first, second: rest)
    }

    // MARK: - Mutations

    /// Dwindle insert: split the target leaf. Orientation defaults to the leaf's
    /// aspect in `bounds` (wide -> side by side, tall -> stacked), which is what
    /// produces the spiral. Returns the new leaf's id.
    @discardableResult
    mutating func insert(
        _ surface: SurfaceKind,
        splitting target: TileID?,
        orientation: SplitOrientation? = nil,
        bounds: CGRect
    ) -> TileID {
        let newID = TileID()
        guard let root else {
            self.root = .leaf(id: newID, surface: surface)
            return newID
        }
        let targetID = target ?? leafIDs.last
        guard let targetID else {
            self.root = .leaf(id: newID, surface: surface)
            return newID
        }
        let targetFrame = frames(in: bounds)[targetID] ?? bounds
        let auto: SplitOrientation = targetFrame.width >= targetFrame.height ? .horizontal : .vertical
        self.root = Self.splitting(
            root,
            target: targetID,
            newLeaf: .leaf(id: newID, surface: surface),
            orientation: orientation ?? auto
        )
        return newID
    }

    /// Remove a leaf; its sibling absorbs the parent's slot.
    mutating func remove(_ id: TileID) {
        guard let root else { return }
        self.root = Self.removing(root, id: id)
    }

    /// Swap the payloads (id + surface) of two leaves; geometry stays put.
    mutating func swap(_ a: TileID, _ b: TileID) {
        guard let root, a != b else { return }
        var payloadA: (TileID, SurfaceKind)?
        var payloadB: (TileID, SurfaceKind)?
        Self.collectLeaves(root) { id, surface in
            if id == a { payloadA = (id, surface) }
            if id == b { payloadB = (id, surface) }
        }
        guard let pa = payloadA, let pb = payloadB else { return }
        self.root = Self.replacing(root) { id, _ in
            if id == a { return .leaf(id: pb.0, surface: pb.1) }
            if id == b { return .leaf(id: pa.0, surface: pa.1) }
            return nil
        }
    }

    /// Grow/shrink the split containing `id` along its orientation.
    mutating func adjustRatio(around id: TileID, delta: Double) {
        guard let root else { return }
        self.root = Self.adjustingRatio(root, around: id, delta: delta).node
    }

    /// Geometric neighbor for focus movement: the leaf whose frame adjoins
    /// `from`'s frame in `direction`, preferring the largest overlap.
    func neighbor(of from: TileID, direction: MoveDirection, bounds: CGRect) -> TileID? {
        let all = frames(in: bounds)
        guard let origin = all[from] else { return nil }
        let epsilon: CGFloat = 2.0
        var best: (TileID, CGFloat)?
        for (id, frame) in all where id != from {
            let adjacent: Bool
            let overlap: CGFloat
            switch direction {
            case .left:
                adjacent = abs(frame.maxX - origin.minX) < epsilon
                overlap = verticalOverlap(frame, origin)
            case .right:
                adjacent = abs(frame.minX - origin.maxX) < epsilon
                overlap = verticalOverlap(frame, origin)
            case .up:
                adjacent = abs(frame.maxY - origin.minY) < epsilon
                overlap = horizontalOverlap(frame, origin)
            case .down:
                adjacent = abs(frame.minY - origin.maxY) < epsilon
                overlap = horizontalOverlap(frame, origin)
            }
            if adjacent, overlap > 0, best == nil || overlap > best!.1 {
                best = (id, overlap)
            }
        }
        return best?.0
    }

    private func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    // MARK: - Recursive helpers

    private static func collectLeaves(_ node: TileNode, _ visit: (TileID, SurfaceKind) -> Void) {
        switch node {
        case .leaf(let id, let surface):
            visit(id, surface)
        case .split(_, _, let first, let second):
            collectLeaves(first, visit)
            collectLeaves(second, visit)
        }
    }

    private static func layout(_ node: TileNode, in rect: CGRect, into out: inout [TileID: CGRect]) {
        switch node {
        case .leaf(let id, _):
            out[id] = rect
        case .split(let orientation, let ratio, let first, let second):
            let r = CGFloat(ratio)
            switch orientation {
            case .horizontal:
                let firstWidth = rect.width * r
                layout(first, in: CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height), into: &out)
                layout(second, in: CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height), into: &out)
            case .vertical:
                let firstHeight = rect.height * r
                layout(first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight), into: &out)
                layout(second, in: CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight), into: &out)
            }
        }
    }

    private static func splitting(
        _ node: TileNode,
        target: TileID,
        newLeaf: TileNode,
        orientation: SplitOrientation
    ) -> TileNode {
        switch node {
        case .leaf(let id, _):
            guard id == target else { return node }
            return .split(orientation: orientation, ratio: 0.5, first: node, second: newLeaf)
        case .split(let o, let ratio, let first, let second):
            return .split(
                orientation: o,
                ratio: ratio,
                first: splitting(first, target: target, newLeaf: newLeaf, orientation: orientation),
                second: splitting(second, target: target, newLeaf: newLeaf, orientation: orientation)
            )
        }
    }

    private static func removing(_ node: TileNode, id: TileID) -> TileNode? {
        switch node {
        case .leaf(let leafID, _):
            return leafID == id ? nil : node
        case .split(let orientation, let ratio, let first, let second):
            let newFirst = removing(first, id: id)
            let newSecond = removing(second, id: id)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let only?, nil): return only // sibling absorbs the slot
            case (nil, let only?): return only
            case (let f?, let s?):
                return .split(orientation: orientation, ratio: ratio, first: f, second: s)
            }
        }
    }

    /// Replace leaves via a transform (used by swap).
    private static func replacing(_ node: TileNode, _ transform: (TileID, SurfaceKind) -> TileNode?) -> TileNode {
        switch node {
        case .leaf(let id, let surface):
            return transform(id, surface) ?? node
        case .split(let orientation, let ratio, let first, let second):
            return .split(
                orientation: orientation,
                ratio: ratio,
                first: replacing(first, transform),
                second: replacing(second, transform)
            )
        }
    }

    /// Adjusts the ratio of the NEAREST split ancestor of `id`.
    private static func adjustingRatio(_ node: TileNode, around id: TileID, delta: Double) -> (node: TileNode, containsTarget: Bool, adjusted: Bool) {
        switch node {
        case .leaf(let leafID, _):
            return (node, leafID == id, false)
        case .split(let orientation, let ratio, let first, let second):
            let f = adjustingRatio(first, around: id, delta: delta)
            let s = adjustingRatio(second, around: id, delta: delta)
            let contains = f.containsTarget || s.containsTarget
            let alreadyAdjusted = f.adjusted || s.adjusted
            var newRatio = ratio
            var adjusted = alreadyAdjusted
            if contains, !alreadyAdjusted {
                // First (deepest) split that contains the target adjusts.
                newRatio = min(0.85, max(0.15, ratio + (f.containsTarget ? delta : -delta)))
                adjusted = true
            }
            return (
                .split(orientation: orientation, ratio: newRatio, first: f.node, second: s.node),
                contains,
                adjusted
            )
        }
    }
}

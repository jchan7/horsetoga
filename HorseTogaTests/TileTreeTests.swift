//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Testing
@testable import HorseToga

@Suite("TileTree")
struct TileTreeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func session() -> SurfaceKind { .session(ConversationID()) }

    @Test("first insert fills the workspace")
    func firstInsert() {
        var tree = TileTree()
        let id = tree.insert(session(), splitting: nil, bounds: bounds)
        #expect(tree.leafIDs == [id])
        #expect(tree.frames(in: bounds)[id] == bounds)
    }

    @Test("dwindle: wide leaf splits side-by-side, tall leaf splits stacked")
    func dwindleOrientation() {
        var tree = TileTree()
        let first = tree.insert(session(), splitting: nil, bounds: bounds)
        // First tile is 1200x800 (wide) -> horizontal split
        let second = tree.insert(session(), splitting: first, bounds: bounds)
        var frames = tree.frames(in: bounds)
        #expect(frames[first]!.width == 600)
        #expect(frames[second]!.minX == 600)

        // Second tile is now 600x800 (tall) -> vertical split: the spiral
        let third = tree.insert(session(), splitting: second, bounds: bounds)
        frames = tree.frames(in: bounds)
        #expect(frames[second]!.height == 400)
        #expect(frames[third]!.minY == 400)
        #expect(frames[third]!.minX == 600)
    }

    @Test("remove collapses the split and the sibling absorbs the space")
    func removeCollapses() {
        var tree = TileTree()
        let a = tree.insert(session(), splitting: nil, bounds: bounds)
        let b = tree.insert(session(), splitting: a, bounds: bounds)
        tree.remove(b)
        #expect(tree.leafIDs == [a])
        #expect(tree.frames(in: bounds)[a] == bounds)
        tree.remove(a)
        #expect(tree.isEmpty)
    }

    @Test("swap exchanges positions, keeps geometry")
    func swapKeepsGeometry() {
        var tree = TileTree()
        let a = tree.insert(session(), splitting: nil, bounds: bounds)
        let b = tree.insert(session(), splitting: a, bounds: bounds)
        let framesBefore = tree.frames(in: bounds)
        tree.swap(a, b)
        let framesAfter = tree.frames(in: bounds)
        #expect(framesAfter[a] == framesBefore[b])
        #expect(framesAfter[b] == framesBefore[a])
        // Same set of rects overall
        #expect(Set(framesAfter.values.map { "\($0)" }) == Set(framesBefore.values.map { "\($0)" }))
    }

    @Test("geometric neighbor finds the adjacent tile")
    func neighborQueries() {
        var tree = TileTree()
        let a = tree.insert(session(), splitting: nil, bounds: bounds)   // left half
        let b = tree.insert(session(), splitting: a, bounds: bounds)    // right half
        let c = tree.insert(session(), splitting: b, bounds: bounds)    // bottom-right

        #expect(tree.neighbor(of: a, direction: .right, bounds: bounds) != nil)
        #expect(tree.neighbor(of: b, direction: .left, bounds: bounds) == a)
        #expect(tree.neighbor(of: b, direction: .down, bounds: bounds) == c)
        #expect(tree.neighbor(of: c, direction: .up, bounds: bounds) == b)
        #expect(tree.neighbor(of: a, direction: .left, bounds: bounds) == nil)
    }

    @Test("ratio adjust clamps and only touches the nearest split")
    func ratioAdjust() {
        var tree = TileTree()
        let a = tree.insert(session(), splitting: nil, bounds: bounds)
        let b = tree.insert(session(), splitting: a, bounds: bounds)
        _ = b
        tree.adjustRatio(around: a, delta: 0.1)
        let frames = tree.frames(in: bounds)
        #expect(abs(frames[a]!.width - 720) < 0.001) // 0.5 + 0.1 -> 0.6 of 1200

        // Clamp: pile on deltas, must stop at 0.85
        for _ in 0..<20 { tree.adjustRatio(around: a, delta: 0.1) }
        #expect(abs(tree.frames(in: bounds)[a]!.width - 1200 * 0.85) < 0.001)
    }

    @Test("tree round-trips through Codable (layout persistence)")
    func codableRoundTrip() throws {
        var tree = TileTree()
        let a = tree.insert(session(), splitting: nil, bounds: bounds)
        let b = tree.insert(session(), splitting: a, bounds: bounds)
        _ = tree.insert(.app("usage"), splitting: b, bounds: bounds)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(TileTree.self, from: data)
        #expect(decoded.leafIDs == tree.leafIDs)
        #expect(decoded.frames(in: bounds) == tree.frames(in: bounds))
    }
}

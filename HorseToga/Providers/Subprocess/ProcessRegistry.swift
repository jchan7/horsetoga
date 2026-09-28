//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Tracks every child process so none outlive the app. CLI agents left orphaned
/// keep burning tokens invisibly; users notice them in Activity Monitor.
nonisolated final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var livePIDs: Set<Int32> = []

    func register(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        livePIDs.insert(pid)
    }

    func unregister(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        livePIDs.remove(pid)
    }

    /// True while the pid is still one of ours. Delayed kill escalation checks this
    /// so a recycled pid is never signalled by mistake.
    func isLive(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return livePIDs.contains(pid)
    }

    /// Called from applicationWillTerminate.
    func killAll() {
        lock.lock()
        let pids = livePIDs
        livePIDs.removeAll()
        lock.unlock()
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }
}

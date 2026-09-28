//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Synchronization

nonisolated struct SubprocessSpec: Sendable {
    var executablePath: String
    var arguments: [String]
    var stdinData: Data?
    var workingDirectory: URL?
    var extraEnvironment: [String: String] = [:]
    /// Kill + fail if the child produces no stdout for this long. CLI agents that
    /// stop to ask a question would otherwise hang the UI forever.
    var watchdogSeconds: TimeInterval = 90
}

nonisolated enum SubprocessEvent: Sendable {
    case spawned(pid: Int32)
    case line(Data)
    case exited(code: Int32, stderrTail: String)
}

/// Spawns a child and streams its stdout line-by-line.
///
/// Deliberate choices, all learned the hard way:
/// - Explicit environment: Finder-launched apps have no PATH/HOME; the CLIs resolve
///   credentials relative to HOME and silently fail without it.
/// - `readabilityHandler`, not `FileHandle.bytes.lines`: the latter ignores Task
///   cancellation and parks a thread on read(2) until the process dies.
/// - stderr drained concurrently into a capped ring: an undrained 64KB pipe buffer
///   deadlocks the child.
/// - Cancellation escalates SIGINT -> SIGTERM -> SIGKILL so CLIs get a chance to
///   flush state, but can't refuse to die.
nonisolated enum ProcessRunner {

    /// GUI apps do not inherit the user's shell PATH. Keep the vendor-specific
    /// install locations here so setup, health checks, and conversations all
    /// resolve the same executable after a one-click install.
    static func executableSearchPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.grok/bin",
            "\(home)/.codex/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin", // MacPorts
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    static func baseEnvironment(extra: [String: String]) -> [String: String] {
        let home = NSHomeDirectory()
        var env: [String: String] = [
            "HOME": home,
            "PATH": executableSearchPaths(home: home).joined(separator: ":"),
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        env.merge(extra) { _, new in new }
        return env
    }

    /// Liveness probe: does `path probeArgs…` actually execute under the same
    /// environment a real run uses? `isExecutableFile` is not enough — an npm
    /// CLI whose platform binary never installed leaves an executable launcher
    /// that ENOENTs the instant it runs (the classic Codex "codex-darwin-arm64
    /// missing" break), and a wrong-arch or half-written binary looks identical
    /// on disk. Cached per (path, size, mtime); an empty probe list skips the
    /// check. A healthy `--version` returns near-instantly and the breaks we
    /// catch exit non-zero just as fast, so a probe still running at the deadline
    /// is trusted — a working-but-sluggish CLI must never be discarded.
    private static let runnableCache = Mutex<[String: Bool]>([:])

    private static func runnableKey(_ path: String, probeArgs: [String]) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "\(path)\u{1}\(size)\u{1}\(mtime)\u{1}\(probeArgs.joined(separator: " "))"
    }

    /// The cached probe verdict, or nil if this binary hasn't been probed yet.
    /// Never launches anything, so it is safe to call from a view body.
    static func cachedRunnable(_ path: String, probeArgs: [String]) -> Bool? {
        guard !probeArgs.isEmpty else { return true }
        let key = runnableKey(path, probeArgs: probeArgs)
        return runnableCache.withLock { $0[key] }
    }

    static func isRunnable(_ path: String, probeArgs: [String]) -> Bool {
        guard !probeArgs.isEmpty else { return true }
        let key = runnableKey(path, probeArgs: probeArgs)
        if let cached = runnableCache.withLock({ $0[key] }) { return cached }

        var healthy = true
        let probe = Process()
        probe.executableURL = URL(filePath: path)
        probe.arguments = probeArgs
        probe.environment = baseEnvironment(extra: [:])
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            // Single-threaded bounded wait (no cross-thread Process capture, so
            // it stays clean under strict concurrency).
            let deadline = Date().addingTimeInterval(3)
            while probe.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.015)
            }
            if probe.isRunning {
                probe.terminate() // hung probe → trust it rather than reject a slow binary
            } else {
                healthy = probe.terminationStatus == 0
            }
        } catch {
            healthy = false // could not even launch it
        }
        runnableCache.withLock { $0[key] = healthy }
        return healthy
    }

    static func run(_ spec: SubprocessSpec) -> AsyncThrowingStream<SubprocessEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(filePath: spec.executablePath)
            process.arguments = spec.arguments
            process.environment = baseEnvironment(extra: spec.extraEnvironment)
            if let wd = spec.workingDirectory {
                process.currentDirectoryURL = wd
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe

            let state = Mutex(RunState())

            // -- stdout: line splitter ----------------------------------------
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { // EOF
                    handle.readabilityHandler = nil
                    let (leftover, finish) = state.withLock { s -> (Data?, (Int32, String)?) in
                        let leftover = s.carry.isEmpty ? nil : s.carry
                        s.carry.removeAll()
                        s.stdoutEOF = true
                        return (leftover, s.readyToFinish())
                    }
                    if let leftover { continuation.yield(.line(leftover)) }
                    if let (code, tail) = finish {
                        continuation.yield(.exited(code: code, stderrTail: tail))
                        continuation.finish()
                    }
                    return
                }
                let lines: [Data]? = state.withLock { s in
                    s.lastActivity = ContinuousClock.now
                    s.carry.append(chunk)
                    guard s.carry.count < 16 * 1024 * 1024 else { return nil } // runaway line
                    var out: [Data] = []
                    while let nl = s.carry.firstIndex(of: 0x0A) {
                        out.append(s.carry.subdata(in: s.carry.startIndex..<nl))
                        s.carry.removeSubrange(s.carry.startIndex...nl)
                    }
                    return out
                }
                guard let lines else {
                    handle.readabilityHandler = nil
                    continuation.finish(throwing: ProviderError.decode("single line exceeded 16MB", rawLine: ""))
                    kill(process.processIdentifier, SIGKILL)
                    return
                }
                for line in lines where !line.isEmpty {
                    continuation.yield(.line(line))
                }
            }

            // -- stderr: capped ring ------------------------------------------
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                state.withLock { s in
                    s.stderrTail.append(chunk)
                    if s.stderrTail.count > 64 * 1024 {
                        s.stderrTail.removeFirst(s.stderrTail.count - 64 * 1024)
                    }
                }
            }

            // -- exit ----------------------------------------------------------
            process.terminationHandler = { proc in
                let pid = proc.processIdentifier
                ProcessRegistry.shared.unregister(pid: pid)
                let finish = state.withLock { s -> (Int32, String)? in
                    s.exitCode = proc.terminationStatus
                    return s.readyToFinish()
                }
                if let (code, tail) = finish {
                    continuation.yield(.exited(code: code, stderrTail: tail))
                    continuation.finish()
                }
            }

            // -- spawn -----------------------------------------------------------
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ProviderError.executableMissing(path: spec.executablePath))
                return
            }
            let pid = process.processIdentifier
            ProcessRegistry.shared.register(pid: pid)
            continuation.yield(.spawned(pid: pid))

            // -- stdin -----------------------------------------------------------
            if let data = spec.stdinData {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            // -- watchdog --------------------------------------------------------
            let watchdog = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    let stalled = state.withLock { s -> Bool in
                        guard s.exitCode == nil else { return false }
                        return ContinuousClock.now - s.lastActivity > .seconds(spec.watchdogSeconds)
                    }
                    if stalled {
                        continuation.finish(throwing: ProviderError.timedOut)
                        Self.escalateKill(pid: pid)
                        return
                    }
                }
            }

            // -- cancellation / teardown ----------------------------------------
            continuation.onTermination = { reason in
                watchdog.cancel()
                if case .cancelled = reason {
                    Self.escalateKill(pid: pid)
                }
            }
        }
    }

    /// SIGINT now, SIGTERM at +2s, SIGKILL at +3s; each step skipped once the pid
    /// leaves the registry (i.e. the process exited).
    private static func escalateKill(pid: Int32) {
        guard ProcessRegistry.shared.isLive(pid: pid) else { return }
        kill(pid, SIGINT)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            guard ProcessRegistry.shared.isLive(pid: pid) else { return }
            kill(pid, SIGTERM)
            try? await Task.sleep(for: .seconds(1))
            guard ProcessRegistry.shared.isLive(pid: pid) else { return }
            kill(pid, SIGKILL)
        }
    }

    private struct RunState {
        var carry = Data()
        var stderrTail = Data()
        var stdoutEOF = false
        var exitCode: Int32?
        var finished = false
        var lastActivity = ContinuousClock.now

        /// Exit is emitted only after BOTH stdout EOF and termination have landed,
        /// whichever order they arrive in.
        mutating func readyToFinish() -> (Int32, String)? {
            guard stdoutEOF, let code = exitCode, !finished else { return nil }
            finished = true
            return (code, String(data: stderrTail, encoding: .utf8) ?? "")
        }
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Synchronization
import Testing
@testable import HorseToga

@Suite("ProcessRunner", .timeLimit(.minutes(1)))
struct ProcessRunnerTests {

    @Test("missing binary throws executableMissing instead of hanging")
    func missingBinary() async {
        let spec = SubprocessSpec(
            executablePath: "/nonexistent/definitely-not-a-binary",
            arguments: [],
            stdinData: nil
        )
        await #expect(throws: ProviderError.self) {
            for try await _ in ProcessRunner.run(spec) {}
        }
    }

    @Test("lines split correctly, trailing partial line flushed at EOF")
    func lineSplitting() async throws {
        let spec = SubprocessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", #"printf 'alpha\nbeta\n'; printf 'gamma-no-newline'"#],
            stdinData: nil
        )
        var lines: [String] = []
        var exitCode: Int32?
        for try await event in ProcessRunner.run(spec) {
            switch event {
            case .spawned: break
            case .line(let data): lines.append(String(data: data, encoding: .utf8) ?? "?")
            case .exited(let code, _): exitCode = code
            }
        }
        #expect(lines == ["alpha", "beta", "gamma-no-newline"])
        #expect(exitCode == 0)
    }

    @Test("stdin is delivered and closed")
    func stdinDelivery() async throws {
        let spec = SubprocessSpec(
            executablePath: "/bin/cat",
            arguments: [],
            stdinData: Data("hello horsetoga\n".utf8)
        )
        var lines: [String] = []
        for try await event in ProcessRunner.run(spec) {
            if case .line(let data) = event {
                lines.append(String(data: data, encoding: .utf8) ?? "?")
            }
        }
        #expect(lines == ["hello horsetoga"])
    }

    @Test("nonzero exit carries stderr tail")
    func stderrTail() async throws {
        let spec = SubprocessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo boom >&2; exit 3"],
            stdinData: nil
        )
        var captured: (Int32, String)?
        for try await event in ProcessRunner.run(spec) {
            if case .exited(let code, let tail) = event {
                captured = (code, tail)
            }
        }
        #expect(captured?.0 == 3)
        #expect(captured?.1.contains("boom") == true)
    }

    @Test("cancelling the consumer kills the child (no orphans)")
    func cancellationKillsChild() async throws {
        let spec = SubprocessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "exec sleep 30"],
            stdinData: nil
        )
        let pidBox = Mutex<Int32?>(nil)
        let consumer = Task {
            do {
                for try await event in ProcessRunner.run(spec) {
                    if case .spawned(let pid) = event {
                        pidBox.withLock { $0 = pid }
                    }
                }
            } catch {}
        }
        // Wait for spawn
        var pid: Int32?
        for _ in 0..<50 {
            pid = pidBox.withLock { $0 }
            if pid != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let childPID = try #require(pid)
        #expect(kill(childPID, 0) == 0) // alive

        consumer.cancel()

        // SIGINT lands immediately; allow up to 5s for the escalation ladder
        var dead = false
        for _ in 0..<50 {
            if kill(childPID, 0) != 0 { dead = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(dead, "child \(childPID) survived cancellation")
        #expect(!ProcessRegistry.shared.isLive(pid: childPID))
    }

    @Test("watchdog kills a silent child")
    func watchdogFires() async throws {
        var spec = SubprocessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "exec sleep 60"], // never writes anything
            stdinData: nil
        )
        spec.watchdogSeconds = 6 // watchdog polls every 5s
        var thrown: Error?
        do {
            for try await _ in ProcessRunner.run(spec) {}
        } catch {
            thrown = error
        }
        guard case .some(ProviderError.timedOut) = thrown else {
            Issue.record("expected timedOut, got \(String(describing: thrown))")
            return
        }
    }
}

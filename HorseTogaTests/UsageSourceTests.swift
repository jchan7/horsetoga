//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Testing
@testable import HorseToga

@Suite("UsageSources")
struct UsageSourceTests {
    /// Fixed "now" so day bucketing is deterministic.
    private let now = ISO8601DateFormatter().date(from: "2026-08-20T15:00:00Z")!

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "horsetoga-usage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("claude source: dedupes retries, buckets by day, respects window, skips synthetic")
    func claudeSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appending(path: "projects/-test-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        func assistantLine(id: String, request: String, ts: String, model: String, input: Int, output: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        }

        let lines = [
            assistantLine(id: "m1", request: "r1", ts: "2026-08-19T10:00:00.000Z", model: "claude-opus-5", input: 100, output: 50),
            assistantLine(id: "m1", request: "r1", ts: "2026-08-19T10:00:00.000Z", model: "claude-opus-5", input: 100, output: 50), // duplicate: dropped
            assistantLine(id: "m2", request: "r2", ts: "2026-08-20T09:00:00.000Z", model: "claude-fable-5", input: 10, output: 5),
            assistantLine(id: "m3", request: "r3", ts: "2026-07-01T09:00:00.000Z", model: "claude-opus-5", input: 999, output: 999), // outside window
            assistantLine(id: "m4", request: "r4", ts: "2026-08-20T10:00:00.000Z", model: "<synthetic>", input: 7, output: 3), // synthetic model: day counts, model doesn't
            #"{"type":"user","message":{"content":"hi"}}"#, // no usage: ignored
            "garbage line",
        ]
        try lines.joined(separator: "\n").write(
            to: project.appending(path: "session.jsonl"), atomically: true, encoding: .utf8)

        var source = ClaudeCodeUsageSource()
        source.root = dir.appending(path: "projects")
        let usage = source.scan(days: 7, now: now)

        #expect(usage.byDay.count == 7)
        let byDayTotal = usage.byDay.reduce(0) { $0 + $1.totalTokens }
        #expect(byDayTotal == 150 + 15 + 10) // m1 once + m2 + m4
        #expect(usage.byDay.last?.totalTokens == 15 + 10) // today: m2 + m4

        #expect(usage.byModel.map(\.model).sorted() == ["claude-fable-5", "claude-opus-5"])
        #expect(usage.byModel.first { $0.model == "claude-opus-5" }?.totalTokens == 150)
    }

    @Test("codex source: sums last_token_usage per turn, attributes model, newest rate limit wins")
    func codexSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = dir.appending(path: "sessions/2026/08/19")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        func tokenCount(ts: String, total: Int, usedPercent: Double?, resetsAt: Int?) -> String {
            var rateLimits = "null"
            if let usedPercent, let resetsAt {
                rateLimits = #"{"limit_id":"codex","plan_type":"team","primary":{"used_percent":\#(usedPercent),"window_minutes":10080,"resets_at":\#(resetsAt)}}"#
            }
            return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":\#(total)}},"rate_limits":\#(rateLimits)}}"#
        }

        let lines = [
            #"{"timestamp":"2026-08-19T10:00:00.000Z","type":"session_meta","payload":{"session_id":"s1"}}"#,
            #"{"timestamp":"2026-08-19T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            tokenCount(ts: "2026-08-19T10:01:00.000Z", total: 1000, usedPercent: 10, resetsAt: 1787434240),
            tokenCount(ts: "2026-08-19T11:00:00.000Z", total: 500, usedPercent: 31, resetsAt: 1787434240),
            #"{"timestamp":"2026-08-19T11:30:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-mini"}}"#,
            tokenCount(ts: "2026-08-19T11:31:00.000Z", total: 200, usedPercent: nil, resetsAt: nil),
        ]
        try lines.joined(separator: "\n").write(
            to: day.appending(path: "rollout-test.jsonl"), atomically: true, encoding: .utf8)

        var source = CodexUsageSource()
        source.root = dir.appending(path: "sessions")
        let usage = source.scan(days: 7, now: now)

        #expect(usage.byDay.reduce(0) { $0 + $1.totalTokens } == 1700)
        #expect(usage.byModel.first { $0.model == "gpt-5.6-sol" }?.totalTokens == 1500)
        #expect(usage.byModel.first { $0.model == "gpt-5.6-mini" }?.totalTokens == 200)
        #expect(usage.planBadge == "TEAM")
        // Newest token_count carrying rate_limits wins: 31%, not 10%.
        #expect(usage.rateLimit?.usedPercent == 31)
        #expect(usage.rateLimit?.label == "Weekly")
        #expect(usage.rateLimit?.resetsAt == Date(timeIntervalSince1970: 1787434240))
    }

    @Test("token formatting matches dashboard style")
    func formatting() {
        #expect(UsageFormat.tokens(0) == "0")
        #expect(UsageFormat.tokens(950) == "950")
        #expect(UsageFormat.tokens(24_400_000) == "24.4M")
        #expect(UsageFormat.tokens(549_700_000) == "549.7M")
        #expect(UsageFormat.tokens(1_300_000_000) == "1.3B")
        #expect(UsageFormat.tokens(7_600) == "7.6K")
    }
}

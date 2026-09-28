//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Computes Codex usage from ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
/// Per-turn tokens come from event_msg/token_count payloads (last_token_usage);
/// the newest token_count also carries rate_limits.primary -> the weekly bar
/// (used_percent + resets_at). Model attribution comes from turn_context lines.
nonisolated struct CodexUsageSource: Sendable {
    var root = URL(filePath: NSHomeDirectory()).appending(path: ".codex/sessions")

    func scan(days window: Int = 7, now: Date = .now, calendar: Calendar = .current) -> ProviderUsage {
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-(window - 1) * 86400))
        let parser = LogTimestampParser()

        var perDay: [Date: Int] = [:]
        var perModel: [String: Int] = [:]
        var newestRateLimit: (Date, RateLimitStatus)?
        var planBadge: String?
        var fileCount = 0

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            fileCount += 1

            var currentModel = "unknown"
            for lineData in data.split(separator: UInt8(0x0A)) {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any],
                      let type = obj["type"] as? String else { continue }

                // Model context switches mid-session follow turn_context lines.
                if type == "turn_context",
                   let payload = obj["payload"] as? [String: Any],
                   let model = payload["model"] as? String {
                    currentModel = model
                    continue
                }

                guard type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count" else { continue }

                let timestamp = (obj["timestamp"] as? String).flatMap(parser.parse)

                if let info = payload["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any] {
                    let total = last["total_tokens"] as? Int
                        ?? (last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0)
                    if total > 0, let timestamp, timestamp >= cutoff {
                        perDay[calendar.startOfDay(for: timestamp), default: 0] += total
                        perModel[currentModel, default: 0] += total
                    }
                }

                if let rateLimits = payload["rate_limits"] as? [String: Any] {
                    if let plan = rateLimits["plan_type"] as? String {
                        planBadge = plan.uppercased()
                    }
                    if let primary = rateLimits["primary"] as? [String: Any],
                       let usedPercent = primary["used_percent"] as? Double {
                        let windowMinutes = primary["window_minutes"] as? Int ?? 0
                        let resetsAt = (primary["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                        let status = RateLimitStatus(
                            label: windowMinutes >= 10080 ? "Weekly" : windowMinutes >= 240 ? "\(windowMinutes / 60)h" : "Limit",
                            usedPercent: usedPercent,
                            resetsAt: resetsAt
                        )
                        let stamp = timestamp ?? .distantPast
                        if newestRateLimit == nil || stamp > newestRateLimit!.0 {
                            newestRateLimit = (stamp, status)
                        }
                    }
                }
            }
        }

        return ProviderUsage(
            providerID: "codex",
            displayName: "Codex",
            planBadge: planBadge,
            rateLimit: newestRateLimit?.1,
            byDay: ClaudeCodeUsageSource.trailingDays(window: window, now: now, calendar: calendar, values: perDay),
            byModel: perModel.map { ModelUsage(model: $0.key, totalTokens: $0.value) }
                .sorted { $0.totalTokens > $1.totalTokens },
            note: fileCount == 0 ? "no Codex sessions found" : nil
        )
    }
}

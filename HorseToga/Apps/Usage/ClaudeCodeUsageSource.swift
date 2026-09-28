//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Computes Claude Code usage from local transcripts: ~/.claude/projects/**/*.jsonl.
/// Each assistant line carries message.usage + message.model; dedupe on
/// message.id (retries re-log the same message). The tree is a few MB, so a full
/// rescan of week-recent files per refresh is cheap; no daemon needed.
nonisolated struct ClaudeCodeUsageSource: Sendable {
    var root = URL(filePath: NSHomeDirectory()).appending(path: ".claude/projects")

    func scan(days window: Int = 7, now: Date = .now, calendar: Calendar = .current) -> ProviderUsage {
        let cutoff = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-(window - 1) * 86400))
        let parser = LogTimestampParser()

        var perDay: [Date: Int] = [:]
        var perModel: [String: Int] = [:]
        var seenMessageIDs = Set<String>()
        var fileCount = 0

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip files untouched since before the window.
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            fileCount += 1

            for lineData in data.split(separator: UInt8(0x0A)) {
                // Fast reject before JSON parse: assistant usage lines only.
                guard lineData.count > 40 else { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }

                guard let rawTimestamp = obj["timestamp"] as? String,
                      let timestamp = parser.parse(rawTimestamp),
                      timestamp >= cutoff else { continue }

                // Dedupe: same API message can be logged more than once.
                if let messageID = message["id"] as? String {
                    let key = messageID + (obj["requestId"] as? String ?? "")
                    guard seenMessageIDs.insert(key).inserted else { continue }
                }

                let total = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                guard total > 0 else { continue }

                let day = calendar.startOfDay(for: timestamp)
                perDay[day, default: 0] += total
                let model = message["model"] as? String ?? "unknown"
                // Synthetic error placeholders aren't real inference.
                if model != "<synthetic>" {
                    perModel[model, default: 0] += total
                }
            }
        }

        return ProviderUsage(
            providerID: "claude-code",
            displayName: "Claude Code",
            planBadge: nil,
            rateLimit: nil, // local transcripts don't carry limit state
            byDay: Self.trailingDays(window: window, now: now, calendar: calendar, values: perDay),
            byModel: perModel.map { ModelUsage(model: $0.key, totalTokens: $0.value) }
                .sorted { $0.totalTokens > $1.totalTokens },
            note: fileCount == 0 ? "no Claude Code transcripts found" : nil
        )
    }

    static func trailingDays(window: Int, now: Date, calendar: Calendar, values: [Date: Int]) -> [DayUsage] {
        let today = calendar.startOfDay(for: now)
        return (0..<window).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayUsage(day: day, totalTokens: values[day] ?? 0)
        }
    }
}

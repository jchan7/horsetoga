//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

nonisolated struct DayUsage: Sendable, Identifiable, Equatable {
    var day: Date // startOfDay, local calendar
    var totalTokens: Int
    var id: Date { day }
}

nonisolated struct ModelUsage: Sendable, Identifiable, Equatable {
    var model: String
    var totalTokens: Int
    var id: String { model }
}

nonisolated struct RateLimitStatus: Sendable, Equatable {
    var label: String       // "Weekly"
    var usedPercent: Double // 0-100
    var resetsAt: Date?
}

nonisolated struct ProviderUsage: Sendable, Identifiable, Equatable {
    var providerID: String       // "claude-code" | "codex" | "fireworks"
    var displayName: String
    var planBadge: String?       // "PRO", "TEAM", "PREPAID"
    var rateLimit: RateLimitStatus?
    var byDay: [DayUsage]        // trailing 7 days, oldest first
    var byModel: [ModelUsage]    // descending by tokens
    var note: String?            // e.g. "add API key in Settings" / parse errors
    var id: String { providerID }
}

nonisolated enum UsageFormat {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...: return trim(v / 1_000_000) + "M"
        case 1_000...: return trim(v / 1_000) + "K"
        case 0: return "0"
        default: return String(n)
        }
    }

    private static func trim(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    static func resetCountdown(to date: Date, from now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Sat / Sun / ... / Today labels for the trailing week.
    static func dayLabel(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEE"
        return formatter.string(from: day)
    }
}

/// Shared JSONL timestamp parsing (both CLIs write ISO8601, claude with fractions).
/// One instance per scan: ISO8601DateFormatter isn't Sendable and isn't free.
nonisolated struct LogTimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
    }

    func parse(_ raw: String) -> Date? {
        fractional.date(from: raw) ?? plain.date(from: raw)
    }
}

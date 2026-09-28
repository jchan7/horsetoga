//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// The usage dashboard: provider tabs, weekly limit bar, tokens by day,
/// tokens by model. Monospace-forward, terminal aesthetic.
struct UsageAppView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                tabStrip
                if let provider = store.selected {
                    if let limit = provider.rateLimit {
                        limitsSection(limit)
                    }
                    tokensByDay(provider)
                    tokensByModel(provider)
                    if let note = provider.note {
                        Text(note)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.startAutoRefresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selected?.displayName ?? "Usage")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                if let badge = store.selected?.planBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .kerning(1.5)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 8) {
            ForEach(store.providers) { provider in
                let isSelected = store.selectedProviderID == provider.providerID
                Button {
                    store.selectedProviderID = provider.providerID
                } label: {
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(isSelected ? 0.35 : 0.12), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.white.opacity(isSelected ? 0.07 : 0))
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func limitsSection(_ limit: RateLimitStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("LIMITS")
            HStack {
                Text(limit.label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(limit.usedPercent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            meterBar(fraction: limit.usedPercent / 100)
            if let resets = limit.resetsAt {
                Text("Resets in \(UsageFormat.resetCountdown(to: resets))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tokensByDay(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("TOKENS BY DAY")
            let maxTokens = max(provider.byDay.map(\.totalTokens).max() ?? 1, 1)
            ForEach(provider.byDay) { day in
                let isToday = Calendar.current.isDateInToday(day.day)
                HStack(spacing: 12) {
                    Text(UsageFormat.dayLabel(day.day))
                        .font(.system(size: 11, weight: isToday ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isToday ? .primary : .secondary)
                        .frame(width: 44, alignment: .leading)
                    meterBar(fraction: Double(day.totalTokens) / Double(maxTokens), height: 4)
                        .help("\(day.day.formatted(date: .abbreviated, time: .omitted)) · \(day.totalTokens.formatted()) tokens")
                    Text(UsageFormat.tokens(day.totalTokens))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    private func tokensByModel(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("TOKENS BY MODEL")
            let maxTokens = max(provider.byModel.map(\.totalTokens).max() ?? 1, 1)
            ForEach(provider.byModel) { model in
                ZStack(alignment: .leading) {
                    // Bar-fill behind the row, screenshot-style.
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.08))
                            .frame(width: geo.size.width * CGFloat(model.totalTokens) / CGFloat(maxTokens))
                    }
                    HStack {
                        Text(prettyModelName(model.model))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(UsageFormat.tokens(model.totalTokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: 27)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.03)))
            }
            if provider.byModel.isEmpty {
                Text("no usage in the last 7 days")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .kerning(1.2)
    }

    private func meterBar(fraction: Double, height: CGFloat = 5) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
    }

    /// "claude-opus-5" -> "Claude Opus 5", "gpt-5.6-sol" -> "GPT 5.6 Sol"
    private func prettyModelName(_ raw: String) -> String {
        raw.split(separator: "-")
            .map { part -> String in
                let s = String(part)
                if s.lowercased() == "gpt" { return "GPT" }
                if s.first?.isNumber == true { return s }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }
}

/// AppModule wrapper so the dashboard opens as a workspace tile.
@MainActor
final class UsageAppModule: AppModule {
    let id = "usage"
    let name = "Usage"
    let icon = "gauge.with.needle"

    func makeView() -> AnyView {
        AnyView(UsageAppView())
    }

    func snapshot() async -> AppSnapshot {
        let store = AppServices.shared.usage
        var lines: [String] = []
        for provider in store.providers {
            let week = provider.byDay.reduce(0) { $0 + $1.totalTokens }
            var line = "\(provider.displayName): \(UsageFormat.tokens(week)) tokens over 7d"
            if let limit = provider.rateLimit {
                line += ", \(limit.label) limit \(Int(limit.usedPercent))% used"
            }
            lines.append(line)
        }
        return AppSnapshot(summary: lines.isEmpty ? "usage data not loaded yet" : lines.joined(separator: "\n"))
    }
}

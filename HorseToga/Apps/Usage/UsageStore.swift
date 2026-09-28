//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var providers: [ProviderUsage] = []
    private(set) var lastRefreshed: Date?
    private(set) var isRefreshing = false
    var selectedProviderID: String = "claude-code"

    private var timer: Timer?

    var selected: ProviderUsage? {
        providers.first { $0.providerID == selectedProviderID } ?? providers.first
    }

    func startAutoRefresh() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                AppServices.shared.usage.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) {
            let claude = ClaudeCodeUsageSource().scan()
            let codex = CodexUsageSource().scan()
            // Fireworks joins once API-key providers land (needs Keychain + HTTP).
            let fireworks = ProviderUsage(
                providerID: "fireworks",
                displayName: "Fireworks",
                planBadge: "PREPAID",
                rateLimit: nil,
                byDay: [],
                byModel: [],
                note: "add a Fireworks API key in Settings"
            )
            await MainActor.run {
                let store = AppServices.shared.usage
                store.providers = [claude, codex, fireworks]
                store.lastRefreshed = .now
                store.isRefreshing = false
            }
        }
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Lemon Squeezy store wiring + trial policy. Fill `storeID`/`productID` from the
/// LS dashboard before shipping; while they're 0 ownership checks are skipped
/// (useful with test-mode keys).
nonisolated enum LicenseConfig {
    static let storeID = 0
    static let productID = 0
    static let checkoutURL = URL(string: "https://horsetoga.lemonsqueezy.com/checkout")!
    static let apiBase = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!

    static let trialDays = 14
    /// A licensed copy keeps working this long without reaching the server.
    static let offlineGraceDays = 14
    /// How often a stored key is re-checked against the server.
    static let revalidateInterval: TimeInterval = 24 * 60 * 60
}

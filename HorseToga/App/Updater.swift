//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation
import Sparkle

/// Sparkle wrapper. The updater is started explicitly so a misconfigured build
/// (no SUPublicEDKey yet, dev signing) logs instead of throwing an alert at you.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController
    private(set) var startError: String?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func start() {
        do {
            try controller.updater.start()
        } catch {
            startError = "\(error)"
            NSLog("HorseToga: updater not started: \(error)")
        }
    }

    var canCheck: Bool { startError == nil && controller.updater.canCheckForUpdates }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        guard startError == nil else { return }
        controller.checkForUpdates(nil)
    }
}

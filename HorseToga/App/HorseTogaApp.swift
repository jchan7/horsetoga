//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

@main
struct HorseTogaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsRootView()
                .injectAppEnvironment(AppServices.shared)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppServices.shared.updater.checkForUpdates() }
            }
        }
    }
}

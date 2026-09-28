//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
        AppServices.shared.workspaceWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.shutdown()
    }

    // Dock icon / reopen brings the workspace back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppServices.shared.workspaceWindow.show() }
        return true
    }
}

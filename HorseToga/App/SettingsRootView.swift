//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        UpdatesSettingsView()
        .frame(width: 480)
    }
}

struct UpdatesSettingsView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                LabeledContent("Last checked") {
                    Text(updater.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")
                }
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                if let error = updater.startError {
                    Text("Updater unavailable in this build: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Version", value: "\(Self.version) (\(Self.build))")
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import Observation

/// Loads themes (bundled + user folder), applies them transactionally, hot-reloads
/// on disk changes, and drives the ⌘T switcher.
@MainActor
@Observable
final class ThemeStore {
    private(set) var available: [ThemeLocation] = []
    private(set) var current: ResolvedTheme = .fallback
    private(set) var lastError: String?

    // Switcher state (⌘T overlay): arrowing PREVIEWS live; Enter commits; Esc reverts.
    var switcherVisible = false
    var switcherIndex = 0
    private var committedThemeName: String?

    private var watcher: ThemeWatcher?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var userThemesDirectory: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/com.jasonchan.horsetoga/Themes")
    }

    static let selectedThemeKey = "horsetoga.selectedTheme"

    func start() {
        try? FileManager.default.createDirectory(
            at: Self.userThemesDirectory, withIntermediateDirectories: true)
        reloadList()

        // A saved choice wins. On first launch (or when the saved theme is gone)
        // show the first theme in switcher order so the window is never blank, and
        // open the switcher so the user picks one; ↩ there is what persists it.
        let saved = defaults.string(forKey: Self.selectedThemeKey)
        if let saved, available.contains(where: { $0.manifest.name == saved }) {
            apply(named: saved)
            committedThemeName = current.name
        } else if let first = available.first {
            apply(named: first.manifest.name)
            toggleSwitcher()
        }

        watcher = ThemeWatcher(directory: Self.userThemesDirectory) { [weak self] in
            self?.hotReload()
        }
    }

    func reloadList() {
        var found: [ThemeLocation] = []
        // Bundled themes ship as a folder reference: Resources/Themes/*.horsetogatheme
        if let bundled = Bundle.main.resourceURL?.appending(path: "Themes") {
            found.append(contentsOf: scan(directory: bundled, builtIn: true))
        }
        found.append(contentsOf: scan(directory: Self.userThemesDirectory, builtIn: false))
        // User themes shadow bundled ones with the same name.
        var byName: [String: ThemeLocation] = [:]
        for theme in found {
            if theme.isBuiltIn, byName[theme.manifest.name] != nil { continue }
            byName[theme.manifest.name] = theme
        }
        available = byName.values.sorted {
            ($0.manifest.order ?? 100, $0.manifest.name) < ($1.manifest.order ?? 100, $1.manifest.name)
        }
    }

    /// "Import image…": a new user theme from any picture. Colors, type, and
    /// metrics are cloned from the current theme; the picture becomes the
    /// background. Applied and kept immediately.
    func importBackground(from source: URL) {
        let stem = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .capitalized
        var name = stem.isEmpty ? "Imported" : stem
        var suffix = 2
        while available.contains(where: { $0.manifest.name == name }) {
            name = "\(stem) \(suffix)"
            suffix += 1
        }
        let folderName = name.filter { $0.isLetter || $0.isNumber }
        let folder = Self.userThemesDirectory.appending(path: "\(folderName).horsetogatheme")
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appending(path: "background.\(ext)")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)

            var manifest = try available.first(where: { $0.manifest.name == current.name })?.manifest
                ?? JSONDecoder().decode(ThemeManifest.self, from: Data(Self.fallbackManifestJSON.utf8))
            manifest.name = name
            manifest.author = NSUserName()
            manifest.order = nil
            var background = try manifest.background
                ?? JSONDecoder().decode(ThemeManifest.BackgroundSpec.self, from: Data(#"{"kind":"image"}"#.utf8))
            background.kind = "image"
            background.image = "background.\(ext)"
            background.scrimOpacity = background.scrimOpacity ?? 0.55
            manifest.background = background

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: folder.appending(path: "theme.json"))

            reloadList()
            apply(named: name)
            committedThemeName = name
            switcherIndex = available.firstIndex { $0.manifest.name == name } ?? 0
            defaults.set(name, forKey: Self.selectedThemeKey)
        } catch {
            lastError = "import failed: \(error.localizedDescription)"
        }
    }

    /// Used only when the current theme has no manifest on disk (fallback theme).
    private static let fallbackManifestJSON = ##"{"schemaVersion":1,"name":"Imported","appearance":"dark","colors":{"accent":"#E6EDF3","background":"#0E0F11","surface":"#1A1C1F","border":"#33373D","textPrimary":"#F2F4F6","textSecondary":"#C4C9D0","textTertiary":"#8A9099","error":"#F26D6D","success":"#8CCB70"},"background":{"kind":"image","scrimOpacity":0.55},"metrics":{"cornerRadius":12,"tileGap":10,"borderWidth":1}}"##

    private func scan(directory: URL, builtIn: Bool) -> [ThemeLocation] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { folder in
            guard folder.pathExtension == "horsetogatheme" else { return nil }
            let manifestURL = folder.appending(path: "theme.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ThemeManifest.self, from: data)
            else { return nil }
            return ThemeLocation(folderURL: folder, manifest: manifest, isBuiltIn: builtIn)
        }
    }

    /// Transactional: on any failure `current` is untouched and the error surfaces.
    func apply(named name: String) {
        guard let location = available.first(where: { $0.manifest.name == name }) else {
            lastError = "theme '\(name)' not found"
            return
        }
        do {
            current = try ThemeResolver.resolve(location.manifest, folderURL: location.folderURL)
            lastError = nil
        } catch {
            lastError = "\(location.manifest.name): \(error)"
        }
    }

    private func hotReload() {
        reloadList()
        // Re-resolve the active theme so an edited theme.json shows up live.
        apply(named: current.name)
        if switcherVisible == false {
            committedThemeName = current.name
        }
    }

    // MARK: - Switcher (⌘T)

    func toggleSwitcher() {
        if switcherVisible {
            revertSwitcher()
        } else {
            committedThemeName = current.name
            switcherIndex = available.firstIndex { $0.manifest.name == current.name } ?? 0
            switcherVisible = true
        }
    }

    func switcherMove(_ delta: Int) {
        guard !available.isEmpty else { return }
        switcherIndex = (switcherIndex + delta + available.count) % available.count
        apply(named: available[switcherIndex].manifest.name) // live preview
    }

    func commitSwitcher() {
        switcherVisible = false
        committedThemeName = current.name
        defaults.set(current.name, forKey: Self.selectedThemeKey)
    }

    func revertSwitcher() {
        switcherVisible = false
        if let committedThemeName { apply(named: committedThemeName) }
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import Foundation
import Testing
@testable import HorseToga

@Suite("Theme")
struct ThemeTests {
    private func manifest(_ json: String) throws -> ThemeManifest {
        try JSONDecoder().decode(ThemeManifest.self, from: Data(json.utf8))
    }

    @Test("hex parsing: #RGB, #RRGGBB, #RRGGBBAA, junk")
    func hexParsing() {
        #expect(ThemeResolver.parseHexColor("#FFFFFF") != nil)
        #expect(ThemeResolver.parseHexColor("#FFF") != nil)
        #expect(ThemeResolver.parseHexColor("#1A1B26") != nil)
        #expect(ThemeResolver.parseHexColor("#1A1B26CC") != nil)
        #expect(ThemeResolver.parseHexColor("1A1B26") == nil)   // missing #
        #expect(ThemeResolver.parseHexColor("#GGHHII") == nil)  // not hex
        #expect(ThemeResolver.parseHexColor("#12345") == nil)   // bad length
    }

    @Test("minimal manifest resolves with defaults")
    func minimalManifest() throws {
        let m = try manifest("""
        {"schemaVersion":1,"name":"Test","colors":{
            "accent":"#7AA2F7","background":"#1A1B26","textPrimary":"#C0CAF5"}}
        """)
        let resolved = try ThemeResolver.resolve(m, folderURL: URL(filePath: "/tmp"))
        #expect(resolved.name == "Test")
        #expect(resolved.cornerRadius == 12)
        #expect(resolved.tileGap == 10)
        #expect(resolved.baseSize == 13)
    }

    @Test("missing required color throws (transactional apply depends on this)")
    func missingColorThrows() throws {
        let m = try manifest("""
        {"schemaVersion":1,"name":"Broken","colors":{"accent":"#FFFFFF"}}
        """)
        #expect(throws: ThemeResolver.ResolveError.self) {
            _ = try ThemeResolver.resolve(m, folderURL: URL(filePath: "/tmp"))
        }
    }

    @Test("missing background image throws, not crashes")
    func missingImageThrows() throws {
        let m = try manifest("""
        {"schemaVersion":1,"name":"NoImage","colors":{
            "accent":"#FFF","background":"#000000","textPrimary":"#FFFFFF"},
         "background":{"kind":"image","image":"nope.png"}}
        """)
        #expect(throws: ThemeResolver.ResolveError.self) {
            _ = try ThemeResolver.resolve(m, folderURL: URL(filePath: "/tmp"))
        }
    }

    @Test("legibility: scrim never drops below requested floor and rises for low contrast")
    func scrimEnforcement() {
        // A mid-gray image: light text needs real scrim to hit 4.5:1.
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor(white: 0.5, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let enforced = ThemeResolver.enforcedScrim(
            image: image,
            requested: 0.05,        // author asks for nearly nothing
            minScrim: 0.15,
            targetContrast: 4.5,
            textLuminance: 0.9      // near-white text
        )
        #expect(enforced >= 0.15)
        let lax = ThemeResolver.enforcedScrim(
            image: image, requested: 0.05, minScrim: 0.15,
            targetContrast: 1.0,    // trivially satisfied
            textLuminance: 0.9
        )
        #expect(enforced >= lax)
        #expect(enforced <= 0.85)
    }

    @Test("every bundled theme decodes and resolves")
    func bundledThemesResolve() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()             // HorseTogaTests/
            .deletingLastPathComponent()             // repo root
            .appending(path: "HorseToga/Resources/Themes")
        let folders = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "horsetogatheme" }
        #expect(!folders.isEmpty)
        for folder in folders {
            let data = try Data(contentsOf: folder.appending(path: "theme.json"))
            let m = try JSONDecoder().decode(ThemeManifest.self, from: data)
            let resolved = try ThemeResolver.resolve(m, folderURL: folder)
            #expect(!resolved.name.isEmpty)
        }
    }

    private func throwawayDefaults() -> (UserDefaults, String) {
        let suiteName = "horsetoga-theme-store-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test("first launch shows the first theme and opens the switcher")
    @MainActor
    func firstLaunchOpensSwitcher() {
        let (defaults, suiteName) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ThemeStore(defaults: defaults)
        store.start()
        #expect(!store.available.isEmpty)
        #expect(store.switcherVisible)
        #expect(store.switcherIndex == 0)
        #expect(store.current.name == store.available.first?.manifest.name)
        #expect(store.lastError == nil)
        // Nothing is persisted until the user keeps a theme with ↩.
        #expect(defaults.string(forKey: ThemeStore.selectedThemeKey) == nil)
        store.commitSwitcher()
        #expect(!store.switcherVisible)
        #expect(defaults.string(forKey: ThemeStore.selectedThemeKey) == store.current.name)
    }

    @Test("a saved theme is restored quietly; a missing one reopens the switcher")
    @MainActor
    func savedThemeRestored() throws {
        let (defaults, suiteName) = throwawayDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ThemeStore(defaults: defaults)
        probe.reloadList()
        let last = try #require(probe.available.last?.manifest.name)

        defaults.set(last, forKey: ThemeStore.selectedThemeKey)
        let restored = ThemeStore(defaults: defaults)
        restored.start()
        #expect(!restored.switcherVisible)
        #expect(restored.current.name == last)

        defaults.set("Theme That Was Deleted", forKey: ThemeStore.selectedThemeKey)
        let orphaned = ThemeStore(defaults: defaults)
        orphaned.start()
        #expect(orphaned.switcherVisible)
        #expect(orphaned.current.name == orphaned.available.first?.manifest.name)
    }
}

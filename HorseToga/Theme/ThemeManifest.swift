//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Pure data, decoded from a theme folder's theme.json. Two-stage on purpose:
/// SwiftUI's Color/Font/Material aren't Codable, so the manifest stays plain and
/// ThemeResolver turns it into live values.
nonisolated struct ThemeManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var author: String?
    /// Switcher position (lower first); unset sorts after ordered themes.
    var order: Int?
    /// "dark" | "light" — drives system control appearance under the theme.
    var appearance: String?
    var colors: [String: String]
    var background: BackgroundSpec?
    /// "none" | "thin" | "regular" | "thick" | "glass"
    var material: String?
    var typography: TypographySpec?
    var metrics: MetricsSpec?
    var legibility: LegibilitySpec?

    nonisolated struct BackgroundSpec: Codable, Sendable, Equatable {
        /// "color" | "gradient" | "image"
        var kind: String
        /// Relative path inside the theme folder (image kind).
        var image: String?
        var gradientColors: [String]?
        /// Degrees, 0 = left→right, 90 = top→bottom.
        var gradientAngle: Double?
        /// Base scrim over images; legibility enforcement may raise it, never lower.
        var scrimOpacity: Double?
    }

    nonisolated struct TypographySpec: Codable, Sendable, Equatable {
        /// PostScript family name; nil = system monospaced. Fonts bundled in the
        /// theme folder's fonts/ are registered before resolution.
        var fontFamily: String?
        var baseSize: Double?
    }

    nonisolated struct MetricsSpec: Codable, Sendable, Equatable {
        var cornerRadius: Double?
        var tileGap: Double?
        var borderWidth: Double?
    }

    nonisolated struct LegibilitySpec: Codable, Sendable, Equatable {
        var minScrim: Double?
        var targetContrast: Double?
    }
}

/// A discovered theme on disk (or bundled).
nonisolated struct ThemeLocation: Identifiable, Sendable, Equatable {
    var folderURL: URL
    var manifest: ThemeManifest
    var isBuiltIn: Bool
    var id: String { manifest.name }
}

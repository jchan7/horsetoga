//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

/// Live theme values every view reads from the environment. Immutable value;
/// switching themes swaps the whole struct atomically.
struct ResolvedTheme {
    var name: String
    var appearance: ColorScheme?

    // Colors
    var accent: Color
    var backgroundColor: Color
    var surface: Color
    var border: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var errorColor: Color
    var successColor: Color

    // Background treatment
    enum Background {
        case color(Color)
        case gradient([Color], angleDegrees: Double)
        case image(NSImage, scrimOpacity: Double, scrimColor: Color)
    }
    var background: Background

    // Chrome
    var material: Material?
    var cornerRadius: CGFloat
    var tileGap: CGFloat
    var borderWidth: CGFloat

    // Typography
    var fontFamily: String? // nil = system monospaced
    var baseSize: CGFloat

    func font(_ size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let pointSize = size ?? baseSize
        if let fontFamily {
            return .custom(fontFamily, size: pointSize).weight(weight)
        }
        return .system(size: pointSize, weight: weight, design: .monospaced)
    }

    /// AppKit twin of `font(_:weight:)` for NSTextView-based inputs.
    func nsFont(_ size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let pointSize = size ?? baseSize
        if let fontFamily, let custom = NSFont(name: fontFamily, size: pointSize) {
            return custom
        }
        return .monospacedSystemFont(ofSize: pointSize, weight: weight)
    }

    /// Fallback used before ThemeStore loads and whenever resolution fails:
    /// the neutral "HorseToga Mono" look.
    static let fallback = ResolvedTheme(
        name: "HorseToga Mono",
        appearance: .dark,
        accent: Color(red: 0.90, green: 0.93, blue: 0.95),
        backgroundColor: Color(red: 0.043, green: 0.051, blue: 0.063),
        surface: Color(red: 0.078, green: 0.090, blue: 0.106),
        border: Color(red: 0.149, green: 0.169, blue: 0.200),
        textPrimary: Color(red: 0.90, green: 0.93, blue: 0.95),
        textSecondary: Color(red: 0.608, green: 0.639, blue: 0.686),
        textTertiary: Color(red: 0.361, green: 0.392, blue: 0.439),
        errorColor: Color(red: 0.95, green: 0.44, blue: 0.44),
        successColor: Color(red: 0.24, green: 0.84, blue: 0.40),
        background: .color(Color(red: 0.043, green: 0.051, blue: 0.063)),
        material: nil,
        cornerRadius: 12,
        tileGap: 10,
        borderWidth: 1,
        fontFamily: nil,
        baseSize: 13
    )
}

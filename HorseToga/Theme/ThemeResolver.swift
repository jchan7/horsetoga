//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import CoreImage
import CoreText
import SwiftUI

/// Manifest -> live values. Resolution is TRANSACTIONAL: any hard failure throws
/// and the previous theme stays; a malformed theme must never blank the UI.
nonisolated enum ThemeResolver {

    enum ResolveError: Error, CustomStringConvertible {
        case badColor(key: String, value: String)
        case missingColor(String)
        case imageNotFound(String)
        var description: String {
            switch self {
            case .badColor(let key, let value): "colors.\(key): '\(value)' is not a valid hex color"
            case .missingColor(let key): "colors.\(key) is required"
            case .imageNotFound(let path): "background.image '\(path)' not found in theme folder"
            }
        }
    }

    static func resolve(_ manifest: ThemeManifest, folderURL: URL) throws -> ResolvedTheme {
        registerBundledFonts(in: folderURL)

        func color(_ key: String) throws -> Color {
            guard let raw = manifest.colors[key] else { throw ResolveError.missingColor(key) }
            guard let parsed = parseHexColor(raw) else { throw ResolveError.badColor(key: key, value: raw) }
            return parsed
        }
        // Optional with fallback to another key
        func colorOr(_ key: String, _ fallback: Color) -> Color {
            guard let raw = manifest.colors[key], let parsed = parseHexColor(raw) else { return fallback }
            return parsed
        }

        let backgroundColor = try color("background")
        let textPrimary = try color("textPrimary")
        let accent = try color("accent")
        let surface = colorOr("surface", backgroundColor)
        let textSecondary = colorOr("textSecondary", textPrimary.opacity(0.65))
        let legibility = manifest.legibility

        let background = try resolveBackground(
            manifest.background,
            folderURL: folderURL,
            fallbackColor: backgroundColor,
            textPrimary: textPrimary,
            legibility: legibility
        )

        return ResolvedTheme(
            name: manifest.name,
            appearance: manifest.appearance == "light" ? .light : manifest.appearance == "dark" ? .dark : nil,
            accent: accent,
            backgroundColor: backgroundColor,
            surface: surface,
            border: colorOr("border", textPrimary.opacity(0.12)),
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            textTertiary: colorOr("textTertiary", textPrimary.opacity(0.4)),
            errorColor: colorOr("error", Color(red: 0.95, green: 0.44, blue: 0.44)),
            successColor: colorOr("success", Color(red: 0.24, green: 0.84, blue: 0.40)),
            background: background,
            material: material(for: manifest.material),
            cornerRadius: CGFloat(manifest.metrics?.cornerRadius ?? 12),
            tileGap: CGFloat(manifest.metrics?.tileGap ?? 10),
            borderWidth: CGFloat(manifest.metrics?.borderWidth ?? 1),
            fontFamily: manifest.typography?.fontFamily,
            baseSize: CGFloat(manifest.typography?.baseSize ?? 13)
        )
    }

    // MARK: - Background

    private static func resolveBackground(
        _ spec: ThemeManifest.BackgroundSpec?,
        folderURL: URL,
        fallbackColor: Color,
        textPrimary: Color,
        legibility: ThemeManifest.LegibilitySpec?
    ) throws -> ResolvedTheme.Background {
        guard let spec else { return .color(fallbackColor) }
        switch spec.kind {
        case "gradient":
            let colors = (spec.gradientColors ?? []).compactMap(parseHexColor)
            guard colors.count >= 2 else { return .color(fallbackColor) }
            return .gradient(colors, angleDegrees: spec.gradientAngle ?? 90)
        case "image":
            guard let relative = spec.image else { return .color(fallbackColor) }
            let url = folderURL.appending(path: relative)
            guard let image = NSImage(contentsOf: url) else {
                throw ResolveError.imageNotFound(relative)
            }
            let scrim = enforcedScrim(
                image: image,
                requested: spec.scrimOpacity ?? 0.3,
                minScrim: legibility?.minScrim ?? 0.15,
                targetContrast: legibility?.targetContrast ?? 4.5,
                textLuminance: relativeLuminance(of: textPrimary)
            )
            return .image(image, scrimOpacity: scrim, scrimColor: fallbackColor)
        default:
            return .color(fallbackColor)
        }
    }

    /// Raise the scrim until estimated text contrast over (scrim ⊕ image average)
    /// meets the target. Theme authors can ask for less; they don't get it.
    static func enforcedScrim(
        image: NSImage,
        requested: Double,
        minScrim: Double,
        targetContrast: Double,
        textLuminance: Double
    ) -> Double {
        let imageLuminance = averageLuminance(of: image) ?? 0.35
        var scrim = max(requested, max(minScrim, 0.10))
        while scrim < 0.85 {
            // Scrim color approximated as near-black/near-white via text tone inverse.
            let scrimLuminance = textLuminance > 0.5 ? 0.02 : 0.95
            let effective = scrim * scrimLuminance + (1 - scrim) * imageLuminance
            let lighter = max(textLuminance, effective)
            let darker = min(textLuminance, effective)
            let contrast = (lighter + 0.05) / (darker + 0.05)
            if contrast >= targetContrast { break }
            scrim += 0.05
        }
        return min(scrim, 0.85)
    }

    /// CIAreaAverage over the full image -> WCAG relative luminance.
    static func averageLuminance(of image: NSImage) -> Double? {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }
        let extent = ciImage.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        func linearize(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(pixel[0]) + 0.7152 * linearize(pixel[1]) + 0.0722 * linearize(pixel[2])
    }

    static func relativeLuminance(of color: Color) -> Double {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func linearize(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(ns.redComponent)
            + 0.7152 * linearize(ns.greenComponent)
            + 0.0722 * linearize(ns.blueComponent)
    }

    // MARK: - Tokens

    static func material(for token: String?) -> Material? {
        switch token {
        case nil, "none": nil
        case "thin": .ultraThinMaterial
        case "regular": .regularMaterial
        case "thick": .thickMaterial
        case "glass": .ultraThinMaterial // GlassEffectContainer adoption tracked separately
        default: nil
        }
    }

    /// #RGB, #RRGGBB, or #RRGGBBAA.
    static func parseHexColor(_ raw: String) -> Color? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        if hex.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    private static func registerBundledFonts(in folderURL: URL) {
        let fontsDir = folderURL.appending(path: "fonts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

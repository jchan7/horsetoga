//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

extension EnvironmentValues {
    @Entry var theme: ResolvedTheme = .fallback
}

/// Wraps every root (panel, workspace, settings) so the resolved theme, accent
/// tint, and color scheme flow together. Sits INSIDE the store injection.
struct ThemedRoot<Content: View>: View {
    @Environment(ThemeStore.self) private var themes
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.theme, themes.current)
            .tint(themes.current.accent)
            .preferredColorScheme(themes.current.appearance)
    }
}

/// The theme's background treatment: color, gradient, or image + enforced scrim.
struct ThemeBackgroundView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        switch theme.background {
        case .color(let color):
            color.ignoresSafeArea()
        case .gradient(let colors, let angle):
            LinearGradient(
                colors: colors,
                startPoint: startPoint(for: angle),
                endPoint: endPoint(for: angle)
            )
            .ignoresSafeArea()
        case .image(let image, let scrim, let scrimColor):
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(scrimColor.opacity(scrim))
            }
            .ignoresSafeArea()
        }
    }

    private func startPoint(for angle: Double) -> UnitPoint {
        let radians = (angle - 90) * .pi / 180
        return UnitPoint(x: 0.5 - cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }

    private func endPoint(for angle: Double) -> UnitPoint {
        let radians = (angle - 90) * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 + sin(radians) / 2)
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ⌘T: Omarchy-style theme menu. Arrowing applies the theme LIVE to the whole
/// app (that's the preview), Enter keeps it, Escape puts the old one back.
struct ThemeSwitcherOverlay: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme

    /// The switcher is chrome, not previewed content: its text stays in the
    /// neutral monospaced face so arrowing through themes never reflows the panel
    /// or changes how the theme names are set — only the live app behind it does.
    private func fixedFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("THEME")
                    .font(fixedFont(10, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Text("↑↓ preview · ↩ keep · ⎋ revert")
                    .font(fixedFont(10))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            VStack(spacing: 2) {
                ForEach(Array(themes.available.enumerated()), id: \.element.id) { index, location in
                    let isSelected = index == themes.switcherIndex
                    HStack(spacing: 10) {
                        swatches(for: location.manifest)
                        // Fixed neutral-mono typography, identical for every row and
                        // independent of the previewed theme — only the color moves.
                        Text(location.manifest.name)
                            .font(fixedFont(12.5, weight: .medium))
                            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        Spacer()
                        if isSelected {
                            Text("selected")
                                .font(fixedFont(9))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(.clear))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        themes.switcherIndex = index
                        themes.apply(named: location.manifest.name)
                        themes.commitSwitcher()
                    }
                }
            }
            .padding(8)

            Divider().opacity(0.4)
            Button(action: importImage) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Import image…")
                        .font(fixedFont(11.5, weight: .medium))
                    Spacer()
                    Text("new theme from a picture")
                        .font(fixedFont(9.5))
                        .foregroundStyle(theme.textTertiary)
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)

            if let error = themes.lastError {
                Divider().opacity(0.4)
                Text(error)
                    .font(fixedFont(10.5))
                    .foregroundStyle(theme.errorColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.surface.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
    }

    private func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the new theme's background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        themes.importBackground(from: url)
    }

    private func swatches(for manifest: ThemeManifest) -> some View {
        HStack(spacing: 3) {
            ForEach(["background", "surface", "accent", "textPrimary"], id: \.self) { key in
                Circle()
                    .fill(ThemeResolver.parseHexColor(manifest.colors[key] ?? "") ?? .gray)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
        }
    }
}

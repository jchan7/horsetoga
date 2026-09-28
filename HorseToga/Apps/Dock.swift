//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Immediate, app-rendered hover label for the bottom dock. Native `.help`
/// remains attached for accessibility, but is not reliable visually in HorseToga's
/// full-size custom window.
private struct DockTooltipModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let text: String
    /// Corner docks grow the label inward: the bottom-right switcher aligns
    /// `.topTrailing` (grows left), the bottom-left docks `.topLeading` (grows
    /// right), so a wide label never spills past the window edge.
    var alignment: Alignment = .top
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: alignment) {
                if isHovering {
                    Text(text)
                        .font(theme.font(10, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(theme.border, lineWidth: theme.borderWidth)
                                )
                        )
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                        .fixedSize()
                        .offset(y: -34)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(isHovering ? 10 : 0)
            .help(text)
    }
}

extension View {
    func dockTooltip(_ text: String, alignment: Alignment = .top) -> some View {
        modifier(DockTooltipModifier(text: text, alignment: alignment))
    }
}

/// App dock: a flat capsule in the bottom-left corner, styled to match the
/// ViewModeSwitcher capsule in the bottom-right. Clicking toggles that app's
/// full-window section.
struct DockView: View {
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    /// Bottom inset content views apply so nothing sits under the bottom bar.
    static let clearance: CGFloat = 38

    var body: some View {
        HStack(spacing: 2) {
            ForEach(apps.modules.map { $0.id }, id: \.self) { id in
                if let module = apps.module(id) {
                    let isActive = apps.activeSectionID == id
                    Button {
                        apps.toggleSection(id)
                    } label: {
                        Image(systemName: module.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isActive ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.textTertiary))
                            .frame(width: 26, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isActive ? theme.textPrimary.opacity(0.08) : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .dockTooltip(helpText(for: module), alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.textPrimary.opacity(0.05)))
    }

    private func helpText(for module: any AppModule) -> String {
        guard let shortcut = AppDockShortcut.forApp(module.id) else { return module.name }
        return "\(module.name) — \(shortcut.label) · ⌘⇧C cycles"
    }
}

/// A dock app opened as its own full-window section over the workspace.
struct AppSectionView: View {
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    let module: any AppModule

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            module.makeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .clipShape(shape)
        .padding(theme.tileGap)
        .padding(.bottom, DockView.clearance) // keep clear of the bottom bar
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: module.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(module.name)
                .font(theme.font(11, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("esc")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Button {
                apps.closeSection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.textPrimary.opacity(0.04))
    }
}

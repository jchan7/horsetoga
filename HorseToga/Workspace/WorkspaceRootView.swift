//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

struct WorkspaceRootView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @Environment(AppRegistry.self) private var apps
    @Environment(CommandPaletteStore.self) private var palette
    @Environment(ModelPickerStore.self) private var modelPicker

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            switch store.active.viewMode {
            case .tiles:
                if store.active.tree.isEmpty {
                    EmptyWorkspaceView()
                } else {
                    TileTreeView(workspace: store.active)
                }
            case .canvas:
                CanvasView(workspace: store.active)
            case .inbox:
                InboxView(workspace: store.active)
            case .tracker:
                TrackerView(workspace: store.active)
            case .rookery:
                RookeryView(workspace: store.active)
            }

            // Dock app opened as its own section, above the workspace.
            if let appID = apps.activeSectionID, let module = apps.module(appID) {
                AppSectionView(module: module)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            bottomBar

            if palette.visible {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { palette.close() }
                CommandPaletteView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if themes.switcherVisible {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { themes.revertSwitcher() }
                ThemeSwitcherOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if modelPicker.visible {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { modelPicker.close() }
                ModelPickerOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: themes.switcherVisible)
        .animation(.easeOut(duration: 0.12), value: apps.activeSectionID)
        .animation(.easeOut(duration: 0.12), value: palette.visible)
        .animation(.easeOut(duration: 0.12), value: modelPicker.visible)
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 8) {
                DockView()
                ScreensDock()
                Spacer()
                ViewModeSwitcher()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .allowsHitTesting(true)
    }
}

struct EmptyWorkspaceView: View {
    @Environment(CommandPaletteStore.self) private var palette
    @Environment(\.theme) private var theme

    // Only ~8 shortcuts show up front; the rest scroll into view.
    private let rowHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 2
    private let topPadding: CGFloat = 8
    private let visibleRows = 8

    private var panelHeight: CGFloat {
        // Eight full rows, plus half of the ninth so the list reads as scrollable.
        topPadding + CGFloat(visibleRows) * rowHeight
            + CGFloat(visibleRows - 1) * rowSpacing + rowHeight * 0.5
    }

    var body: some View {
        // A compact, centered panel; every shortcut is still reachable by scrolling.
        ScrollView(.vertical) {
            VStack(spacing: rowSpacing) {
                ForEach(Array(palette.homeShortcuts.enumerated()), id: \.offset) { _, command in
                    ActionRow(label: command.title.lowercased(), key: command.key ?? "", height: rowHeight) {
                        command.action()
                    }
                }
            }
            .padding(.vertical, topPadding)
        }
        .scrollIndicators(.hidden)
        .frame(width: 300, height: panelHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(y: 44)
    }
}

private struct ActionRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let key: String
    var height: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(theme.font(11))
                    .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                Spacer()
                Text(key)
                    .font(theme.font(11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.textPrimary.opacity(0.08)))
            }
            .padding(.horizontal, 10)
            .frame(width: 260, height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(hovering ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

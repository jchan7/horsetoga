//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Email-client projection of the workspace: every tile is an inbox row on the
/// left, the selected one opens full-height on the right.
struct InboxView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    var workspace: WorkspaceModel

    var body: some View {
        let items = workspace.surfaceItems
        HStack(spacing: theme.tileGap) {
            sidebar(items)
            detail(items)
        }
        .padding(theme.tileGap)
        .padding(.bottom, DockView.clearance)
    }

    private func sidebar(_ items: [(id: TileID, surface: SurfaceKind)]) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Inbox")
                    .font(theme.font(12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("\(items.count)")
                    .font(theme.font(11))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button {
                    store.newSession(providerID: providers.defaultProviderID)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("New session (⌘↩)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.4)
            if items.isEmpty {
                SurfaceEmptyState(icon: "tray", message: "no chats yet — ⌘↩ starts one")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items, id: \.id) { item in
                            InboxRow(
                                surface: item.surface,
                                isSelected: workspace.focused == item.id
                            ) { workspace.focused = item.id }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 300)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(
            store.browseFocused ? theme.accent.opacity(0.85) : theme.border,
            lineWidth: store.browseFocused ? max(theme.borderWidth, 1.5) : theme.borderWidth
        ))
        .clipShape(shape)
    }

    @ViewBuilder
    private func detail(_ items: [(id: TileID, surface: SurfaceKind)]) -> some View {
        if let selected = selectedSurfaceItem(in: workspace) {
            // While the list owns the keyboard (⇧⇥) the open chat isn't the active
            // selection, so it shows unfocused chrome.
            TileView(tileID: selected.id, surface: selected.surface, isFocused: !store.browseFocused, isZoomed: false)
                .id(selected.id)
        } else {
            SurfaceEmptyState(icon: "bubble.left", message: "select a chat")
        }
    }
}

private struct InboxRow: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    let surface: SurfaceKind
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(surfaceStatusColor(surface, store: store, theme: theme))
                        .frame(width: 6, height: 6)
                    Text(surfaceTitle(surface, store: store, apps: apps))
                        .font(theme.font(11, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(surfaceBadge(surface, store: store, providers: providers))
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                }
                Text(surfacePreview(surface, store: store, apps: apps))
                    .font(theme.font(10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                        ? AnyShapeStyle(theme.accent.opacity(0.14))
                        : hovering ? AnyShapeStyle(theme.textPrimary.opacity(0.04)) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

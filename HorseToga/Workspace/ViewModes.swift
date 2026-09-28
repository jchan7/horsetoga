//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

// Shared pieces for the non-tiles view modes (inbox, tracker, rookery). Every
// mode renders the same surfaceItems and drives selection through
// workspace.focused, so switching modes never loses state.

/// Bottom-bar capsule for one-click switching between view modes.
struct ViewModeSwitcher: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceViewMode.allCases, id: \.self) { mode in
                let isActive = store.active.viewMode == mode
                Button {
                    store.setViewMode(mode)
                } label: {
                    Image(systemName: mode.icon)
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
                .dockTooltip("\(mode.label) view — ⌘⇧V cycles", alignment: .topTrailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.textPrimary.opacity(0.05)))
    }
}

extension ConversationViewModel {
    /// One-line preview for list rows and speech bubbles.
    var previewText: String {
        if !liveText.isEmpty { return String(liveText.suffix(160)) }
        for entry in entries.reversed() {
            switch entry.kind {
            case .assistant(let text), .user(let text):
                if !text.isEmpty { return text }
            case .error(let text):
                return text
            case .tool(let name, _, _, _):
                return "⚙ \(name)"
            case .reasoning, .notice:
                continue
            }
        }
        return "no messages yet"
    }
}

// MARK: - Surface lookups (shared row metadata)

@MainActor
func surfaceStatus(_ surface: SurfaceKind, store: WorkspaceStore) -> RunStatus? {
    guard case .session(let id) = surface else { return nil }
    return store.runner(for: id)?.viewModel.status
}

@MainActor
func surfaceStatusColor(_ surface: SurfaceKind, store: WorkspaceStore, theme: ResolvedTheme) -> Color {
    switch surfaceStatus(surface, store: store) {
    case .some(.connecting): .yellow
    case .some(.streaming), .some(.runningTool): theme.successColor
    case .some(.failed): theme.errorColor
    default: theme.textPrimary.opacity(0.25)
    }
}

@MainActor
func surfaceTitle(_ surface: SurfaceKind, store: WorkspaceStore, apps: AppRegistry) -> String {
    switch surface {
    case .session(let id): store.runner(for: id)?.viewModel.title ?? "Session"
    case .app(let appID): apps.module(appID)?.name ?? appID.capitalized
    }
}

@MainActor
func surfaceBadge(_ surface: SurfaceKind, store: WorkspaceStore, providers: ProviderRegistry) -> String {
    switch surface {
    case .session(let id):
        store.runner(for: id).map { providers.provider($0.viewModel.providerID)?.displayName ?? "" } ?? ""
    case .app: "app"
    }
}

@MainActor
func surfacePreview(_ surface: SurfaceKind, store: WorkspaceStore, apps: AppRegistry) -> String {
    switch surface {
    case .session(let id): store.runner(for: id)?.viewModel.previewText ?? "session ended"
    case .app: "built-in app"
    }
}

/// The item the current selection points at, falling back to the first tile.
@MainActor
func selectedSurfaceItem(in workspace: WorkspaceModel) -> (id: TileID, surface: SurfaceKind)? {
    let items = workspace.surfaceItems
    if let focused = workspace.focused, let hit = items.first(where: { $0.id == focused }) {
        return hit
    }
    return items.first
}

/// Centered hint for a mode with nothing to show.
struct SurfaceEmptyState: View {
    @Environment(\.theme) private var theme
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            Text(message)
                .font(theme.font(11))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas view

/// Obsidian-style endless canvas: every chat is a freeform card. Drag a card by
/// its header to move it, drag the empty background to pan, pinch (or the ± / 1:1
/// controls) to zoom. Positions live on the store so they stick while you roam.
struct CanvasView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    var workspace: WorkspaceModel

    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var dragBase: [TileID: CGPoint] = [:]
    @State private var viewport: CGSize = .zero
    @State private var didSeed = false

    private let cardW: CGFloat = 340
    private let cardH: CGFloat = 400
    private let gap: CGFloat = 40

    var body: some View {
        let items = workspace.surfaceItems
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dots
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .simultaneousGesture(zoomGesture)
                    .onTapGesture { workspace.focused = nil }

                if items.isEmpty {
                    SurfaceEmptyState(icon: "square.on.square.dashed",
                                      message: "empty canvas — ⌘↩ drops a chat here")
                }

                ForEach(items, id: \.id) { item in
                    card(item)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { controls }
            .onAppear {
                viewport = geo.size
                seedMissing(items: items, in: geo.size)
            }
            .onChange(of: geo.size) { _, size in viewport = size }
            .onChange(of: items.count) { _, _ in seedMissing(items: items, in: geo.size) }
        }
        .padding(theme.tileGap)
        .padding(.bottom, DockView.clearance)
    }

    @ViewBuilder
    private func card(_ item: (id: TileID, surface: SurfaceKind)) -> some View {
        let isFocused = workspace.focused == item.id
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            cardHeader(item, isFocused: isFocused)
                .gesture(cardDrag(item.id))
            Divider().opacity(0.4)
            cardContent(item.surface, isFocused: isFocused)
        }
        .frame(width: cardW, height: cardH)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(isFocused ? theme.accent : theme.border,
                                    lineWidth: isFocused ? 1.5 : theme.borderWidth))
        .clipShape(shape)
        .shadow(color: .black.opacity(isFocused ? 0.32 : 0.22), radius: isFocused ? 16 : 10, y: 5)
        .scaleEffect(zoom, anchor: .center)
        .position(screenCenter(item.id))
        .simultaneousGesture(TapGesture().onEnded { workspace.focused = item.id })
    }

    private func cardHeader(_ item: (id: TileID, surface: SurfaceKind), isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2")
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
            Circle()
                .fill(surfaceStatusColor(item.surface, store: store, theme: theme))
                .frame(width: 6, height: 6)
            Text(surfaceTitle(item.surface, store: store, apps: apps))
                .font(theme.font(11, weight: .semibold))
                .foregroundStyle(isFocused ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if case .session(let id) = item.surface, let runner = store.runner(for: id) {
                ProviderMenu(viewModel: runner.viewModel)
            }
            Button {
                store.active.focused = item.id
                store.closeFocusedTile()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(theme.textPrimary.opacity(isFocused ? 0.05 : 0.02))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cardContent(_ surface: SurfaceKind, isFocused: Bool) -> some View {
        switch surface {
        case .session(let id):
            if let runner = store.runner(for: id) {
                SessionTileView(runner: runner, isFocusedTile: isFocused)
            } else {
                SurfaceEmptyState(icon: "bubble.left", message: "session ended")
            }
        case .app(let appID):
            if let module = apps.module(appID) {
                module.makeView()
            } else {
                AppSurfacePlaceholder(appID: appID)
            }
        }
    }

    private func screenCenter(_ id: TileID) -> CGPoint {
        let c = store.canvasPositions[id] ?? .zero
        return CGPoint(x: pan.width + c.x * zoom, y: pan.height + c.y * zoom)
    }

    private func cardDrag(_ id: TileID) -> some Gesture {
        // Global coordinate space is essential: the card is repositioned by this
        // very drag, so a local-space translation would chase its own moving frame
        // and diverge to NaN — taking the whole layout (every card) down with it.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if dragBase[id] == nil {
                    dragBase[id] = store.canvasPositions[id] ?? .zero
                    workspace.focused = id
                }
                let base = dragBase[id]!
                store.canvasPositions[id] = CGPoint(
                    x: base.x + value.translation.width / zoom,
                    y: base.y + value.translation.height / zoom
                )
            }
            .onEnded { _ in dragBase[id] = nil }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in pan = CGSize(width: panBase.width + value.translation.width,
                                               height: panBase.height + value.translation.height) }
            .onEnded { _ in panBase = pan }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in setZoom(zoomBase * scale) }
            .onEnded { _ in zoomBase = zoom }
    }

    /// Zoom about the viewport centre so the middle of the screen stays put.
    private func setZoom(_ target: CGFloat) {
        let z = min(2.2, max(0.35, target))
        guard viewport != .zero else { zoom = z; return }
        let s = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let c = CGPoint(x: (s.x - pan.width) / zoom, y: (s.y - pan.height) / zoom)
        pan = CGSize(width: s.x - c.x * z, height: s.y - c.y * z)
        panBase = pan
        zoom = z
    }

    /// Give any card without a position a slot — a tidy grid on first paint, and
    /// the current view centre for chats created later.
    private func seedMissing(items: [(id: TileID, surface: SurfaceKind)], in size: CGSize) {
        let cols = max(1, Int(((size.width - gap) / (cardW + gap)).rounded(.down)))
        var placed = store.canvasPositions.count
        for item in items where store.canvasPositions[item.id] == nil {
            if !didSeed {
                let col = placed % cols, row = placed / cols
                store.canvasPositions[item.id] = CGPoint(
                    x: gap + cardW / 2 + CGFloat(col) * (cardW + gap),
                    y: gap + cardH / 2 + CGFloat(row) * (cardH + gap)
                )
            } else {
                let jitter = CGFloat((placed % 5) * 28)
                store.canvasPositions[item.id] = CGPoint(
                    x: (size.width / 2 - pan.width) / zoom + jitter,
                    y: (size.height / 2 - pan.height) / zoom + jitter
                )
            }
            placed += 1
        }
        didSeed = true
    }

    private var controls: some View {
        HStack(spacing: 4) {
            controlButton("plus") { addChat() }
            Divider().frame(height: 14).opacity(0.4)
            controlButton("minus.magnifyingglass") { setZoom(zoom - 0.2); zoomBase = zoom }
            Button { setZoom(1); zoomBase = 1 } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(theme.font(10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 42)
            }
            .buttonStyle(.plain)
            controlButton("plus.magnifyingglass") { setZoom(zoom + 0.2); zoomBase = zoom }
            Divider().frame(height: 14).opacity(0.4)
            controlButton("scope") { recenter() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.surface.opacity(0.9)))
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(16)
    }

    private func controlButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addChat() {
        store.newSession(providerID: providers.defaultProviderID)
        if let id = store.active.focused {
            store.canvasPositions[id] = CGPoint(
                x: (viewport.width / 2 - pan.width) / zoom,
                y: (viewport.height / 2 - pan.height) / zoom
            )
        }
    }

    /// Reset zoom and pan so the focused card (or the first) lands in the middle.
    private func recenter() {
        let target = workspace.focused ?? workspace.surfaceItems.first?.id
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            zoomBase = 1
            if let target, let c = store.canvasPositions[target], viewport != .zero {
                pan = CGSize(width: viewport.width / 2 - c.x, height: viewport.height / 2 - c.y)
            } else {
                pan = .zero
            }
            panBase = pan
        }
    }

    private var dots: some View {
        Canvas { ctx, size in
            let step = max(12, 28 * zoom)
            let radius = max(0.5, 1.1 * zoom)
            let ox = pan.width.truncatingRemainder(dividingBy: step)
            let oy = pan.height.truncatingRemainder(dividingBy: step)
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                        with: .color(theme.textPrimary.opacity(0.14))
                    )
                    x += step
                }
                y += step
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

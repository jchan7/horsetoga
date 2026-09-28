//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Issue-tracker projection, agile-board style: one column per status lane,
/// sessions as cards inside them, with the selected card open in a right-hand
/// inspector.
struct TrackerView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    var workspace: WorkspaceModel

    private enum Lane: String, CaseIterable {
        case new = "New"
        case running = "Running"
        case failed = "Failed"
        case done = "Done"
        case apps = "Apps"

        var icon: String {
            switch self {
            case .new: "circle.dotted"
            case .running: "play.circle.fill"
            case .failed: "exclamationmark.circle.fill"
            case .done: "checkmark.circle.fill"
            case .apps: "square.grid.2x2"
            }
        }
    }

    var body: some View {
        let items = workspace.surfaceItems
        HStack(spacing: theme.tileGap) {
            board(items)
            if let selected = selectedSurfaceItem(in: workspace) {
                // While the board owns the keyboard (⇧⇥) the open chat isn't the
                // active selection, so it shows unfocused chrome.
                TileView(tileID: selected.id, surface: selected.surface, isFocused: !store.browseFocused, isZoomed: false)
                    .id(selected.id)
                    .frame(width: 400)
            }
        }
        .padding(theme.tileGap)
        .padding(.bottom, DockView.clearance)
    }

    private func board(_ items: [(id: TileID, surface: SurfaceKind)]) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        // Status lanes are fixed board columns; Apps only appears when occupied.
        let lanes = Lane.allCases.filter { laneCase in
            laneCase != .apps || items.contains { lane(for: $0.surface) == .apps }
        }
        return Group {
            if items.isEmpty {
                SurfaceEmptyState(icon: "rectangle.split.3x1", message: "no sessions yet — ⌘↩ starts one")
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(lanes, id: \.self) { laneCase in
                        column(laneCase, items: items.filter { lane(for: $0.surface) == laneCase })
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(
            store.browseFocused ? theme.accent.opacity(0.85) : theme.border,
            lineWidth: store.browseFocused ? max(theme.borderWidth, 1.5) : theme.borderWidth
        ))
        .clipShape(shape)
    }

    private func column(_ lane: Lane, items: [(id: TileID, surface: SurfaceKind)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: lane.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(laneColor(lane))
                Text(lane.rawValue.uppercased())
                    .font(theme.font(9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Text("\(items.count)")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 4)
            if lane == .new {
                Button {
                    store.newSession(providerID: providers.defaultProviderID)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("New chat")
                            .font(theme.font(10, weight: .medium))
                        Spacer(minLength: 0)
                        Text("⌘↩")
                            .font(theme.font(9, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.border.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Start a new chat (⌘↩)")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items, id: \.id) { item in
                        TrackerCard(
                            surface: item.surface,
                            laneColor: laneColor(lane),
                            isSelected: workspace.focused == item.id
                        ) { workspace.focused = item.id }
                    }
                    if items.isEmpty {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(height: 54)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.textPrimary.opacity(0.03)))
    }

    private func lane(for surface: SurfaceKind) -> Lane {
        switch surface {
        case .app:
            return .apps
        case .session(let id):
            guard let vm = store.runner(for: id)?.viewModel else { return .done }
            switch vm.status {
            case .connecting, .streaming, .runningTool: return .running
            case .failed: return .failed
            case .idle: return vm.hasContent ? .done : .new
            }
        }
    }

    private func laneColor(_ lane: Lane) -> Color {
        switch lane {
        case .running: theme.accent
        case .failed: theme.errorColor
        case .done: theme.successColor.opacity(0.75)
        case .new, .apps: theme.textTertiary
        }
    }
}

private struct TrackerCard: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    let surface: SurfaceKind
    let laneColor: Color
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(laneColor)
                        .frame(width: 6, height: 6)
                    Text(surfaceTitle(surface, store: store, apps: apps))
                        .font(theme.font(11, weight: .medium))
                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(surfacePreview(surface, store: store, apps: apps))
                    .font(theme.font(10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(surfaceBadge(surface, store: store, providers: providers))
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.textPrimary.opacity(0.06)))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                        ? AnyShapeStyle(theme.accent.opacity(0.14))
                        : hovering ? AnyShapeStyle(theme.textPrimary.opacity(0.06)) : AnyShapeStyle(theme.textPrimary.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? theme.accent.opacity(0.5) : theme.border.opacity(0.7), lineWidth: theme.borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

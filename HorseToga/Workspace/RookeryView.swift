//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// The playful projection: every session is a penguin waddling on a snowfield
/// (apps are snowmen). Streaming text shows up as speech bubbles; clicking a
/// penguin opens its chat as a bottom overlay.
struct RookeryView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    var workspace: WorkspaceModel
    @State private var detailShown = false

    var body: some View {
        let items = workspace.surfaceItems
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    snowfield(t: t, size: geo.size)
                    ForEach(items, id: \.id) { item in
                        penguin(item, t: t, size: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea(edges: .top) // the scene owns the title-bar area too
        .overlay {
            if items.isEmpty {
                // Fixed colors: the cartoon scene ignores the theme, so must this.
                VStack(spacing: 8) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 22))
                    Text("no penguins yet — ⌘↩ hatches one")
                        .font(theme.font(11))
                }
                .foregroundStyle(Color(red: 0.16, green: 0.29, blue: 0.42))
            }
        }
        .overlay {
            if detailShown, let selected = selectedSurfaceItem(in: workspace) {
                detailOverlay(selected)
            }
        }
        .animation(.easeOut(duration: 0.15), value: detailShown)
    }

    // MARK: - Scene

    // Opaque cartoon scene (Club Penguin vibes) — deliberately ignores the
    // theme background so the rookery always looks like the island.
    private func snowfield(t: Double, size: CGSize) -> some View {
        let horizon = size.height * 0.42
        return ZStack {
            // Bright cartoon sky.
            LinearGradient(
                colors: [Color(red: 0.29, green: 0.60, blue: 0.87), Color(red: 0.66, green: 0.87, blue: 0.97)],
                startPoint: .top, endPoint: .bottom
            )
            // Puffy clouds.
            cloud(scale: 1.0)
                .position(x: size.width * 0.18, y: size.height * 0.14)
            cloud(scale: 0.7)
                .position(x: size.width * 0.72, y: size.height * 0.09)
            cloud(scale: 0.55)
                .position(x: size.width * 0.48, y: size.height * 0.22)
            // Distant snow banks on the horizon.
            Ellipse()
                .fill(Color(red: 0.85, green: 0.93, blue: 0.98))
                .frame(width: size.width * 1.0, height: 160)
                .position(x: size.width * 0.22, y: horizon + 30)
            Ellipse()
                .fill(Color(red: 0.90, green: 0.96, blue: 1.0))
                .frame(width: size.width * 0.9, height: 180)
                .position(x: size.width * 0.85, y: horizon + 40)
            // Main snowfield.
            Ellipse()
                .fill(Color(red: 0.94, green: 0.98, blue: 1.0))
                .frame(width: size.width * 1.7, height: size.height * 1.2)
                .position(x: size.width * 0.5, y: size.height * 1.05)
            // Igloo on the right bank.
            igloo
                .position(x: size.width * 0.85, y: horizon + 52)
            // Chunky drifting snow.
            Canvas { ctx, canvasSize in
                for i in 0..<40 {
                    let fx = Double((i * 73) % 97) / 97
                    let base = Double((i * 41) % 89) / 89
                    let speed = 0.014 + Double(i % 5) * 0.005
                    let fy = (base + t * speed).truncatingRemainder(dividingBy: 1)
                    let radius = 2.0 + Double(i % 4) * 1.1
                    let drift = sin(t * 0.4 + Double(i)) * 8
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: fx * canvasSize.width + drift, y: fy * canvasSize.height, width: radius, height: radius)),
                        with: .color(.white.opacity(0.85))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func cloud(scale: CGFloat) -> some View {
        ZStack {
            Ellipse().frame(width: 120, height: 44)
            Ellipse().frame(width: 70, height: 52).offset(x: -28, y: -14)
            Ellipse().frame(width: 56, height: 40).offset(x: 30, y: -8)
        }
        .foregroundStyle(.white.opacity(0.92))
        .scaleEffect(scale)
    }

    private var igloo: some View {
        ZStack(alignment: .bottom) {
            // Dome: a circle cropped to its top half.
            Circle()
                .fill(Color(red: 0.97, green: 0.99, blue: 1.0))
                .frame(width: 150, height: 150)
                .frame(height: 76, alignment: .top)
                .clipped()
                .overlay(
                    // Block joints.
                    VStack(spacing: 16) {
                        Rectangle().frame(height: 1.5)
                        Rectangle().frame(height: 1.5)
                        Rectangle().frame(height: 1.5)
                    }
                    .foregroundStyle(Color(red: 0.72, green: 0.85, blue: 0.94).opacity(0.7))
                    .padding(.top, 18)
                )
            // Entrance tunnel.
            Circle()
                .fill(Color(red: 0.88, green: 0.95, blue: 0.99))
                .frame(width: 54, height: 54)
                .frame(height: 30, alignment: .top)
                .clipped()
            Ellipse()
                .fill(Color(red: 0.16, green: 0.29, blue: 0.42))
                .frame(width: 30, height: 22)
                .frame(height: 12, alignment: .top)
                .clipped()
        }
    }

    private func penguin(_ item: (id: TileID, surface: SurfaceKind), t: Double, size: CGSize) -> some View {
        let u = item.id.raw.uuid
        let phase = Double(u.2) / 255 * 2 * .pi
        let speed = 0.15 + Double(u.3) / 255 * 0.2
        let movingRight = cos(t * speed + phase) >= 0
        let isApp = { if case .app = item.surface { true } else { false } }()
        let bubble = bubbleContent(for: item.surface)
        return PenguinView(
            title: surfaceTitle(item.surface, store: store, apps: apps),
            bubble: bubble?.text,
            bubbleIsError: bubble?.isError ?? false,
            emoji: isApp ? "⛄️" : "🐧",
            facingRight: !isApp && movingRight,
            waddleDegrees: isApp ? 0 : sin(t * 5 + phase) * 3.5,
            isSelected: workspace.focused == item.id
        ) {
            workspace.focused = item.id
            detailShown = true
        }
        .position(position(for: item.id, at: t, in: size, stationary: isApp))
    }

    private func position(for id: TileID, at t: Double, in size: CGSize, stationary: Bool) -> CGPoint {
        let u = id.raw.uuid
        let sx = Double(u.0) / 255
        let sy = Double(u.1) / 255
        let phase = Double(u.2) / 255 * 2 * .pi
        let speed = 0.15 + Double(u.3) / 255 * 0.2
        var x = size.width * (0.15 + 0.7 * sx)
        var y = size.height * (0.38 + 0.36 * sy) // keep the colony clear of the dock
        if !stationary {
            x += sin(t * speed + phase) * size.width * 0.08
            y += sin(t * 2.6 + phase) * 2.5 // waddle bob
        }
        return CGPoint(x: x, y: y)
    }

    private func bubbleContent(for surface: SurfaceKind) -> (text: String, isError: Bool)? {
        guard case .session(let id) = surface,
              let vm = store.runner(for: id)?.viewModel else { return nil }
        switch vm.status {
        case .connecting:
            return ("…", false)
        case .streaming:
            let text = vm.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text.isEmpty ? "…" : "…" + String(text.suffix(70)), false)
        case .runningTool(let name):
            return ("⚙ \(name)", false)
        case .failed(let message):
            return ("! " + String(message.prefix(70)), true)
        case .idle:
            return nil
        }
    }

    // MARK: - Detail overlay

    private func detailOverlay(_ item: (id: TileID, surface: SurfaceKind)) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .onTapGesture { detailShown = false }
            TileView(
                tileID: item.id,
                surface: item.surface,
                isFocused: true,
                isZoomed: false,
                onDismiss: { detailShown = false }
            )
            .id(item.id)
            .frame(maxWidth: 760)
            .frame(height: 400)
            .padding(.horizontal, 24)
            .padding(.bottom, DockView.clearance + 10)
        }
        .transition(.opacity)
    }
}

private struct PenguinView: View {
    @Environment(\.theme) private var theme

    let title: String
    let bubble: String?
    let bubbleIsError: Bool
    let emoji: String
    let facingRight: Bool
    let waddleDegrees: Double
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                if let bubble {
                    // Fixed cartoon palette to match the scene, not the theme.
                    Text(bubble)
                        .font(theme.font(9))
                        .foregroundStyle(bubbleIsError ? Color(red: 0.78, green: 0.20, blue: 0.16) : Color(red: 0.13, green: 0.25, blue: 0.38))
                        .lineLimit(2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .frame(maxWidth: 170)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.95)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.72, green: 0.85, blue: 0.94), lineWidth: 1))
                }
                Text(emoji)
                    .font(.system(size: 34))
                    .scaleEffect(x: facingRight ? -1 : 1)
                    .rotationEffect(.degrees(waddleDegrees))
                Text(title)
                    .font(theme.font(9, weight: .medium))
                    .foregroundStyle(isSelected ? Color(red: 0.96, green: 0.49, blue: 0.12) : Color(red: 0.16, green: 0.29, blue: 0.42))
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }
            .frame(width: 180, height: 130, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

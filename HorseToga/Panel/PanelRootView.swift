//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

struct PanelRootView: View {
    @Environment(\.theme) private var theme
    let controller: PanelController
    @Bindable var state: PanelState
    let focus: PanelFocus

    @State private var promptHeight: CGFloat = 30
    @State private var dictation = DictationState.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if let vm = state.session?.viewModel, vm.hasContent {
                Divider().opacity(0.5)
                TranscriptView(viewModel: vm, fontSize: theme.baseSize, maxHeight: 420)
            }
            footer
        }
        .frame(width: PanelController.panelWidth, alignment: .top)
        .background(
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(theme.surface.opacity(0.72))
            }
            .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            controller.setContentHeight(height)
        }
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 12) {
            PromptTextView(
                text: $state.text,
                font: theme.nsFont(20),
                textColor: NSColor(theme.textPrimary),
                focus: focus,
                onSubmit: { controller.onSubmit?(state.text) },
                onCancel: { handleEscape() },
                onExpand: { controller.onExpand?() },
                onHeightChange: { promptHeight = min(max($0, 30), 220) }
            )
            .frame(height: promptHeight)
            keycap("⎋")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .overlay(alignment: .topTrailing) {
            Group {
                if dictation.isRecording { DictationPill() }
                else if let note = dictation.note { DictationNoteView(text: note) }
            }
            .padding(.trailing, 18)
            .padding(.top, 2)
        }
    }

    /// Escape is progressive: cancel a running stream, then clear input, then dismiss.
    private func handleEscape() {
        if let session = state.session, session.viewModel.isRunning {
            session.cancel()
        } else if !state.text.isEmpty {
            state.text = ""
        } else {
            controller.hide()
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("HorseToga")
                .font(theme.font(11, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            if let vm = state.session?.viewModel {
                statusLabel(vm)
            }
            Spacer()
            hint("↩", "send")
            hint("⌘↩", "workspace")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    @ViewBuilder
    private func statusLabel(_ vm: ConversationViewModel) -> some View {
        let text: String? = switch vm.status {
        case .connecting: "connecting…"
        case .streaming: "streaming"
        case .runningTool(let name): "running \(name)"
        case .failed: "failed"
        case .idle: vm.usage.flatMap { usage in
            usage.costUSD.map { String(format: "$%.4f", $0) }
        }
        }
        let isFailed = if case .failed = vm.status { true } else { false }
        if let text {
            Text(text)
                .font(theme.font(11))
                .foregroundStyle(isFailed ? theme.errorColor : theme.textTertiary)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            keycap(key)
            Text(label)
                .font(theme.font(11))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func keycap(_ s: String) -> some View {
        Text(s)
            .font(theme.font(11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.textPrimary.opacity(0.08))
            )
    }
}

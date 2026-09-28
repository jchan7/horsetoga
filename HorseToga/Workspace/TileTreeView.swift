//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Observation
import SwiftUI

/// Renders a workspace's tile tree with absolute frames (computed by the pure
/// layout function) so tiles animate smoothly between arrangements. Omarchy-style
/// gaps; focused tile carries the accent ring.
struct TileTreeView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.theme) private var theme
    var workspace: WorkspaceModel

    private var gap: CGFloat { theme.tileGap }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let frames = workspace.tree.frames(in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(workspace.tree.leafIDs, id: \.self) { tileID in
                    if let frame = effectiveFrame(for: tileID, frames: frames, bounds: bounds),
                       let surface = workspace.tree.surface(of: tileID) {
                        TileView(
                            tileID: tileID,
                            surface: surface,
                            isFocused: workspace.focused == tileID,
                            isZoomed: workspace.zoomed == tileID
                        )
                        .frame(width: max(frame.width - gap, 0), height: max(frame.height - gap, 0))
                        .position(x: frame.midX, y: frame.midY)
                        .animation(.spring(duration: 0.22, bounce: 0.12), value: frame)
                        .opacity(hiddenByZoom(tileID) ? 0 : 1)
                        .allowsHitTesting(!hiddenByZoom(tileID))
                    }
                }
            }
            .onAppear { store.layoutBounds = bounds }
            .onChange(of: geo.size) { _, size in
                store.layoutBounds = CGRect(origin: .zero, size: size)
            }
        }
        .padding(gap)
        .padding(.bottom, DockView.clearance)
    }

    private func effectiveFrame(for id: TileID, frames: [TileID: CGRect], bounds: CGRect) -> CGRect? {
        if let zoomed = workspace.zoomed {
            return id == zoomed ? bounds : frames[id]
        }
        return frames[id]
    }

    private func hiddenByZoom(_ id: TileID) -> Bool {
        if let zoomed = workspace.zoomed { return id != zoomed }
        return false
    }
}

/// Shared chrome for every tile: header bar, focus ring, rounded material body.
struct TileView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(AppRegistry.self) private var apps
    @Environment(\.theme) private var theme

    let tileID: TileID
    let surface: SurfaceKind
    let isFocused: Bool
    let isZoomed: Bool
    /// Set by overlay-style presentations (rookery): shows a collapse control
    /// that hides the detail WITHOUT closing the session.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            header
            content
        }
        .background(
            ZStack {
                if let material = theme.material {
                    shape.fill(material)
                    shape.fill(theme.surface.opacity(0.55))
                } else {
                    // Slightly translucent so the theme wallpaper reads through.
                    shape.fill(theme.surface.opacity(0.85))
                }
            }
        )
        .overlay(
            shape.strokeBorder(
                isFocused ? theme.accent.opacity(0.85) : theme.border,
                lineWidth: isFocused ? max(theme.borderWidth, 1.5) : theme.borderWidth
            )
        )
        .clipShape(shape)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            store.active.focused = tileID
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(title)
                .font(theme.font(11, weight: .semibold))
                .foregroundStyle(isFocused ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
            if isZoomed {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            badgeView
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Collapse")
            }
            Button {
                store.active.focused = tileID
                store.closeFocusedTile()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.textPrimary.opacity(isFocused ? 0.05 : 0.02))
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .session(let conversationID):
            if let runner = store.runner(for: conversationID) {
                SessionTileView(runner: runner, isFocusedTile: isFocused)
            } else {
                Text("session ended")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .app(let appID):
            if let module = apps.module(appID) {
                module.makeView()
            } else {
                AppSurfacePlaceholder(appID: appID)
            }
        }
    }

    private var title: String {
        switch surface {
        case .session(let id): store.runner(for: id)?.viewModel.title ?? "Session"
        case .app(let appID): apps.module(appID)?.name ?? appID.capitalized
        }
    }

    /// Sessions get the provider/model switcher; apps keep a static tag.
    @ViewBuilder
    private var badgeView: some View {
        switch surface {
        case .session(let id):
            if let runner = store.runner(for: id) {
                ProviderMenu(viewModel: runner.viewModel)
            }
        case .app:
            Text("app")
                .font(theme.font(10))
                .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = switch sessionStatus {
        case .some(.connecting): .yellow
        case .some(.streaming), .some(.runningTool): theme.successColor
        case .some(.failed): theme.errorColor
        default: theme.textPrimary.opacity(0.25)
        }
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var sessionStatus: RunStatus? {
        if case .session(let id) = surface {
            return store.runner(for: id)?.viewModel.status
        }
        return nil
    }
}

nonisolated struct ModelPickerChoice: Identifiable, Equatable, Sendable {
    let providerID: ProviderID
    let providerName: String
    let modelLabel: String
    let model: String?

    var id: String { "\(providerID.raw)|\(model ?? "default")" }
}

nonisolated struct RecentModelSelection: Codable, Equatable, Sendable {
    let providerID: ProviderID
    let model: String?

    var id: String { "\(providerID.raw)|\(model ?? "default")" }
}

/// One flat, keyboard-first list shared by new-chat creation and the model chips.
/// Flattening provider submenus makes every choice reachable with the same keys.
@MainActor
@Observable
final class ModelPickerStore {
    /// Two-level selection: pick the agent/provider first (new chat + header),
    /// then the model within that provider (the composer chip next to ↩).
    enum PickerMode: Sendable { case provider, model }

    private(set) var choices: [ModelPickerChoice] = []
    private(set) var recentChoices: [ModelPickerChoice] = []
    private(set) var allChoices: [ModelPickerChoice] = []
    private(set) var showsRecentSection = false
    private(set) var mode: PickerMode = .provider
    var selectionIndex = 0
    var visible = false
    private var viewModel: ConversationViewModel?
    private let defaults: UserDefaults
    private var recentSelections: [RecentModelSelection]
    var onSelection: ((ProviderID) -> Void)?

    private static let recentModelsKey = "model-picker-recent-models-v1"
    private static let maximumRecentModels = 4

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentModelsKey),
           let decoded = try? JSONDecoder().decode([RecentModelSelection].self, from: data) {
            recentSelections = Array(decoded.prefix(Self.maximumRecentModels))
        } else {
            recentSelections = []
        }
    }

    /// Header button / explicit agent switch: one entry per provider.
    func openProviderPicker(for viewModel: ConversationViewModel, providers: ProviderRegistry) {
        beginProviderPicker(for: viewModel, providers: providers, preferredProviderID: viewModel.providerID)
    }

    /// Composer chip next to ↩: the models offered by the current provider.
    func openModelPicker(for viewModel: ConversationViewModel, providers: ProviderRegistry) {
        mode = .model
        allChoices = modelChoices(for: viewModel.providerID, from: providers)
        recentChoices = []
        showsRecentSection = false
        choices = allChoices
        self.viewModel = viewModel
        selectionIndex = choices.firstIndex { $0.model == viewModel.model } ?? 0
        visible = !choices.isEmpty
    }

    private func beginProviderPicker(
        for viewModel: ConversationViewModel,
        providers: ProviderRegistry,
        preferredProviderID: ProviderID
    ) {
        mode = .provider
        allChoices = providerChoices(from: providers)
        recentChoices = []
        showsRecentSection = false
        choices = allChoices
        self.viewModel = viewModel
        selectionIndex = choices.firstIndex { $0.providerID == preferredProviderID } ?? 0
        visible = !choices.isEmpty
    }

    func openForNewChat(
        for viewModel: ConversationViewModel,
        providers: ProviderRegistry,
        archiveSelections: [RecentModelSelection]
    ) {
        // A new chat picks the provider, pre-selected on the one used most
        // recently (falling back to the archive, then the app default). The
        // model within it is chosen later from the composer chip.
        let preferred = (recentSelections + archiveSelections).first?.providerID ?? viewModel.providerID
        beginProviderPicker(for: viewModel, providers: providers, preferredProviderID: preferred)
    }

    /// One choice per provider; the model is left at the provider default.
    private func providerChoices(from providers: ProviderRegistry) -> [ModelPickerChoice] {
        providers.providers.map { provider in
            ModelPickerChoice(
                providerID: provider.id,
                providerName: provider.displayName,
                modelLabel: "Default",
                model: nil
            )
        }
    }

    /// One choice per model offered by a single provider.
    private func modelChoices(for providerID: ProviderID, from providers: ProviderRegistry) -> [ModelPickerChoice] {
        guard let provider = providers.provider(providerID) else { return [] }
        let models = provider.models.isEmpty ? [ModelOption("Default")] : provider.models
        return models.map { option in
            ModelPickerChoice(
                providerID: provider.id,
                providerName: provider.displayName,
                modelLabel: option.label,
                model: option.value
            )
        }
    }

    func moveSelection(_ delta: Int) {
        guard !choices.isEmpty else { return }
        selectionIndex = (selectionIndex + delta + choices.count) % choices.count
    }

    /// The "r" shortcut: jump straight to a random option you're actually
    /// connected to (setup complete), so it never lands on an agent that would
    /// still need sign-in. A no-op when nothing is connected yet.
    func selectRandomReady(isReady: (ProviderID) -> Bool) {
        let ready = choices.indices.filter { isReady(choices[$0].providerID) }
        guard let index = ready.randomElement() else { return }
        select(at: index)
    }

    func select(at index: Int? = nil) {
        let index = index ?? selectionIndex
        guard let viewModel, choices.indices.contains(index) else {
            close()
            return
        }
        let choice = choices[index]
        let hadContent = viewModel.hasContent

        switch mode {
        case .provider:
            // Re-picking the same provider keeps its model; a new provider falls
            // back to that provider's default and drops the old CLI session handle.
            if viewModel.providerID != choice.providerID {
                viewModel.providerID = choice.providerID
                viewModel.model = nil
                viewModel.handle = nil
                if hadContent {
                    viewModel.entries.append(
                        TranscriptEntry(kind: .notice("agent switched to \(choice.providerName)"))
                    )
                }
            }
        case .model:
            if viewModel.model != choice.model {
                viewModel.model = choice.model
                if hadContent {
                    let label = choice.modelLabel == "Default" ? "default model" : choice.modelLabel
                    viewModel.entries.append(
                        TranscriptEntry(kind: .notice("model switched to \(label)"))
                    )
                }
            }
        }
        remember(choice)
        close()
        onSelection?(choice.providerID)
    }

    private func remember(_ choice: ModelPickerChoice) {
        let selection = RecentModelSelection(providerID: choice.providerID, model: choice.model)
        recentSelections.removeAll { $0.id == selection.id }
        recentSelections.insert(selection, at: 0)
        recentSelections = Array(recentSelections.prefix(Self.maximumRecentModels))
        persistRecentSelections()
    }

    private func persistRecentSelections() {
        guard let data = try? JSONEncoder().encode(recentSelections) else { return }
        defaults.set(data, forKey: Self.recentModelsKey)
    }

    func close() {
        visible = false
        viewModel = nil
    }
}

/// Header badge: shows and switches the tile's agent/provider. The model within
/// that provider is chosen separately from the composer's `ModelMenu`.
struct ProviderMenu: View {
    @Environment(ProviderRegistry.self) private var providers
    @Environment(ModelPickerStore.self) private var modelPicker
    @Environment(\.theme) private var theme
    let viewModel: ConversationViewModel

    var body: some View {
        Button {
            modelPicker.openProviderPicker(for: viewModel, providers: providers)
        } label: {
            HStack(spacing: 4) {
                ProviderLogo(id: viewModel.providerID, size: 11)
                Text(providerName)
                    .font(theme.font(10))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch agent — ↑↓ then ↩")
    }

    private var providerName: String {
        providers.provider(viewModel.providerID)?.displayName ?? String(describing: viewModel.providerID)
    }
}

/// Composer chip (next to ↩): shows and switches the model within the tile's
/// current provider — e.g. Opus / Sonnet / Haiku when the agent is Claude Code.
struct ModelMenu: View {
    @Environment(ProviderRegistry.self) private var providers
    @Environment(ModelPickerStore.self) private var modelPicker
    @Environment(\.theme) private var theme
    let viewModel: ConversationViewModel

    var body: some View {
        Button {
            modelPicker.openModelPicker(for: viewModel, providers: providers)
        } label: {
            HStack(spacing: 4) {
                Text(modelLabel)
                    .font(theme.font(10))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose model — ↑↓ then ↩")
    }

    private var modelLabel: String {
        guard let provider = providers.provider(viewModel.providerID) else { return "Default" }
        if let option = provider.models.first(where: { $0.value == viewModel.model }) {
            return option.label
        }
        if let model = viewModel.model, !model.isEmpty {
            return model.capitalized
        }
        return "Default"
    }
}

struct ModelPickerOverlay: View {
    @Environment(ModelPickerStore.self) private var modelPicker
    @Environment(ProviderRegistry.self) private var providers
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(modelPicker.mode == .provider ? "AGENT" : "MODEL")
                    .font(theme.font(10, weight: .semibold))
                    .kerning(1.3)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Text("↑↓ or tab · ↩ select · r random · esc cancel")
                    .font(theme.font(9.5))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if modelPicker.showsRecentSection {
                            sectionLabel("RECENT MODELS")
                            ForEach(Array(modelPicker.recentChoices.enumerated()), id: \.offset) { index, choice in
                                choiceRow(choice, index: index)
                                    .id(scrollID(for: index))
                            }

                            sectionLabel("ALL MODELS")
                                .padding(.top, 7)
                            ForEach(Array(modelPicker.allChoices.enumerated()), id: \.offset) { offset, choice in
                                let index = modelPicker.recentChoices.count + offset
                                choiceRow(choice, index: index)
                                    .id(scrollID(for: index))
                            }
                        } else {
                            ForEach(Array(modelPicker.choices.enumerated()), id: \.offset) { index, choice in
                                choiceRow(choice, index: index)
                                    .id(scrollID(for: index))
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 410)
                .onChange(of: modelPicker.selectionIndex) { _, index in
                    guard modelPicker.choices.indices.contains(index) else { return }
                    proxy.scrollTo(scrollID(for: index), anchor: .center)
                }
            }

            Divider().opacity(0.4)
            Text("Press 1–9 to choose the first nine options instantly")
                .font(theme.font(9.5))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 440)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(theme.font(9, weight: .semibold))
            .kerning(1.1)
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
    }

    private func scrollID(for index: Int) -> String {
        "model-picker-choice-\(index)"
    }

    private func choiceRow(_ choice: ModelPickerChoice, index: Int) -> some View {
        let isSelected = index == modelPicker.selectionIndex
        let needsSetup = providers.setupRequirement(for: choice.providerID, probing: false) != nil
        return Button {
            modelPicker.selectionIndex = index
            modelPicker.select()
        } label: {
            HStack(spacing: 10) {
                Text(index < 9 ? "\(index + 1)" : "")
                    .font(theme.font(9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.textPrimary.opacity(index < 9 ? 0.07 : 0))
                    )
                ProviderLogo(id: choice.providerID, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(modelPicker.mode == .provider ? choice.providerName : choice.modelLabel)
                            .font(theme.font(11.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        // Distinguish a local coding agent (a CLI) from a direct
                        // key-billed API to the same vendor's models.
                        if modelPicker.mode == .provider, let tag = providerKindTag(choice.providerID) {
                            Text(tag)
                                .font(theme.font(8, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.textPrimary.opacity(0.08)))
                        }
                    }
                    Text(choiceSubtitle(choice, needsSetup: needsSetup))
                        .font(theme.font(9.5))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? AnyShapeStyle(theme.accent.opacity(0.14)) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.providerName), \(choice.modelLabel)")
    }

    /// "agent" for a local CLI (SubprocessProvider), "API" for a key-billed HTTP
    /// adapter — the two ways a vendor like Anthropic appears in the list.
    private func providerKindTag(_ id: ProviderID) -> String? {
        guard let provider = providers.provider(id) else { return nil }
        if provider is SubprocessProvider { return "agent" }
        if provider is any KeyBackedProvider { return "API" }
        return nil
    }

    private func choiceSubtitle(_ choice: ModelPickerChoice, needsSetup: Bool) -> String {
        let base: String
        if modelPicker.mode == .provider {
            // Under each agent, list the models it offers so the two-step choice reads ahead.
            let models = (providers.provider(choice.providerID)?.models ?? [])
                .map(\.label)
                .filter { $0 != "Default" }
            base = models.isEmpty ? "default model only" : models.joined(separator: " · ")
        } else {
            base = choice.modelLabel == "Default" ? "Default model" : choice.providerName
        }
        return needsSetup ? "\(base) · sign-in opens on select" : base
    }
}

/// A session rendered inside a tile: full transcript + its own prompt field.
struct SessionTileView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ProviderRegistry.self) private var providers
    @Environment(ModelPickerStore.self) private var modelPicker
    @Environment(CommandPaletteStore.self) private var palette
    @Environment(\.theme) private var theme

    let runner: ConversationRunner
    let isFocusedTile: Bool

    @State private var input = ""
    @State private var focus = PanelFocus()
    @State private var promptHeight: CGFloat = 22
    @State private var dictation = DictationState.shared

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(viewModel: runner.viewModel, fontSize: theme.baseSize - 0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            composer
        }
        .onChange(of: isFocusedTile) { _, _ in
            if shouldHoldKeyboard { grabKeyboard() }
        }
        .onChange(of: modelPicker.visible) { _, _ in
            if shouldHoldKeyboard { DispatchQueue.main.async { grabKeyboard() } }
        }
        // Closing the ⌘K palette (e.g. after renaming) returns you to the chat.
        .onChange(of: palette.visible) { _, _ in
            if shouldHoldKeyboard { DispatchQueue.main.async { grabKeyboard() } }
        }
        // Inbox/tracker ⇧⇥ moves the keyboard to the list/board; ⇥ / ↩ hands it
        // back. (The detail is isFocused:false while browsing, so this can't gate
        // on isFocusedTile — in these views the detail is the only composer.)
        .onChange(of: store.browseFocused) { _, browsing in
            guard isBrowseMode else { return }
            if browsing {
                blurComposer()
            } else {
                DispatchQueue.main.async { grabKeyboard() }
            }
        }
        // A freshly created tile is already the focused one — onChange never
        // fires, so claim the keyboard on appear too: ⌘↩ lands you typing.
        .onAppear {
            if shouldHoldKeyboard { DispatchQueue.main.async { grabKeyboard() } }
        }
    }

    private var isBrowseMode: Bool {
        store.active.viewMode == .inbox || store.active.viewMode == .tracker
    }

    /// The composer owns the keyboard unless a modal is up or the inbox/tracker
    /// list/board zone has claimed it (⇧⇥).
    private var shouldHoldKeyboard: Bool {
        isFocusedTile && !modelPicker.visible && !palette.visible
            && !(isBrowseMode && store.browseFocused)
    }

    private func grabKeyboard() {
        focus.textView?.window?.makeFirstResponder(focus.textView)
    }

    private func blurComposer() {
        if focus.textView?.window?.firstResponder === focus.textView {
            focus.textView?.window?.makeFirstResponder(nil)
        }
    }

    /// Claude Code-style composer: a rounded card with the prompt on top and a
    /// control row underneath (agent picker on the right, like the model chip).
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            PromptTextView(
                text: $input,
                font: theme.nsFont(theme.baseSize - 0.5),
                textColor: NSColor(theme.textPrimary),
                focus: focus,
                onSubmit: submit,
                onCancel: { if runner.viewModel.isRunning { runner.cancel() } },
                onHeightChange: { promptHeight = min(max($0, 22), 140) }
            )
            .frame(height: promptHeight)
            HStack(spacing: 8) {
                Text("⇧↩ newline")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                ModelMenu(viewModel: runner.viewModel)
                if runner.viewModel.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.textPrimary.opacity(0.07)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.textPrimary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocusedTile ? theme.accent.opacity(0.35) : theme.border, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isFocusedTile {
                Group {
                    if dictation.isRecording { DictationPill() }
                    else if let note = dictation.note { DictationNoteView(text: note) }
                }
                .padding(8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 6)
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let provider = providers.provider(runner.viewModel.providerID)
            ?? providers.defaultProvider else { return }
        runner.send(text, via: provider)
        input = ""
    }
}

/// Stand-in until AppModules land (usage dashboard, browser, notes, ...).
struct AppSurfacePlaceholder: View {
    let appID: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(appID)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("app module coming soon")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

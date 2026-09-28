//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Presentation app: a minimal working deck editor — slide list on the left,
/// 16:9 editable slide canvas in the middle. In-memory for now.
@MainActor
@Observable
final class SlidesState {
    struct DeckSlide: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    var slides = [DeckSlide(title: "Untitled deck", body: "Click to edit")]
    var selectedIndex = 0

    var selected: DeckSlide? {
        slides.indices.contains(selectedIndex) ? slides[selectedIndex] : nil
    }

    func addSlide() {
        slides.insert(DeckSlide(title: "New slide", body: ""), at: min(selectedIndex + 1, slides.count))
        selectedIndex = min(selectedIndex + 1, slides.count - 1)
    }

    func deleteSelected() {
        guard slides.count > 1, slides.indices.contains(selectedIndex) else { return }
        slides.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, slides.count - 1)
    }
}

struct SlidesAppView: View {
    @Environment(\.theme) private var theme
    @Bindable var state: SlidesState

    var body: some View {
        HStack(spacing: 0) {
            slideList
            Divider().opacity(0.4)
            canvas
        }
    }

    private var slideList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { state.addSlide() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Add slide")
                Button { state.deleteSelected() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete slide")
                Spacer()
                Text("\(state.slides.count)")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().opacity(0.4)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(state.slides.enumerated()), id: \.element.id) { index, slide in
                        thumbnail(slide, number: index + 1, isSelected: index == state.selectedIndex)
                            .onTapGesture { state.selectedIndex = index }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 168)
    }

    private func thumbnail(_ slide: SlidesState.DeckSlide, number: Int, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number)")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 12, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(slide.title.isEmpty ? "—" : slide.title)
                    .font(theme.font(9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.textPrimary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? theme.accent.opacity(0.8) : theme.border, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .contentShape(Rectangle())
    }

    private var canvas: some View {
        VStack {
            if state.slides.indices.contains(state.selectedIndex) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Slide title", text: $state.slides[state.selectedIndex].title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(theme.font(26, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    TextEditor(text: $state.slides[state.selectedIndex].body)
                        .font(.system(size: theme.baseSize + 2, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .scrollContentBackground(.hidden)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.textPrimary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border))
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class SlidesAppModule: AppModule {
    let id = "slides"
    let name = "Slides"
    let icon = "rectangle.on.rectangle"
    private let state = SlidesState()

    func makeView() -> AnyView {
        AnyView(SlidesAppView(state: state))
    }

    func snapshot() async -> AppSnapshot {
        let outline = state.slides.enumerated()
            .map { "\($0.offset + 1). \($0.element.title): \($0.element.body.prefix(120))" }
            .joined(separator: "\n")
        return AppSnapshot(summary: "Slides deck (\(state.slides.count) slides):\n\(outline)")
    }
}

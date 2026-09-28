//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Email app shell: the layout is real (mailboxes + list + reading pane) but no
/// account backend is wired yet, and it says so honestly.
struct MailAppView: View {
    @Environment(\.theme) private var theme
    @State private var selectedBox = "Inbox"

    private let boxes: [(String, String)] = [
        ("Inbox", "tray"),
        ("Sent", "paperplane"),
        ("Drafts", "doc"),
        ("Archive", "archivebox"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            SurfaceEmptyState(icon: "envelope", message: "no account connected — IMAP/Gmail coming soon")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MAILBOXES")
                .font(theme.font(9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(boxes, id: \.0) { box in
                let isSelected = selectedBox == box.0
                Button {
                    selectedBox = box.0
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: box.1)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 14)
                        Text(box.0)
                            .font(theme.font(11))
                            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        Spacer()
                        Text("0")
                            .font(theme.font(9))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? AnyShapeStyle(theme.accent.opacity(0.14)) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(width: 170)
    }
}

@MainActor
final class MailAppModule: AppModule {
    let id = "mail"
    let name = "Mail"
    let icon = "envelope"

    func makeView() -> AnyView {
        AnyView(MailAppView())
    }

    func snapshot() async -> AppSnapshot {
        AppSnapshot(summary: "Mail: no account connected yet")
    }
}

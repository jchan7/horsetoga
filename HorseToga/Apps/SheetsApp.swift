//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import SwiftUI

/// Spreadsheet app: a working editable grid (26 rows × 8 columns), in-memory.
/// No formula engine yet — the footer says so.
@MainActor
@Observable
final class SheetsState {
    static let rows = 26
    static let columns = 8

    var cells: [[String]] = Array(
        repeating: Array(repeating: "", count: SheetsState.columns),
        count: SheetsState.rows
    )

    static func columnName(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index)))
    }

    var filledCount: Int {
        cells.reduce(0) { $0 + $1.count { !$0.isEmpty } }
    }
}

struct SheetsAppView: View {
    @Environment(\.theme) private var theme
    @Bindable var state: SheetsState

    private let columnWidth: CGFloat = 104
    private let rowHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                grid.padding(10)
            }
            Divider().opacity(0.4)
            footer
        }
    }

    private var grid: some View {
        VStack(spacing: 1) {
            // Header row: A–H
            HStack(spacing: 1) {
                headerCell("", width: 34)
                ForEach(0..<SheetsState.columns, id: \.self) { column in
                    headerCell(SheetsState.columnName(column), width: columnWidth)
                }
            }
            ForEach(0..<SheetsState.rows, id: \.self) { row in
                HStack(spacing: 1) {
                    headerCell("\(row + 1)", width: 34)
                    ForEach(0..<SheetsState.columns, id: \.self) { column in
                        TextField("", text: $state.cells[row][column])
                            .textFieldStyle(.plain)
                            .font(.system(size: theme.baseSize - 1, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 6)
                            .frame(width: columnWidth, height: rowHeight)
                            .background(theme.textPrimary.opacity(0.03))
                            .overlay(Rectangle().strokeBorder(theme.border.opacity(0.5), lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func headerCell(_ label: String, width: CGFloat) -> some View {
        Text(label)
            .font(theme.font(9, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .frame(width: width, height: rowHeight)
            .background(theme.textPrimary.opacity(0.06))
    }

    private var footer: some View {
        HStack {
            Text("\(state.filledCount) cells filled")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Text("formulas coming soon")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

@MainActor
final class SheetsAppModule: AppModule {
    let id = "sheets"
    let name = "Sheets"
    let icon = "tablecells"
    private let state = SheetsState()

    func makeView() -> AnyView {
        AnyView(SheetsAppView(state: state))
    }

    func snapshot() async -> AppSnapshot {
        var filled: [String] = []
        for (rowIndex, row) in state.cells.enumerated() {
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                filled.append("\(SheetsState.columnName(columnIndex))\(rowIndex + 1)=\(value)")
            }
        }
        return AppSnapshot(summary: filled.isEmpty ? "Sheets: empty grid" : "Sheets cells: " + filled.joined(separator: ", "))
    }
}

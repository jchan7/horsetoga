//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

/// Transcript renderer shared by the panel (capped height) and session tiles
/// (fills the tile). Same component so the two surfaces can never diverge.
struct TranscriptView: View {
    @Environment(\.theme) private var theme
    let viewModel: ConversationViewModel
    var fontSize: CGFloat = 13
    var maxHeight: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.entries) { entry in
                        row(for: entry)
                    }
                    if !viewModel.liveReasoning.isEmpty {
                        Text(viewModel.liveReasoning)
                            .font(.system(size: fontSize - 1, design: .monospaced))
                            .italic()
                            .foregroundStyle(theme.textTertiary)
                            .textSelection(.enabled)
                    }
                    if !viewModel.liveText.isEmpty {
                        MarkdownMessageView(text: viewModel.liveText, fontSize: fontSize)
                    }
                    if viewModel.status == .connecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("connecting")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: maxHeight ?? .infinity)
            .onChange(of: viewModel.liveText) { proxy.scrollTo("bottom") }
            .onChange(of: viewModel.entries.count) { proxy.scrollTo("bottom") }
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .user(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("›")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Text(text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            assistantBody(text)
        case .reasoning(let text):
            Text(text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .italic()
                .foregroundStyle(theme.textTertiary)
                .lineLimit(4)
        case .tool(let name, let detail, let result, let isError):
            HStack(spacing: 6) {
                Image(systemName: result == nil ? "gearshape.arrow.trianglehead.2.clockwise.rotate.90" : (isError ? "xmark.circle" : "checkmark.circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(isError ? theme.errorColor : theme.textSecondary)
                Text(name + (detail.isEmpty ? "" : " \(detail)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(0.06)))
        case .notice(let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
        case .error(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(theme.errorColor)
                    .textSelection(.enabled)
                if ConversationErrorRecovery.suggested(for: text) == .providerSignIn {
                    Button(action: openProviderSignIn) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text(signInLabel)
                                .font(theme.font(10, weight: .semibold))
                        }
                        .foregroundStyle(theme.backgroundColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Open Providers to sign in or add an API key")
                }
            }
        }
    }

    /// Assistant text with any markdown image references (or links to image
    /// files) pulled out and rendered inline as actual images.
    @ViewBuilder
    private func assistantBody(_ text: String) -> some View {
        let segments = MessageParser.segments(from: text)
        if segments.count == 1, case .text(let only) = segments[0] {
            MarkdownMessageView(text: only, fontSize: fontSize)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let value):
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownMessageView(text: value, fontSize: fontSize)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .image(let reference):
                        InlineImage(reference: reference, base: viewModel.workingDirectory)
                    }
                }
            }
        }
    }

    private var signInLabel: String {
        switch viewModel.providerID {
        case .claudeCLI:
            "Sign in with Anthropic"
        case .codexCLI:
            "Sign in to ChatGPT"
        default:
            "Fix sign-in"
        }
    }

    private func openProviderSignIn() {
        let services = AppServices.shared
        services.workspaceWindow.show()
        services.providerSetup.request(viewModel.providerID, force: true)
        services.panel.hide()
    }
}

// MARK: - Inline images

private enum MessageSegment {
    case text(String)
    case image(String) // path or URL reference
}

/// Splits assistant text into text runs and image references. An image is any
/// `![alt](url)` — or a plain `[text](url)` whose target is an image file.
private enum MessageParser {
    private static let regex = try! NSRegularExpression(pattern: #"(!?)\[[^\]]*\]\(([^)\s]+)\)"#)
    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg"]

    static func segments(from text: String) -> [MessageSegment] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var segments: [MessageSegment] = []
        var cursor = 0
        for match in matches {
            let bang = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            let ext = (url as NSString).pathExtension.lowercased()
            guard bang == "!" || imageExtensions.contains(ext) else { continue }
            if match.range.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            segments.append(.image(url))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }
        return segments.isEmpty ? [.text(text)] : segments
    }
}

/// Renders a referenced image inline — local (relative to the chat's working
/// directory, absolute, ~, or file://) or remote (http). Falls back to a small
/// chip showing the path when the file can't be loaded.
private struct InlineImage: View {
    @Environment(\.theme) private var theme
    let reference: String
    let base: URL?
    @State private var image: NSImage?
    @State private var triedLoad = false

    var body: some View {
        Group {
            if let image {
                imageView(Image(nsImage: image))
            } else if let remote {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let img): imageView(img)
                    case .failure: placeholder
                    default: ProgressView().controlSize(.small)
                    }
                }
            } else {
                placeholder
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func imageView(_ img: Image) -> some View {
        img.resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 380, maxHeight: 380, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 10))
            Text(reference)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(0.06)))
        .help("Couldn't load image: \(reference)")
    }

    private var remote: URL? {
        (reference.hasPrefix("http://") || reference.hasPrefix("https://")) ? URL(string: reference) : nil
    }

    private func loadIfNeeded() {
        guard image == nil, !triedLoad, remote == nil, let url = localURL else { return }
        triedLoad = true
        image = NSImage(contentsOf: url)
    }

    private var localURL: URL? {
        var ref = reference
        if ref.hasPrefix("file://") { return URL(string: ref) }
        if ref.hasPrefix("~") { ref = NSString(string: ref).expandingTildeInPath }
        if ref.hasPrefix("/") { return URL(filePath: ref) }
        return (base ?? URL(filePath: NSHomeDirectory())).appending(path: ref)
    }
}

// MARK: - Markdown rendering (folded in here so the generated .xcodeproj picks it
// up without an xcodegen run; safe to split back into its own file after regen).

/// Renders an assistant message as formatted Markdown — headings, bold/italic,
/// inline code, fenced code blocks, bullet/numbered lists, block quotes, GFM
/// tables, links, and rules — instead of showing the raw source with visible
/// `**`, `#`, and `|`. Block structure is parsed here; inline spans are handled
/// by AttributedString's inline Markdown. Prose is proportional (like the Claude
/// and ChatGPT apps); code stays monospaced. Colors come from the active theme.
struct MarkdownMessageView: View {
    @Environment(\.theme) private var theme
    let text: String
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let source):
            inlineText(source, size: headingSize(level), bold: true)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 3 : 0)

        case .paragraph(let source):
            inlineText(source)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.ordered ? "\(item.number)." : "•")
                            .font(.system(size: fontSize).monospacedDigit())
                            .foregroundStyle(theme.textSecondary)
                        inlineText(item.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .codeBlock(let language, let code):
            codeBlock(language: language, code: code)

        case .quote(let inner):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accent.opacity(0.6))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, b in
                        AnyView(blockView(b))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .table(let header, let aligns, let rows):
            tableView(header: header, aligns: aligns, rows: rows)

        case .rule:
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: max(fontSize - 3, 9), design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textPrimary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }

    private func tableView(header: [String], aligns: [HorizontalAlignment], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        return VStack(spacing: 0) {
            tableRow(header, aligns: aligns, cols: cols, bold: true)
            Rectangle().fill(theme.border).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                tableRow(row, aligns: aligns, cols: cols, bold: false)
                if index < rows.count - 1 {
                    Rectangle().fill(theme.border.opacity(0.5)).frame(height: 1)
                }
            }
        }
        .background(theme.textPrimary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(_ cells: [String], aligns: [HorizontalAlignment], cols: Int, bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { column in
                let value = column < cells.count ? cells[column] : ""
                let align = column < aligns.count ? aligns[column] : .leading
                inlineText(value, size: fontSize - 0.5, bold: bold)
                    .multilineTextAlignment(textAlignment(align))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment(align))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                if column < cols - 1 {
                    Rectangle().fill(theme.border.opacity(0.5)).frame(width: 1)
                }
            }
        }
    }

    // MARK: - Inline

    private func inlineText(_ source: String, size: CGFloat? = nil, bold: Bool = false) -> Text {
        Text(MarkdownInline.attributed(
            source,
            size: size ?? fontSize,
            bold: bold,
            textColor: theme.textPrimary,
            codeColor: theme.textPrimary,
            codeBackground: theme.textPrimary.opacity(0.09),
            linkColor: theme.accent
        ))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: fontSize + 7
        case 2: fontSize + 4
        case 3: fontSize + 2
        case 4: fontSize + 1
        default: fontSize
        }
    }

    private func frameAlignment(_ h: HorizontalAlignment) -> Alignment {
        if h == .center { return .center }
        if h == .trailing { return .trailing }
        return .leading
    }

    private func textAlignment(_ h: HorizontalAlignment) -> TextAlignment {
        if h == .center { return .center }
        if h == .trailing { return .trailing }
        return .leading
    }
}

// MARK: - Inline Markdown → styled AttributedString

private enum MarkdownInline {
    static func attributed(
        _ source: String,
        size: CGFloat,
        bold: Bool,
        textColor: Color,
        codeColor: Color,
        codeBackground: Color,
        linkColor: Color
    ) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        var attributed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)

        attributed.font = .system(size: size).weight(bold ? .semibold : .regular)
        attributed.foregroundColor = textColor

        // Collect per-run styling first; applying attributes doesn't change the
        // string, so ranges captured here stay valid through the second pass.
        var edits: [(range: Range<AttributedString.Index>, font: Font, fg: Color?, bg: Color?)] = []
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent
            let isCode = intent?.contains(.code) ?? false
            let isBold = bold || (intent?.contains(.stronglyEmphasized) ?? false)
            let isItalic = intent?.contains(.emphasized) ?? false

            var font: Font = isCode ? .system(size: size, design: .monospaced) : .system(size: size)
            font = font.weight(isBold ? .semibold : .regular)
            if isItalic { font = font.italic() }

            var fg: Color? = nil
            var bg: Color? = nil
            if isCode { fg = codeColor; bg = codeBackground }
            if run.link != nil { fg = linkColor }

            edits.append((run.range, font, fg, bg))
        }
        for edit in edits {
            attributed[edit.range].font = edit.font
            if let fg = edit.fg { attributed[edit.range].foregroundColor = fg }
            if let bg = edit.bg { attributed[edit.range].backgroundColor = bg }
        }
        return attributed
    }
}

// MARK: - Block parser

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(items: [MarkdownListItem])
    case codeBlock(language: String?, code: String)
    case quote(blocks: [MarkdownBlock])
    case table(header: [String], alignments: [HorizontalAlignment], rows: [[String]])
    case rule
}

struct MarkdownListItem {
    var indent: Int
    var ordered: Bool
    var number: Int
    var text: String
}

/// A deliberately small, line-based CommonMark/GFM subset covering what chat
/// agents actually emit. Full inline parsing is left to AttributedString.
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block (``` or ~~~), auto-closed at end of input.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // consume closing fence
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language,
                                         code: code.joined(separator: "\n")))
                continue
            }

            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1; continue
            }

            if isRule(trimmed) {
                blocks.append(.rule); i += 1; continue
            }

            // Table: a row containing "|" immediately followed by a delimiter row.
            if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                let header = splitRow(line)
                let aligns = alignments(lines[i + 1])
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                    rows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(header: header, alignments: aligns, rows: rows))
                continue
            }

            // Block quote (lazy continuation until a blank line).
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix(">") {
                        var inner = String(ql.dropFirst())
                        if inner.hasPrefix(" ") { inner.removeFirst() }
                        quoted.append(inner)
                        i += 1
                    } else if ql.isEmpty {
                        break
                    } else {
                        quoted.append(ql); i += 1
                    }
                }
                blocks.append(.quote(blocks: parse(quoted.joined(separator: "\n"))))
                continue
            }

            // List (bullet or ordered), with simple indent-based nesting.
            if listMatch(line) != nil {
                var items: [MarkdownListItem] = []
                while i < lines.count {
                    let raw = lines[i]
                    if raw.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if let item = listMatch(raw) {
                        items.append(item); i += 1
                    } else if raw.first == " " || raw.first == "\t", !items.isEmpty {
                        items[items.count - 1].text += "\n" + raw.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items))
                continue
            }

            // Paragraph: gather until a blank line or the start of another block.
            var paragraph: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("~~~") { break }
                if headingMatch(nextTrimmed) != nil { break }
                if isRule(nextTrimmed) { break }
                if nextTrimmed.hasPrefix(">") { break }
                if listMatch(next) != nil { break }
                if next.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) { break }
                paragraph.append(next); i += 1
            }
            blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: helpers

    private static func headingMatch(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.filter { $0 != " " }
        guard stripped.count >= 3 else { return false }
        for marker in ["-", "*", "_"] where stripped.allSatisfy({ String($0) == marker }) {
            return true
        }
        return false
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let allowed = Set("-:| ")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return false }
        return splitRow(line).allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            let core = c.replacingOccurrences(of: ":", with: "")
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignments(_ delimiterLine: String) -> [HorizontalAlignment] {
        splitRow(delimiterLine).map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            return .leading
        }
    }

    private static func listMatch(_ raw: String) -> MarkdownListItem? {
        var index = raw.startIndex
        var spaces = 0
        while index < raw.endIndex, raw[index] == " " { spaces += 1; index = raw.index(after: index) }
        while index < raw.endIndex, raw[index] == "\t" { spaces += 4; index = raw.index(after: index) }
        let rest = raw[index...]
        guard let first = rest.first else { return nil }
        let indent = spaces / 2

        // Unordered: "- ", "* ", "+ "
        if first == "-" || first == "*" || first == "+" {
            let afterMarker = rest.dropFirst()
            guard afterMarker.hasPrefix(" ") else { return nil }
            return MarkdownListItem(indent: indent, ordered: false, number: 0,
                                    text: String(afterMarker.dropFirst()))
        }

        // Ordered: "1. " or "1) "
        var digits = ""
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor].isNumber {
            digits.append(rest[cursor]); cursor = rest.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < rest.endIndex, rest[cursor] == "." || rest[cursor] == ")" else {
            return nil
        }
        let afterPunct = rest.index(after: cursor)
        guard afterPunct < rest.endIndex, rest[afterPunct] == " " else { return nil }
        return MarkdownListItem(indent: indent, ordered: true, number: Int(digits) ?? 1,
                                text: String(rest[rest.index(after: afterPunct)...]))
    }
}

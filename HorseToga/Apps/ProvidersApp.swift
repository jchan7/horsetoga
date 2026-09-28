//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import SwiftUI

nonisolated private struct ProviderAPIKeyOption: Identifiable, Sendable {
    let providerID: ProviderID
    let displayName: String
    let models: [ModelOption]
    let keychainAccount: String
    let keyHint: String
    let keyConsoleURL: String

    var id: String { keychainAccount }
}

/// The login center. Account sign-in and API keys are parallel credential
/// routes: browser OAuth uses the vendor subscription, while a platform key
/// enables direct HTTP and any compatible vendor CLI. Keys live in Keychain,
/// never UserDefaults or provider configuration files.
struct ProvidersAppView: View {
    @Environment(ProviderRegistry.self) private var registry
    @Environment(\.theme) private var theme
    @State private var drafts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Accounts", note: "your existing subscriptions, via each vendor's own sign-in")
                ForEach(accountIDs, id: \.self) { id in
                    if let provider = registry.provider(id) as? SubprocessProvider {
                        AccountCard(provider: provider)
                    }
                }
                sectionHeader("API keys", note: "stored in Keychain and shared only with that provider")
                    .padding(.top, 8)
                ForEach(apiKeyOptions) { option in
                    APIKeyCard(
                        option: option,
                        draft: draftBinding(option.keychainAccount)
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await registry.refreshHealth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await registry.refreshHealth() }
        }
    }

    private var accountIDs: [ProviderID] {
        registry.providers.compactMap { ($0 as? SubprocessProvider)?.id }
    }

    private var apiKeyOptions: [ProviderAPIKeyOption] {
        var seen: Set<String> = []
        var options: [ProviderAPIKeyOption] = []

        // Direct API adapters first. CLI entries sharing the same key (Grok/xAI)
        // reuse this card instead of asking the user to save the key twice.
        for provider in registry.providers {
            guard let keyed = provider as? any KeyBackedProvider, keyed.requiresKey,
                  seen.insert(keyed.keychainAccount).inserted
            else { continue }
            options.append(ProviderAPIKeyOption(
                providerID: provider.id,
                displayName: provider.displayName,
                models: provider.models,
                keychainAccount: keyed.keychainAccount,
                keyHint: keyed.keyHint,
                keyConsoleURL: keyed.keyConsoleURL
            ))
        }

        for provider in registry.providers.compactMap({ $0 as? SubprocessProvider }) {
            guard let credential = provider.config.apiKeyCredential,
                  seen.insert(credential.keychainAccount).inserted
            else { continue }
            options.append(ProviderAPIKeyOption(
                providerID: provider.id,
                displayName: credential.displayName,
                models: provider.models,
                keychainAccount: credential.keychainAccount,
                keyHint: credential.keyHint,
                keyConsoleURL: credential.keyConsoleURL
            ))
        }
        return options
    }

    private func sectionHeader(_ title: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(theme.font(9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .kerning(1)
            Text(note)
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0 }
        )
    }
}

// MARK: - Account cards (CLI agents)

private struct AccountCard: View {
    @Environment(AccountSignIn.self) private var signIn
    @Environment(ProviderSetupCoordinator.self) private var providerSetup
    @Environment(\.theme) private var theme

    let provider: SubprocessProvider

    private var isClaude: Bool { provider.id == .claudeCLI }

    private var signedIn: Bool {
        ProviderAccountInfo.isSignedIn(provider.id)
    }

    private var apiKeyReady: Bool {
        guard let credential = provider.config.apiKeyCredential else { return false }
        return KeychainStore.get(account: credential.keychainAccount)?.isEmpty == false
    }

    var body: some View {
        @Bindable var signIn = signIn
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(signedIn || apiKeyReady ? theme.successColor : theme.textPrimary.opacity(0.2))
                    .frame(width: 8, height: 8)
                    .shadow(color: signedIn || apiKeyReady ? theme.successColor.opacity(0.7) : .clear, radius: 3)
                ProviderLogo(id: provider.id, size: 16)
                Text(provider.displayName)
                    .font(theme.font(12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(accountLabel)
                    .font(theme.font(9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.textPrimary.opacity(0.07)))
                Spacer()
                statusView
            }
            if !provider.models.isEmpty {
                Text("models: " + provider.models.map { $0.label }.joined(separator: " · "))
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
            actions
            if let status = providerSetup.statuses[provider.id] {
                Text(status.message)
                    .font(theme.font(9))
                    .foregroundStyle(status.isError ? theme.errorColor : theme.textSecondary)
            }
        }
        .padding(12)
        .background(shape.fill(theme.textPrimary.opacity(0.03)))
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }

    private var accountLabel: String {
        isClaude ? "Anthropic account" : (provider.config.accountLabel ?? "account")
    }

    @ViewBuilder
    private var statusView: some View {
        if signedIn {
            Text("Signed in" + (ClaudeAccountInfo.email.map { " as \($0)" } ?? ""))
                .font(theme.font(10))
                .foregroundStyle(theme.successColor)
        } else if apiKeyReady {
            Text("API key ready")
                .font(theme.font(10))
                .foregroundStyle(theme.successColor)
        } else if provider.resolvedExecutablePath == nil {
            Text("not installed")
                .font(theme.font(10))
                .foregroundStyle(theme.textTertiary)
        } else {
            Text(isClaude ? "not signed in" : "installed")
                .font(theme.font(10))
                .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let path = provider.resolvedExecutablePath {
            if isClaude {
                claudeActions(path: path)
            } else {
                HStack(spacing: 8) {
                    PillButton(signInButtonLabel, prominent: true) {
                        providerSetup.request(provider.id, force: true)
                    }
                    Text(signInHelp)
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        } else if provider.config.installAndAccountSetupCommand != nil {
            HStack(spacing: 8) {
                PillButton(installButtonLabel, prominent: true) {
                    providerSetup.request(provider.id, force: true)
                }
                Text(installHelp)
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
        } else {
            Text("No installer is configured for this CLI")
                .font(theme.font(9))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var installButtonLabel: String {
        if provider.id == .openCodeCLI { return "Install & configure" }
        return "Install & sign in"
    }

    private var installHelp: String {
        return switch provider.id {
        case .claudeCLI: "then opens Anthropic sign-in"
        case .codexCLI: "then opens ChatGPT sign-in"
        case .geminiCLI: "then starts Google account setup"
        case .openCodeCLI: "then lets you choose a model provider"
        case .cursorCLI: "then opens Cursor sign-in"
        case .vibeCLI: "then starts Mistral account setup"
        case .kimiCLI: "then opens Kimi device sign-in"
        case .grokCLI: "then opens xAI sign-in"
        default: "then starts the account setup"
        }
    }

    private var signInButtonLabel: String {
        switch provider.id {
        case .codexCLI: "Sign in with ChatGPT"
        case .geminiCLI: "Sign in with Google"
        case .openCodeCLI: "Choose a provider"
        case .cursorCLI: "Sign in with Cursor"
        case .vibeCLI: "Sign in with Mistral"
        case .kimiCLI: "Sign in with Kimi"
        case .grokCLI: "Sign in with xAI"
        default: "Sign in"
        }
    }

    private var signInHelp: String {
        provider.id == .openCodeCLI
            ? "opens OpenCode's provider setup in Terminal"
            : "opens the official sign-in flow in Terminal"
    }

    @ViewBuilder
    private func claudeActions(path: String) -> some View {
        @Bindable var signIn = signIn
        switch signIn.phase {
        case .running(let status):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(theme.font(10))
                        .foregroundStyle(theme.textSecondary)
                }
                HStack(spacing: 8) {
                    TextField("paste the authorization code here", text: $signIn.codeDraft)
                        .textFieldStyle(.plain)
                        .font(theme.font(10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
                        .frame(maxWidth: 300)
                        .onSubmit { signIn.submitCode() }
                    PillButton("Submit") { signIn.submitCode() }
                    PillButton("Cancel") { signIn.cancel() }
                }
            }
        case .idle, .failed, .done:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if signIn.claudeSignedInViaHorseToga {
                        PillButton("Sign out") { signIn.signOutClaude() }
                    }
                    PillButton(
                        signedIn ? "Use a different Anthropic account" : "Sign in with Anthropic",
                        prominent: !signedIn
                    ) {
                        signIn.signInClaude(claudePath: path)
                    }
                }
                if signedIn && !signIn.claudeSignedInViaHorseToga {
                    Text("Claude CLI is signed in; this creates a separate account token for HorseToga")
                        .font(theme.font(9))
                        .foregroundStyle(theme.textTertiary)
                }
                if case .failed(let message) = signIn.phase {
                    Text(message)
                        .font(theme.font(9))
                        .foregroundStyle(theme.errorColor)
                } else if signIn.phase == .done {
                    Text("Signed in — sessions now run on your subscription")
                        .font(theme.font(10))
                        .foregroundStyle(theme.successColor)
                }
            }
        }
    }

}

// MARK: - API key cards

private struct APIKeyCard: View {
    @Environment(ProviderRegistry.self) private var registry
    @Environment(\.theme) private var theme

    let option: ProviderAPIKeyOption
    @Binding var draft: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(hasKey ? theme.successColor : theme.textPrimary.opacity(0.2))
                    .frame(width: 7, height: 7)
                ProviderLogo(id: option.providerID, size: 16)
                Text(option.displayName)
                    .font(theme.font(12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(hasKey ? "saved securely" : "needs a key")
                    .font(theme.font(10))
                    .foregroundStyle(hasKey ? theme.successColor : theme.textTertiary)
            }
            if !option.models.isEmpty {
                Text("models: " + option.models.map { $0.label }.joined(separator: " · "))
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
            keyRow
        }
        .padding(12)
        .background(shape.fill(theme.textPrimary.opacity(0.03)))
        .overlay(shape.strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }

    private var hasKey: Bool {
        KeychainStore.get(account: option.keychainAccount)?.isEmpty == false
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            SecureField(option.keyHint, text: $draft)
                .textFieldStyle(.plain)
                .font(theme.font(10))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.textPrimary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
                .frame(maxWidth: 260)
            PillButton("Save") {
                let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                KeychainStore.set(key, account: option.keychainAccount)
                draft = ""
                Task { await registry.refreshHealth() }
            }
            if hasKey {
                PillButton("Remove") {
                    KeychainStore.delete(account: option.keychainAccount)
                    Task { await registry.refreshHealth() }
                }
            }
            Spacer()
            Button {
                if let url = URL(string: option.keyConsoleURL) { NSWorkspace.shared.open(url) }
            } label: {
                Text("get a key ↗")
                    .font(theme.font(9))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Shared bits

private struct PillButton: View {
    @Environment(\.theme) private var theme
    let label: String
    let prominent: Bool
    let action: () -> Void

    init(_ label: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.font(10, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(theme.backgroundColor) : AnyShapeStyle(theme.textSecondary))
                .padding(.horizontal, prominent ? 10 : 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.textPrimary.opacity(0.07)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// Opens a self-deleting `.command` file in Terminal. Launch Services handles
/// this as a normal document open, so sign-in does not depend on the fragile
/// Apple Events / Automation permission path.
@MainActor
enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case terminalDidNotOpen

        var errorDescription: String? {
            switch self {
            case .terminalDidNotOpen:
                "Terminal could not open the sign-in command. Check that Terminal.app is available."
            }
        }
    }

    static func run(_ command: String, providerName: String, providerID: ProviderID) throws {
        let url = try prepareCommandFile(
            command: command,
            providerName: providerName,
            providerID: providerID
        )
        guard NSWorkspace.shared.open(url) else {
            try? FileManager.default.removeItem(at: url)
            NSLog("HorseToga: provider setup failed to open in Terminal for %@", providerName)
            throw LaunchError.terminalDidNotOpen
        }
        NSLog("HorseToga: provider setup opened in Terminal for %@", providerName)
    }

    static func prepareCommandFile(
        command: String,
        providerName: String,
        providerID: ProviderID
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "horsetoga-provider-\(UUID().uuidString).command")
        let label = shellQuote(providerName)
        let marker = ProviderAccountInfo.authMarkerURL(for: providerID)
        let markerDirectory = shellQuote(marker.deletingLastPathComponent().path)
        let markerPath = shellQuote(marker.path)
        let script = """
        #!/bin/zsh
        rm -f -- "$0"
        export PATH="$HOME/.grok/bin:$HOME/.codex/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
        clear
        printf 'HorseToga — %s setup\\n\\n' \(label)
        \(command)
        horsetoga_status=$?
        printf '\\n'
        if (( horsetoga_status == 0 )); then
          mkdir -p \(markerDirectory)
          : > \(markerPath)
          printf 'Setup finished. Return to HorseToga, then press any key to close this window.\\n'
        else
          printf 'Setup failed (exit %d). The error above explains what needs attention.\\n' "$horsetoga_status" >&2
          printf 'Press any key to close this window.\\n'
        fi
        read -k 1
        exit "$horsetoga_status"
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class ProvidersAppModule: AppModule {
    let id = "providers"
    let name = "Providers"
    let icon = "key.horizontal"

    func makeView() -> AnyView {
        AnyView(ProvidersAppView())
    }

    func snapshot() async -> AppSnapshot {
        let registry = AppServices.shared.providers
        let lines = registry.providers.map { provider in
            let state: String = switch registry.health[provider.id] {
            case .success: "ready"
            case .failure(let error): error.description
            case nil: "unknown"
            }
            return "\(provider.displayName): \(state)"
        }
        return AppSnapshot(summary: "Providers:\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - Brand marks

/// Vendor marks drawn natively (no bundled assets): recognizable at 12–18pt,
/// crisp in any theme. Superset-style identity for every agent.
struct ProviderLogo: View {
    let id: ProviderID
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch id {
            case .claudeCLI, .anthropicAPI: claudeMark
            case .codexCLI, .openAIAPI: openAIMark
            case .geminiCLI, .geminiAPI: geminiMark
            case .openCodeCLI: openCodeMark
            case .cursorCLI: cursorMark
            case .vibeCLI, .mistralAPI: mistralMark
            case .kimiCLI, .kimiAPI: kimiMark
            case .grokCLI, .xaiAPI: xMark
            default:
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    /// Orange sunburst: twelve tapered rays.
    private var claudeMark: some View {
        Canvas { ctx, rect in
            let c = CGPoint(x: rect.width / 2, y: rect.height / 2)
            let r = min(rect.width, rect.height) / 2
            for i in 0..<12 {
                let angle = Double(i) / 12 * 2 * .pi
                let length = r * (i % 2 == 0 ? 1.0 : 0.72)
                var path = Path()
                path.move(to: CGPoint(x: c.x + cos(angle) * r * 0.18, y: c.y + sin(angle) * r * 0.18))
                path.addLine(to: CGPoint(x: c.x + cos(angle) * length, y: c.y + sin(angle) * length))
                ctx.stroke(path, with: .color(Color(red: 0.85, green: 0.47, blue: 0.34)),
                           style: StrokeStyle(lineWidth: r * 0.22, lineCap: .round))
            }
        }
    }

    /// Hexagonal knot: six rounded petals around a hollow center.
    private var openAIMark: some View {
        Canvas { ctx, rect in
            let c = CGPoint(x: rect.width / 2, y: rect.height / 2)
            let r = min(rect.width, rect.height) / 2
            for i in 0..<6 {
                let angle = Double(i) / 6 * 2 * .pi - .pi / 2
                let petal = CGRect(x: -r * 0.26, y: -r, width: r * 0.52, height: r * 0.95)
                var t = CGAffineTransform(translationX: c.x, y: c.y)
                t = t.rotated(by: angle)
                let path = Path(roundedRect: petal, cornerRadius: r * 0.26).applying(t)
                ctx.stroke(path, with: .color(.primary.opacity(0.9)), lineWidth: r * 0.16)
            }
        }
    }

    /// Four-point sparkle, blue → violet.
    private var geminiMark: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.95, weight: .medium))
            .foregroundStyle(LinearGradient(
                colors: [Color(red: 0.31, green: 0.55, blue: 0.98), Color(red: 0.62, green: 0.40, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
    }

    /// Terminal window: square frame with a filled lower pane.
    private var openCodeMark: some View {
        Canvas { ctx, rect in
            let s = min(rect.width, rect.height)
            let frame = CGRect(x: (rect.width - s) / 2, y: (rect.height - s) / 2, width: s, height: s).insetBy(dx: s * 0.08, dy: s * 0.08)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: s * 0.12), with: .color(.primary.opacity(0.9)), lineWidth: s * 0.12)
            let pane = CGRect(x: frame.minX + s * 0.22, y: frame.midY - s * 0.02, width: frame.width - s * 0.44, height: frame.height * 0.34)
            ctx.fill(Path(roundedRect: pane, cornerRadius: s * 0.05), with: .color(.primary.opacity(0.9)))
        }
    }

    private var cursorMark: some View {
        Image(systemName: "cube.fill")
            .font(.system(size: size * 0.95, weight: .regular))
            .foregroundStyle(.primary.opacity(0.85))
    }

    /// Pixel "M" in Mistral's yellow → red rows.
    private var mistralMark: some View {
        Canvas { ctx, rect in
            let rows: [[Int]] = [
                [1, 0, 0, 0, 1],
                [1, 1, 0, 1, 1],
                [1, 0, 1, 0, 1],
                [1, 0, 0, 0, 1],
                [1, 0, 0, 0, 1],
            ]
            let colors = [
                Color(red: 1.0, green: 0.82, blue: 0.0), Color(red: 1.0, green: 0.65, blue: 0.0),
                Color(red: 1.0, green: 0.45, blue: 0.0), Color(red: 0.98, green: 0.30, blue: 0.05),
                Color(red: 0.88, green: 0.12, blue: 0.08),
            ]
            let cell = min(rect.width, rect.height) / 5
            let ox = (rect.width - cell * 5) / 2, oy = (rect.height - cell * 5) / 2
            for (y, row) in rows.enumerated() {
                for (x, on) in row.enumerated() where on == 1 {
                    ctx.fill(Path(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: cell, height: cell)),
                             with: .color(colors[y]))
                }
            }
        }
    }

    /// Rounded face with two eyes.
    private var kimiMark: some View {
        Canvas { ctx, rect in
            let s = min(rect.width, rect.height)
            let face = CGRect(x: (rect.width - s) / 2, y: (rect.height - s) / 2, width: s, height: s).insetBy(dx: s * 0.08, dy: s * 0.16)
            ctx.stroke(Path(roundedRect: face, cornerRadius: s * 0.22), with: .color(.primary.opacity(0.9)), lineWidth: s * 0.12)
            for x in [face.midX - s * 0.16, face.midX + s * 0.16] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - s * 0.07, y: face.midY - s * 0.07, width: s * 0.14, height: s * 0.14)),
                         with: .color(.primary.opacity(0.9)))
            }
        }
    }

    /// xAI: a sharp X with one long stroke.
    private var xMark: some View {
        Canvas { ctx, rect in
            let s = min(rect.width, rect.height)
            let b = CGRect(x: (rect.width - s) / 2, y: (rect.height - s) / 2, width: s, height: s).insetBy(dx: s * 0.1, dy: s * 0.1)
            var long = Path()
            long.move(to: CGPoint(x: b.minX, y: b.minY))
            long.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
            ctx.stroke(long, with: .color(.primary.opacity(0.95)), style: StrokeStyle(lineWidth: s * 0.16, lineCap: .round))
            var short = Path()
            short.move(to: CGPoint(x: b.maxX, y: b.minY))
            short.addLine(to: CGPoint(x: b.midX + s * 0.04, y: b.midY - s * 0.04))
            ctx.stroke(short, with: .color(.primary.opacity(0.95)), style: StrokeStyle(lineWidth: s * 0.16, lineCap: .round))
        }
    }

    // MARK: Rasterized for AppKit menus

    private static var cache: [ProviderID: NSImage] = [:]

    /// NSMenu items can't host SwiftUI views, so the mark is rendered once per id.
    static func image(for id: ProviderID) -> NSImage? {
        if let cached = cache[id] { return cached }
        let renderer = ImageRenderer(content: ProviderLogo(id: id, size: 14).foregroundStyle(Color.white).padding(1))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        cache[id] = image
        return image
    }
}

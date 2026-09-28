//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import Foundation

// "Sign in with your account": drives the vendor CLI's browser OAuth from
// inside HorseToga. For Claude Code, `claude setup-token` runs in a hidden PTY —
// HorseToga opens the browser page it prints, forwards the pasted authorization
// code, and stores the resulting long-lived token in the Keychain. Spawned
// sessions then authenticate via CLAUDE_CODE_OAUTH_TOKEN, billed to the
// user's subscription. No API key anywhere.

/// A child process on a pseudo-terminal (interactive CLIs refuse pipes).
nonisolated final class PTYProcess: @unchecked Sendable {
    private let process = Process()
    private let master: FileHandle
    private let onOutput: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(
        executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.onOutput = onOutput
        self.onExit = onExit
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        // Very wide terminal: long OAuth tokens must never line-wrap, or the
        // output parser would capture a truncated (invalid) fragment.
        var size = winsize(ws_row: 40, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw NSError(domain: "PTYProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ProcessRunner.baseEnvironment(extra: ["TERM": "xterm-256color"])
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
    }

    func start() throws {
        master.readabilityHandler = { [onOutput] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            onOutput(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self, onExit] finished in
            self?.master.readabilityHandler = nil
            onExit(finished.terminationStatus)
        }
        try process.run()
    }

    func write(_ text: String) {
        try? master.write(contentsOf: Data(text.utf8))
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// State machine behind the "Sign in with Anthropic" button.
@MainActor
@Observable
final class AccountSignIn {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)
    }

    nonisolated static let claudeTokenAccount = "claude-account-oauth-token"

    private(set) var phase: Phase = .idle
    private(set) var outputTail = ""
    var codeDraft = ""
    private var pty: PTYProcess?
    private var openedURL = false

    var claudeSignedInViaHorseToga: Bool {
        KeychainStore.get(account: Self.claudeTokenAccount)?.isEmpty == false
    }

    func signInClaude(claudePath: String) {
        cancel()
        // Start clean: a leftover (possibly expired) token would otherwise let an
        // early process exit read as success, hiding the code-paste field — and it
        // keeps the app claiming "signed in" while every run 401s.
        KeychainStore.delete(account: Self.claudeTokenAccount)
        openedURL = false
        outputTail = ""
        codeDraft = ""
        phase = .running("starting browser sign-in…")
        do {
            let pty = try PTYProcess(
                executable: claudePath,
                arguments: ["setup-token"],
                onOutput: { chunk in
                    Task { @MainActor in AppServices.shared.accountSignIn.consume(chunk) }
                },
                onExit: { code in
                    Task { @MainActor in AppServices.shared.accountSignIn.processExited(code) }
                }
            )
            self.pty = pty
            try pty.start()
        } catch {
            phase = .failed("couldn't start claude: \(error.localizedDescription)")
        }
    }

    /// The authorization code the browser shows at the end of the OAuth flow.
    func submitCode() {
        let code = codeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        pty?.write(code + "\r")
        codeDraft = ""
        phase = .running("verifying…")
    }

    func cancel() {
        pty?.terminate()
        pty = nil
        if phase != .done { phase = .idle }
    }

    func signOutClaude() {
        KeychainStore.delete(account: Self.claudeTokenAccount)
        phase = .idle
        Task { await AppServices.shared.providers.refreshHealth() }
    }

    // MARK: - PTY parsing

    private func consume(_ raw: String) {
        let text = Self.stripANSI(raw)
        outputTail = String((outputTail + text).suffix(800))
        if !openedURL, let url = Self.firstURL(in: outputTail) {
            openedURL = true
            NSWorkspace.shared.open(url)
            phase = .running("finish signing in in your browser, then paste the code below")
        }
        if let token = Self.oauthToken(in: outputTail) {
            KeychainStore.set(token, account: Self.claudeTokenAccount)
            phase = .done
            pty?.terminate()
            pty = nil
            Task { await AppServices.shared.providers.refreshHealth() }
        } else if text.contains("Press Enter") {
            pty?.write("\r")
        }
    }

    private func processExited(_ code: Int32) {
        pty = nil
        switch phase {
        case .done, .failed, .idle:
            break
        case .running:
            if claudeSignedInViaHorseToga {
                phase = .done
            } else {
                let tail = outputTail.split(separator: "\n").suffix(3).joined(separator: " ")
                phase = .failed("sign-in didn't finish (exit \(code)) \(tail.isEmpty ? "" : "— \(tail)")")
            }
        }
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
            .replacing("\r", with: "")
    }

    private static func firstURL(in text: String) -> URL? {
        guard let match = text.firstMatch(of: /https:\/\/[^\s"'\)\]]+/) else { return nil }
        return URL(string: String(match.0))
    }

    private static func oauthToken(in text: String) -> String? {
        // setup-token output: "sk-ant-oat01-…", ~100 chars. The strict prefix +
        // length floor rejects wrapped/truncated fragments and lookalikes.
        guard let match = text.firstMatch(of: /sk-ant-oat[A-Za-z0-9_\-]{40,}/) else { return nil }
        return String(match.0)
    }
}

/// Shared handoff from model selection (or a Providers button) into the right
/// account setup surface. The selected provider/model stays on the chat while
/// this coordinator opens the required sign-in flow.
@MainActor
@Observable
final class ProviderSetupCoordinator {
    struct Status: Equatable {
        var message: String
        var isError: Bool
    }

    private(set) var statuses: [ProviderID: Status] = [:]

    func request(_ providerID: ProviderID, force: Bool = false) {
        let services = AppServices.shared
        NSLog("HorseToga: provider setup requested for %@ (force=%@)", providerID.raw, force.description)

        // Missing credentials and missing executables are both synchronous facts.
        // Act on them immediately so selecting Gemini (whose first interactive
        // launch owns OAuth) cannot lose its setup prompt behind an async hop.
        if let requirement = services.providers.setupRequirement(for: providerID, force: force) {
            NSLog("HorseToga: provider setup required immediately for %@", providerID.raw)
            begin(requirement, services: services)
            return
        }

        statuses[providerID] = Status(message: "Checking sign-in status…", isError: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let requirement = await services.providers.verifiedSetupRequirement(
                for: providerID,
                force: force
            ) else {
                NSLog("HorseToga: provider account already ready for %@", providerID.raw)
                statuses[providerID] = nil
                return
            }
            NSLog("HorseToga: provider setup required after verification for %@", providerID.raw)
            begin(requirement, services: services)
        }
    }

    private func begin(_ requirement: ProviderSetupRequirement, services: AppServices) {
        services.apps.openSection("providers")
        switch requirement {
        case .claude(let executablePath):
            NSLog("HorseToga: starting in-app Anthropic sign-in")
            statuses[.claudeCLI] = Status(
                message: "Finish signing in with Anthropic in your browser.",
                isError: false
            )
            services.accountSignIn.signInClaude(claudePath: executablePath)

        case .terminal(let id, let providerName, let command):
            statuses[id] = Status(message: "Opening \(providerName) setup in Terminal…", isError: false)
            do {
                try TerminalLauncher.run(
                    command,
                    providerName: providerName,
                    providerID: id
                )
                statuses[id] = Status(
                    message: "Continue in Terminal; browser sign-in opens automatically.",
                    isError: false
                )
            } catch {
                NSLog("HorseToga: provider setup launch failed for %@: %@", id.raw, error.localizedDescription)
                statuses[id] = Status(message: error.localizedDescription, isError: true)
            }

        case .apiKey(let id):
            NSLog("HorseToga: provider setup requires an API key for %@", id.raw)
            statuses[id] = Status(
                message: "This provider uses an API key. Add it below to continue with the selected model.",
                isError: false
            )
        }
    }
}

/// Credential probes only. Tokens remain owned by their vendor CLI; HorseToga reads
/// neither their contents nor any browser session data. Where supported, the
/// CLI's own read-only status command is authoritative.
nonisolated enum ProviderAccountInfo {
    static func isSignedIn(_ providerID: ProviderID, home: String = NSHomeDirectory()) -> Bool {
        switch providerID {
        case .claudeCLI:
            return KeychainStore.get(account: AccountSignIn.claudeTokenAccount)?.isEmpty == false
        case .codexCLI:
            return nonemptyFile("\(home)/.codex/auth.json")
        case .grokCLI:
            return nonemptyFile("\(home)/.grok/auth.json")
        case .geminiCLI:
            return nonemptyFile("\(home)/.gemini/oauth_creds.json")
        case .openCodeCLI:
            return nonemptyFile("\(home)/.local/share/opencode/auth.json")
        case .cursorCLI, .vibeCLI, .kimiCLI:
            return FileManager.default.fileExists(atPath: authMarkerURL(for: providerID, home: home).path)
        default:
            return false
        }
    }

    static func isVerifiedSignedIn(_ provider: SubprocessProvider) async -> Bool {
        guard let executablePath = provider.runnableExecutablePath else { return false }
        switch provider.id {
        case .claudeCLI:
            if isSignedIn(.claudeCLI) { return true }
            guard let result = await commandOutput(
                executablePath: executablePath,
                arguments: ["auth", "status", "--json"]
            ) else { return false }
            let compact = result.output.replacingOccurrences(of: " ", with: "")
            return result.code == 0 && compact.contains(#""loggedIn":true"#)

        case .codexCLI:
            guard let result = await commandOutput(
                executablePath: executablePath,
                arguments: ["login", "status"]
            ) else { return isSignedIn(.codexCLI) }
            let output = result.output.lowercased()
            return result.code == 0
                && output.contains("logged in")
                && !output.contains("not logged in")

        default:
            return isSignedIn(provider.id)
        }
    }

    static func authMarkerURL(for providerID: ProviderID, home: String = NSHomeDirectory()) -> URL {
        URL(filePath: home)
            .appending(path: "Library/Application Support/com.jasonchan.horsetoga/provider-auth")
            .appending(path: providerID.raw)
    }

    private static func nonemptyFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    private static func commandOutput(
        executablePath: String,
        arguments: [String]
    ) async -> (code: Int32, output: String)? {
        var output = ""
        do {
            let stream = ProcessRunner.run(SubprocessSpec(
                executablePath: executablePath,
                arguments: arguments,
                watchdogSeconds: 10
            ))
            for try await event in stream {
                switch event {
                case .spawned:
                    break
                case .line(let data):
                    output += String(decoding: data, as: UTF8.self) + "\n"
                case .exited(let code, let stderrTail):
                    output += stderrTail
                    return (code, output)
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

/// Read-only facts about the user's Claude account on this machine.
nonisolated enum ClaudeAccountInfo {
    /// Email from ~/.claude.json's oauthAccount, written by the CLI's own login.
    static var email: String? {
        let url = URL(filePath: NSHomeDirectory()).appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any]
        else { return nil }
        return account["emailAddress"] as? String
    }

    /// True when the standalone claude CLI has its own keychain login.
    static var cliKeychainLogin: Bool {
        KeychainStore.externalItemExists(service: "Claude Code-credentials")
    }
}

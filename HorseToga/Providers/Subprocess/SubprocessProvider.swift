//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// An optional API-key route for a vendor CLI. HorseToga owns the secret in the
/// Keychain and injects it only into that CLI's child-process environment.
nonisolated struct CLIAPIKeyCredential: Codable, Sendable, Hashable {
    var displayName: String
    var environmentVariable: String
    var keychainAccount: String
    var keyHint: String
    var keyConsoleURL: String
    /// Non-secret companion variables required by a CLI's explicit key mode.
    var additionalEnvironment: [String: String]?

    nonisolated func environment(apiKey: String) -> [String: String] {
        var environment = additionalEnvironment ?? [:]
        environment[environmentVariable] = apiKey
        return environment
    }
}

/// Invocation is DATA, not code: CLI flags drift between releases, so argv lives in
/// a user-editable config and a flag change is a config edit, not an app update.
nonisolated struct SubprocessProviderConfig: Codable, Sendable {
    enum ParserKind: String, Codable, Sendable {
        case claudeStreamJSON = "claude-stream-json"
        case codexJSON = "codex-json"
        /// Plain stdout text — the universal fallback for any CLI agent.
        case plainText = "plain-text"
    }

    var id: String
    var displayName: String
    /// Bare name (resolved against HorseToga's fixed PATH) or absolute/~-path.
    var executable: String
    var newSessionArgs: [String]
    /// Used instead of newSessionArgs when resuming; supports the {{session}} slot.
    var resumeArgs: [String]
    var modelArgs: [String] = [] // e.g. ["--model", "{{model}}"]
    var models: [ModelOption] = []
    /// Account sign-in via HorseToga: when this Keychain account holds a token
    /// (from the in-app browser OAuth), it is exported to the child under this
    /// env var — subscription-billed auth with no CLI-side login.
    var tokenEnvVar: String?
    var tokenKeychainAccount: String?
    /// Optional direct API billing, independent of the vendor account login.
    var apiKeyCredential: CLIAPIKeyCredential?
    var parser: ParserKind
    var watchdogSeconds: Double = 90
    /// Providers-app metadata: whose account signs in, how to install the CLI,
    /// and the CLI's own login subcommand (nil = first interactive run logs in).
    var accountLabel: String?
    var installCommand: String?
    var loginArgs: [String]?
    /// A cheap invocation (e.g. `--version`) used to confirm the resolved binary
    /// actually runs before HorseToga relies on it — guards broken npm-launcher
    /// installs whose platform binary is missing. Empty means "trust that the
    /// file exists" (for CLIs without a dependable version flag).
    var versionProbeArgs: [String] = []

    static let claudeDefault = SubprocessProviderConfig(
        id: ProviderID.claudeCLI.raw,
        displayName: "Claude Code",
        executable: "claude",
        // Headless (`--print`) has no channel to answer permission prompts, so
        // without a pre-authorization flag every Write/Edit/Bash is auto-denied
        // and the agent can only read. `--dangerously-skip-permissions` runs the
        // agent with full autonomy — the point of an agent workspace.
        newSessionArgs: [
            "--print", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
            "--dangerously-skip-permissions",
        ],
        resumeArgs: [
            "--print", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
            "--dangerously-skip-permissions",
            "--resume", "{{session}}",
        ],
        modelArgs: ["--model", "{{model}}"],
        models: [
            ModelOption("Default"),
            ModelOption("Opus", "opus"),
            ModelOption("Sonnet", "sonnet"),
            ModelOption("Haiku", "haiku"),
        ],
        tokenEnvVar: "CLAUDE_CODE_OAUTH_TOKEN",
        tokenKeychainAccount: "claude-account-oauth-token",
        parser: .claudeStreamJSON,
        versionProbeArgs: ["--version"]
    )

    static let codexDefault = SubprocessProviderConfig(
        id: ProviderID.codexCLI.raw,
        displayName: "Codex",
        executable: "codex",
        // `codex exec` is non-interactive, so it can't answer approval prompts;
        // without this its sandbox blocks writes and shell commands. Full autonomy,
        // matching Claude above. (`--full-auto` is the safer, workspace-scoped option.)
        newSessionArgs: ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "-"],
        resumeArgs: ["exec", "resume", "{{session}}", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "-"],
        modelArgs: ["--model", "{{model}}"],
        parser: .codexJSON,
        accountLabel: "ChatGPT account",
        installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        loginArgs: ["login"],
        versionProbeArgs: ["--version"]
    )

    // The rest of the roster streams plain text through the universal parser.
    // Flags are best-known defaults; ~/Library/Application Support/
    // com.jasonchan.horsetoga/providers.json overrides any entry by id.

    static let geminiDefault = SubprocessProviderConfig(
        id: ProviderID.geminiCLI.raw,
        displayName: "Gemini CLI",
        executable: "gemini",
        // Gemini downgrades --yolo back to prompt-mode unless the folder is also
        // trusted, so both flags are needed for headless writes to work.
        newSessionArgs: ["-p", "{{prompt}}", "--yolo", "--skip-trust"],
        resumeArgs: ["-p", "{{prompt}}", "--yolo", "--skip-trust"],
        modelArgs: ["-m", "{{model}}"],
        models: [ModelOption("Default"), ModelOption("2.5 Pro", "gemini-2.5-pro"), ModelOption("2.5 Flash", "gemini-2.5-flash")],
        apiKeyCredential: CLIAPIKeyCredential(
            displayName: "Google Gemini API",
            environmentVariable: "GEMINI_API_KEY",
            keychainAccount: "gemini-api-key",
            keyHint: "AI Studio API key",
            keyConsoleURL: "https://aistudio.google.com/apikey"
        ),
        parser: .plainText,
        accountLabel: "Google account",
        installCommand: "npm install -g @google/gemini-cli",
        versionProbeArgs: ["--version"]
    )

    static let openCodeDefault = SubprocessProviderConfig(
        id: ProviderID.openCodeCLI.raw,
        displayName: "OpenCode",
        executable: "opencode",
        newSessionArgs: ["run", "{{prompt}}"],
        resumeArgs: ["run", "{{prompt}}"],
        modelArgs: ["--model", "{{model}}"],
        parser: .plainText,
        accountLabel: "any provider (opencode auth)",
        installCommand: "npm install -g opencode-ai",
        loginArgs: ["auth", "login"]
    )

    static let cursorDefault = SubprocessProviderConfig(
        id: ProviderID.cursorCLI.raw,
        displayName: "Cursor Agent",
        executable: "cursor-agent",
        // cursor-agent gates on workspace trust AND command approval when run
        // non-interactively; --force (alias --yolo) clears both so writes work.
        newSessionArgs: ["-p", "{{prompt}}", "--output-format", "text", "--force"],
        resumeArgs: ["-p", "{{prompt}}", "--output-format", "text", "--force"],
        modelArgs: ["--model", "{{model}}"],
        apiKeyCredential: CLIAPIKeyCredential(
            displayName: "Cursor API key",
            environmentVariable: "CURSOR_API_KEY",
            keychainAccount: "cursor-api-key",
            keyHint: "Cursor user API key",
            keyConsoleURL: "https://cursor.com/dashboard"
        ),
        parser: .plainText,
        accountLabel: "Cursor account",
        installCommand: "curl https://cursor.com/install -fsS | bash",
        loginArgs: ["login"]
    )

    static let vibeDefault = SubprocessProviderConfig(
        id: ProviderID.vibeCLI.raw,
        displayName: "Mistral Vibe",
        executable: "vibe",
        newSessionArgs: ["-p", "{{prompt}}"],
        resumeArgs: ["-p", "{{prompt}}"],
        apiKeyCredential: CLIAPIKeyCredential(
            displayName: "Mistral API",
            environmentVariable: "MISTRAL_API_KEY",
            keychainAccount: "mistral-api-key",
            keyHint: "Mistral API key",
            keyConsoleURL: "https://console.mistral.ai"
        ),
        parser: .plainText,
        accountLabel: "Mistral account",
        installCommand: "curl -LsSf https://mistral.ai/vibe/install.sh | bash",
        loginArgs: ["--setup"]
    )

    static let kimiDefault = SubprocessProviderConfig(
        id: ProviderID.kimiCLI.raw,
        displayName: "Kimi Code",
        executable: "kimi",
        newSessionArgs: ["-p", "{{prompt}}"],
        resumeArgs: ["-p", "{{prompt}}"],
        apiKeyCredential: CLIAPIKeyCredential(
            displayName: "Kimi Platform API",
            environmentVariable: "KIMI_MODEL_API_KEY",
            keychainAccount: "kimi-api-key",
            keyHint: "Kimi Platform API key",
            keyConsoleURL: "https://platform.moonshot.ai/console/api-keys",
            additionalEnvironment: [
                "KIMI_MODEL_NAME": "kimi-k2.5",
                "KIMI_MODEL_PROVIDER_TYPE": "kimi",
                "KIMI_MODEL_BASE_URL": "https://api.moonshot.ai/v1",
            ]
        ),
        parser: .plainText,
        accountLabel: "Moonshot account",
        installCommand: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash",
        loginArgs: ["login"]
    )

    static let grokDefault = SubprocessProviderConfig(
        id: ProviderID.grokCLI.raw,
        displayName: "Grok CLI",
        executable: "grok",
        newSessionArgs: ["-p", "{{prompt}}"],
        resumeArgs: ["-p", "{{prompt}}"],
        modelArgs: ["--model", "{{model}}"],
        apiKeyCredential: CLIAPIKeyCredential(
            displayName: "xAI API",
            environmentVariable: "XAI_API_KEY",
            keychainAccount: "xai-api-key",
            keyHint: "xai-…",
            keyConsoleURL: "https://console.x.ai"
        ),
        parser: .plainText,
        accountLabel: "xAI account",
        installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash",
        loginArgs: ["login"]
    )

    static let builtIns: [SubprocessProviderConfig] = [
        claudeDefault, codexDefault, geminiDefault, openCodeDefault,
        cursorDefault, vibeDefault, kimiDefault, grokDefault,
    ]
}

/// Lenient decoding so a hand-written providers.json only needs the essentials.
extension SubprocessProviderConfig {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        executable = try c.decode(String.self, forKey: .executable)
        newSessionArgs = try c.decode([String].self, forKey: .newSessionArgs)
        resumeArgs = try c.decodeIfPresent([String].self, forKey: .resumeArgs) ?? newSessionArgs
        modelArgs = try c.decodeIfPresent([String].self, forKey: .modelArgs) ?? []
        models = try c.decodeIfPresent([ModelOption].self, forKey: .models) ?? []
        tokenEnvVar = try c.decodeIfPresent(String.self, forKey: .tokenEnvVar)
        tokenKeychainAccount = try c.decodeIfPresent(String.self, forKey: .tokenKeychainAccount)
        apiKeyCredential = try c.decodeIfPresent(CLIAPIKeyCredential.self, forKey: .apiKeyCredential)
        parser = try c.decodeIfPresent(ParserKind.self, forKey: .parser) ?? .plainText
        watchdogSeconds = try c.decodeIfPresent(Double.self, forKey: .watchdogSeconds) ?? 90
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        installCommand = try c.decodeIfPresent(String.self, forKey: .installCommand)
        loginArgs = try c.decodeIfPresent([String].self, forKey: .loginArgs)
    }

    /// A safely quoted command for the CLI's own account setup. A nil `loginArgs`
    /// means the first interactive launch owns setup (Gemini, for example).
    nonisolated func accountSignInCommand(executablePath: String? = nil) -> String {
        return ([executablePath ?? executable] + (loginArgs ?? []))
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    /// One Terminal command that installs the CLI and proceeds directly into its
    /// account flow. The PATH refresh covers the common destinations used by the
    /// standalone installers without requiring the user to open a second shell.
    nonisolated var installAndAccountSetupCommand: String? {
        guard let installCommand, !installCommand.isEmpty else { return nil }
        let signIn = accountSignInCommand()
        let refreshPath = #"export PATH="$HOME/.grok/bin:$HOME/.codex/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" && hash -r"#
        return "\(installCommand) && \(refreshPath) && \(signIn)"
    }

    private nonisolated static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

nonisolated struct SubprocessProvider: ChatProvider {
    let config: SubprocessProviderConfig

    var id: ProviderID { ProviderID(config.id) }
    var displayName: String { config.displayName }
    var models: [ModelOption] { config.models }

    /// Where the binary actually resolved to, for the Providers app's status row.
    var resolvedExecutablePath: String? { try? resolveExecutable() }

    /// Like `resolvedExecutablePath`, but only yields a binary that actually
    /// runs. Setup, sign-in verification, and preflight use this so a broken
    /// install (npm launcher with a missing platform binary, wrong-arch binary,
    /// half-written file) is treated as "not installed" and triggers a clean
    /// (re)install instead of launching a doomed process.
    var runnableExecutablePath: String? { try? resolveExecutable(requireRunnable: true) }

    /// Like `runnableExecutablePath`, but never launches a probe: an unprobed
    /// binary is assumed runnable. For view bodies, where a blocking `--version`
    /// probe per CLI would freeze the UI (the launch warm-up fills the cache).
    var knownRunnableExecutablePath: String? {
        try? resolveExecutable(requireRunnable: true, probeUncached: false)
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            isStateful: true,
            needsWorkingDirectory: true,
            emitsToolEvents: true,
            emitsUsage: true,
            supportsPersistentProcess: false,
            coldStartEstimate: .seconds(2)
        )
    }

    func preflight() async throws {
        _ = try resolveExecutable(requireRunnable: true)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.started(runID: UUID()))
                    let executable = try resolveExecutable()
                    var prompt = request.latestUserText
                    if request.handle == nil, let system = request.system, !system.isEmpty {
                        prompt = system + "\n\n" + prompt
                    }

                    var slots: [String: String] = ["prompt": prompt]
                    if let handle = request.handle { slots["session"] = handle.token }
                    if let model = request.model { slots["model"] = model }

                    // Prompt goes over stdin (immune to ARG_MAX and quoting) unless
                    // the CLI only takes it as an argument — then the {{prompt}} slot.
                    let template = request.handle != nil ? config.resumeArgs : config.newSessionArgs
                    let promptInArgs = template.contains { $0.contains("{{prompt}}") }
                    var args = ArgvTemplate.render(template, slots: slots)
                    if request.model != nil {
                        args += ArgvTemplate.render(config.modelArgs, slots: slots)
                    }

                    var extraEnvironment: [String: String] = [:]
                    if let envVar = config.tokenEnvVar,
                       let account = config.tokenKeychainAccount,
                       let token = KeychainStore.get(account: account), !token.isEmpty {
                        extraEnvironment[envVar] = token
                    }
                    if let credential = config.apiKeyCredential,
                       let apiKey = KeychainStore.get(account: credential.keychainAccount),
                       !apiKey.isEmpty {
                        extraEnvironment.merge(credential.environment(apiKey: apiKey)) { _, new in new }
                    }

                    let spec = SubprocessSpec(
                        executablePath: executable,
                        arguments: args,
                        stdinData: promptInArgs ? nil : Data(prompt.utf8),
                        workingDirectory: request.workingDirectory,
                        extraEnvironment: extraEnvironment,
                        watchdogSeconds: config.watchdogSeconds
                    )
                    let parser = makeParser()

                    for try await event in ProcessRunner.run(spec) {
                        switch event {
                        case .spawned:
                            break
                        case .line(let data):
                            for parsed in parser.parse(line: data) {
                                continuation.yield(parsed)
                            }
                        case .exited(let code, let stderrTail):
                            if !parser.sawTerminal {
                                if code == 0 {
                                    continuation.yield(.finished(.completed))
                                } else {
                                    throw ProviderError.executableFailed(
                                        path: executable,
                                        exitCode: code,
                                        stderrTail: String(stderrTail.suffix(500))
                                    )
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeParser() -> any SubprocessOutputParser {
        switch config.parser {
        case .claudeStreamJSON: ClaudeStreamJSONParser(providerID: id)
        case .codexJSON: CodexJSONParser(providerID: id)
        case .plainText: PlainTextParser()
        }
    }

    private func resolveExecutable(requireRunnable: Bool = false, probeUncached: Bool = true) throws -> String {
        // `requireRunnable` additionally confirms the candidate actually executes,
        // so a present-but-broken binary is skipped in favour of the next match
        // (a bundled CLI, or ultimately none → the installer path).
        func runnable(_ path: String) -> Bool {
            guard requireRunnable else { return true }
            if probeUncached { return ProcessRunner.isRunnable(path, probeArgs: config.versionProbeArgs) }
            return ProcessRunner.cachedRunnable(path, probeArgs: config.versionProbeArgs) ?? true
        }
        let raw = config.executable
        if raw.contains("/") {
            let expanded = NSString(string: raw).expandingTildeInPath
            if requireRunnable,
               !(FileManager.default.isExecutableFile(atPath: expanded) && runnable(expanded)) {
                throw ProviderError.executableMissing(path: expanded)
            }
            return expanded
        }
        // Bare name: search the same fixed PATH the child will run with, plus
        // per-user node installs (~/.local/opt/<node>/bin) since GUI apps never
        // inherit shell PATH customizations.
        let home = NSHomeDirectory()
        var searchPaths = ProcessRunner.executableSearchPaths(home: home)
        let optRoot = "\(home)/.local/opt"
        if let opts = try? FileManager.default.contentsOfDirectory(atPath: optRoot) {
            searchPaths += opts.map { "\(optRoot)/\($0)/bin" }
        }
        // Keep the first present-but-broken match so the error names a real path
        // for diagnostics rather than the bare command name.
        var brokenCandidate: String?
        for dir in searchPaths {
            let candidate = "\(dir)/\(raw)"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if runnable(candidate) { return candidate }
            brokenCandidate = brokenCandidate ?? candidate
        }
        if let bundled = Self.bundledExecutable(named: raw), runnable(bundled) {
            return bundled
        }
        throw ProviderError.executableMissing(path: brokenCandidate ?? raw)
    }

    /// Last resort: desktop apps can bundle their vendor CLI without putting it
    /// on PATH. Reuse those signed binaries instead of asking for a duplicate
    /// installation.
    private static func bundledExecutable(named name: String) -> String? {
        switch name {
        case "codex":
            let candidates = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex",
            ]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        case "claude":
            let root = "\(NSHomeDirectory())/Library/Application Support/Claude/claude-code"
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let candidate = "\(root)/\(version)/claude.app/Contents/MacOS/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        default:
            return nil
        }
    }
}

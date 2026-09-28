//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Testing
@testable import HorseToga

@Suite("ClaudeStreamJSONParser")
struct ClaudeParserTests {
    private func fixtureLines(_ name: String) throws -> [Data] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let raw = try Data(contentsOf: url)
        return raw.split(separator: UInt8(0x0A)).map { Data($0) }
    }

    @Test("auth-error fixture: real captured output maps to notice + text + error finish")
    func authErrorFixture() throws {
        let parser = ClaudeStreamJSONParser(providerID: .claudeCLI)
        var events: [StreamEvent] = []
        for line in try fixtureLines("claude-auth-error.jsonl") {
            events.append(contentsOf: parser.parse(line: line))
        }
        #expect(parser.sawTerminal)

        // Session handle from the init envelope
        let handles = events.compactMap { if case .handleIssued(let h) = $0 { h } else { nil } }
        #expect(handles.first?.token == "35196602-c4d9-4707-8312-105f7091b5a2")

        // Assistant text (no stream deltas came before it, so full text is emitted)
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text.contains("Failed to authenticate"))

        // Terminal error
        let finish = events.compactMap { if case .finished(let r) = $0 { r } else { nil } }.last
        #expect(finish == .error("Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue."))
    }

    @Test("streamed deltas suppress the duplicate full assistant message")
    func deltaDedupe() {
        let parser = ClaudeStreamJSONParser(providerID: .claudeCLI)
        var events: [StreamEvent] = []
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start"}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.001,"session_id":"s1"}"#,
        ]
        for line in lines {
            events.append(contentsOf: parser.parse(line: Data(line.utf8)))
        }
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "hello") // NOT "hellohello"

        let usage = events.compactMap { if case .usage(let u) = $0 { u } else { nil } }.last
        #expect(usage?.inputTokens == 10)
        #expect(usage?.costUSD == 0.001)

        let finish = events.compactMap { if case .finished(let r) = $0 { r } else { nil } }.last
        #expect(finish == .completed)
    }

    @Test("tool use start/finish pairing")
    func toolEvents() {
        let parser = ClaudeStreamJSONParser(providerID: .claudeCLI)
        var events: [StreamEvent] = []
        let lines = [
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"t1","name":"Bash"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt","is_error":false}]}}"#,
        ]
        for line in lines {
            events.append(contentsOf: parser.parse(line: Data(line.utf8)))
        }
        let starts = events.filter { if case .toolUseStarted = $0 { true } else { false } }
        #expect(starts.count == 1) // content_block_start seen; assistant envelope must not double it
        let finishes = events.compactMap { if case .toolUseFinished(_, let r, let e) = $0 { (r, e) } else { nil } }
        #expect(finishes.first?.0 == "file.txt")
        #expect(finishes.first?.1 == false)
    }

    @Test("garbage and unknown envelopes are ignored, never fatal")
    func tolerance() {
        let parser = ClaudeStreamJSONParser(providerID: .claudeCLI)
        let lines = [
            "not json at all",
            #"{"type":"totally_new_event_kind","payload":{}}"#,
            #"{"no_type_key":1}"#,
            "",
        ]
        for line in lines {
            #expect(parser.parse(line: Data(line.utf8)).isEmpty)
        }
    }
}

@Suite("Conversation error recovery")
struct ConversationErrorRecoveryTests {
    @Test("organization-disabled Claude access offers sign-in recovery")
    func claudeOrganizationPolicy() {
        let message = "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead"
        #expect(ConversationErrorRecovery.suggested(for: message) == .providerSignIn)
    }

    @Test("expired OAuth tokens offer sign-in recovery")
    func expiredOAuthToken() {
        let message = "Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue."
        #expect(ConversationErrorRecovery.suggested(for: message) == .providerSignIn)
    }

    @Test("ordinary provider failures do not show a sign-in button")
    func unrelatedFailure() {
        #expect(ConversationErrorRecovery.suggested(for: "No output before timeout") == nil)
        #expect(ConversationErrorRecovery.suggested(for: "Rate limit exceeded; try again later") == nil)
    }
}

@Suite("Provider account setup")
struct ProviderAccountSetupTests {
    @Test("install proceeds directly into browser account login")
    func chainedInstallAndLogin() {
        let command = SubprocessProviderConfig.codexDefault.installAndAccountSetupCommand
        #expect(command?.contains("https://chatgpt.com/codex/install.sh") == true)
        #expect(command?.contains("'codex' 'login'") == true)
        #expect(command?.contains("hash -r") == true)
    }

    @Test("first-run providers launch after installation")
    func firstRunSetup() {
        let command = SubprocessProviderConfig.geminiDefault.installAndAccountSetupCommand
        #expect(command?.hasSuffix("'gemini'") == true)
    }

    @Test("CLI API keys use each vendor's supported environment")
    func cliAPIKeyEnvironments() {
        let gemini = SubprocessProviderConfig.geminiDefault.apiKeyCredential
        let cursor = SubprocessProviderConfig.cursorDefault.apiKeyCredential
        let mistral = SubprocessProviderConfig.vibeDefault.apiKeyCredential
        let kimi = SubprocessProviderConfig.kimiDefault.apiKeyCredential
        let grok = SubprocessProviderConfig.grokDefault.apiKeyCredential

        #expect(gemini?.environment(apiKey: "secret")["GEMINI_API_KEY"] == "secret")
        #expect(cursor?.environment(apiKey: "secret")["CURSOR_API_KEY"] == "secret")
        #expect(mistral?.environment(apiKey: "secret")["MISTRAL_API_KEY"] == "secret")
        #expect(grok?.environment(apiKey: "secret")["XAI_API_KEY"] == "secret")
        #expect(kimi?.environment(apiKey: "secret")["KIMI_MODEL_API_KEY"] == "secret")
        #expect(kimi?.environment(apiKey: "secret")["KIMI_MODEL_NAME"] == "kimi-k2.5")
        #expect(kimi?.environment(apiKey: "secret")["KIMI_MODEL_PROVIDER_TYPE"] == "kimi")
        #expect(kimi?.environment(apiKey: "secret")["KIMI_MODEL_BASE_URL"] == "https://api.moonshot.ai/v1")
        #expect(SubprocessProviderConfig.openCodeDefault.apiKeyCredential == nil)
    }

    @Test("direct API adapters share keys with their CLI counterparts")
    func sharedAPIKeys() {
        #expect(GeminiHTTPProvider().keychainAccount == SubprocessProviderConfig.geminiDefault.apiKeyCredential?.keychainAccount)
        #expect(OpenAICompatibleProvider.mistral.keychainAccount == SubprocessProviderConfig.vibeDefault.apiKeyCredential?.keychainAccount)
        #expect(OpenAICompatibleProvider.kimi.keychainAccount == SubprocessProviderConfig.kimiDefault.apiKeyCredential?.keychainAccount)
        #expect(OpenAICompatibleProvider.xAI.keychainAccount == SubprocessProviderConfig.grokDefault.apiKeyCredential?.keychainAccount)
    }

    @Test("signed-out Gemini resolves directly to interactive account setup")
    @MainActor
    func geminiSelectionSetupRequirement() {
        let providers = ProviderRegistry()
        let requirement = providers.setupRequirement(for: .geminiCLI, force: true)

        guard case .terminal(let id, let providerName, let command) = requirement else {
            Issue.record("Gemini should use a Terminal account setup flow")
            return
        }
        #expect(id == .geminiCLI)
        #expect(providerName == "Gemini CLI")
        #expect(command.hasSuffix("'gemini'"))
    }

    @Test("Grok uses xAI's first-party installer and account login")
    func grokAccountLogin() {
        let config = SubprocessProviderConfig.grokDefault
        #expect(config.installCommand == "curl -fsSL https://x.ai/cli/install.sh | bash")
        #expect(config.accountSignInCommand() == "'grok' 'login'")
        #expect(config.installAndAccountSetupCommand?.contains(#"$HOME/.grok/bin"#) == true)
        #expect(config.installAndAccountSetupCommand?.hasSuffix("'grok' 'login'") == true)
    }

    @Test("GUI subprocess PATH includes vendor install directories")
    func providerExecutablePaths() {
        let paths = ProcessRunner.executableSearchPaths(home: "/Users/tester")
        #expect(paths.contains("/Users/tester/.grok/bin"))
        #expect(paths.contains("/Users/tester/.codex/bin"))
    }

    @Test("Terminal handoff is self-deleting and keeps failures visible")
    @MainActor
    func terminalHandoff() throws {
        let url = try TerminalLauncher.prepareCommandFile(
            command: "'grok' 'login'",
            providerName: "Grok CLI",
            providerID: .grokCLI
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let script = try String(contentsOf: url, encoding: .utf8)
        #expect(script.contains(#"rm -f -- "$0""#))
        #expect(script.contains(#"$HOME/.grok/bin"#))
        #expect(script.contains("'grok' 'login'"))
        #expect(script.contains("Setup failed (exit %d)"))
        #expect(script.contains("provider-auth/grok-cli"))
    }

    @Test("provider credential probes distinguish logged-in and missing accounts")
    func providerCredentialProbe() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "horsetoga-provider-auth-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: ".grok"),
            withIntermediateDirectories: true
        )

        #expect(ProviderAccountInfo.isSignedIn(.grokCLI, home: root.path) == false)
        try Data("{}".utf8).write(to: root.appending(path: ".grok/auth.json"))
        #expect(ProviderAccountInfo.isSignedIn(.grokCLI, home: root.path) == true)
        #expect(ProviderAccountInfo.isSignedIn(.kimiCLI, home: root.path) == false)

        let marker = ProviderAccountInfo.authMarkerURL(for: .kimiCLI, home: root.path)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: marker)
        #expect(ProviderAccountInfo.isSignedIn(.kimiCLI, home: root.path) == true)
    }

    @Test("model selection notifies provider setup after preserving the choice")
    @MainActor
    func modelSelectionRequestsSetup() {
        let providers = ProviderRegistry()
        let viewModel = ConversationViewModel(providerID: .claudeCLI)
        let picker = ModelPickerStore()
        var selectedProvider: ProviderID?
        picker.onSelection = { selectedProvider = $0 }
        picker.openProviderPicker(for: viewModel, providers: providers)
        let grokIndex = picker.choices.firstIndex { $0.providerID == .grokCLI }

        #expect(grokIndex != nil)
        picker.select(at: grokIndex)
        #expect(viewModel.providerID == .grokCLI)
        #expect(selectedProvider == .grokCLI)
        #expect(picker.visible == false)
    }

    @Test("new chats show deduplicated recent models with the latest selected")
    @MainActor
    func newChatRecentModels() {
        let suiteName = "horsetoga-model-picker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderRegistry()
        let viewModel = ConversationViewModel(providerID: .claudeCLI)
        let picker = ModelPickerStore(defaults: defaults)

        picker.openForNewChat(
            for: viewModel,
            providers: providers,
            archiveSelections: [
                RecentModelSelection(providerID: .grokCLI, model: nil),
                RecentModelSelection(providerID: .codexCLI, model: nil),
                RecentModelSelection(providerID: .grokCLI, model: nil),
                RecentModelSelection(providerID: ProviderID("removed-provider"), model: nil),
            ]
        )

        #expect(picker.showsRecentSection)
        #expect(picker.recentChoices.map(\.providerID) == [.grokCLI, .codexCLI])
        #expect(picker.choices.first?.providerID == .grokCLI)
        #expect(picker.selectionIndex == 0)
    }

    @Test("selected models become the newest recent model across launches")
    @MainActor
    func recentModelPersistence() {
        let suiteName = "horsetoga-model-picker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderRegistry()
        let firstViewModel = ConversationViewModel(providerID: .claudeCLI)
        let firstPicker = ModelPickerStore(defaults: defaults)
        firstPicker.openForNewChat(
            for: firstViewModel,
            providers: providers,
            archiveSelections: [RecentModelSelection(providerID: .grokCLI, model: nil)]
        )
        let codexIndex = firstPicker.choices.firstIndex {
            $0.providerID == .codexCLI && $0.model == nil
        }
        #expect(codexIndex != nil)
        firstPicker.select(at: codexIndex)

        let nextPicker = ModelPickerStore(defaults: defaults)
        nextPicker.openForNewChat(
            for: ConversationViewModel(providerID: .claudeCLI),
            providers: providers,
            archiveSelections: []
        )

        #expect(nextPicker.recentChoices.first?.providerID == .codexCLI)
        #expect(nextPicker.selectionIndex == 0)
    }

    @Test("Claude credential probe does not trust the CLI keychain heuristic")
    func claudeCredentialProbeUsesHorseTogaTokenOnly() {
        let signedInViaHorseToga = KeychainStore.get(account: AccountSignIn.claudeTokenAccount)?.isEmpty == false
        #expect(ProviderAccountInfo.isSignedIn(.claudeCLI) == signedInViaHorseToga)
    }

    @Test("provider status command is authoritative")
    func providerStatusCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "horsetoga-provider-status-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func fakeCodex(named name: String, output: String, exitCode: Int) throws -> SubprocessProvider {
            let executable = root.appending(path: name)
            let script = "#!/bin/sh\nprintf '%s\\n' \"\(output)\"\nexit \(exitCode)\n"
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var config = SubprocessProviderConfig.codexDefault
            config.executable = executable.path
            return SubprocessProvider(config: config)
        }

        let ready = try fakeCodex(named: "ready", output: "Logged in using ChatGPT", exitCode: 0)
        let missing = try fakeCodex(named: "missing", output: "Not logged in", exitCode: 1)
        #expect(await ProviderAccountInfo.isVerifiedSignedIn(ready) == true)
        #expect(await ProviderAccountInfo.isVerifiedSignedIn(missing) == false)
    }

    @Test("arguments are shell quoted")
    func shellQuoting() {
        var config = SubprocessProviderConfig.codexDefault
        config.loginArgs = ["team's account"]
        #expect(config.accountSignInCommand() == #"'codex' 'team'\''s account'"#)
    }
}

@Suite("ArgvTemplate")
struct ArgvTemplateTests {
    @Test func rendersSlots() {
        let args = ArgvTemplate.render(
            ["--resume", "{{session}}", "--model", "{{model}}"],
            slots: ["session": "abc", "model": "opus"]
        )
        #expect(args == ["--resume", "abc", "--model", "opus"])
    }

    @Test func dropsUnresolvedArgs() {
        let args = ArgvTemplate.render(["--print", "--resume", "{{session}}"], slots: [:])
        #expect(args == ["--print", "--resume"])
        // NOTE: dangling flag is the config author's problem; resumeArgs are only
        // used when a session exists, so this path never fires in practice.
    }
}

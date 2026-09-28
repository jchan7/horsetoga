//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

// The provider seam. Both adapters satisfy this:
//   - HTTP SSE (Anthropic/OpenAI with the user's API key): stateless, resend history
//   - Subprocess (claude / codex CLIs the user already logged into): stateful sessions
// The protocol is shaped around the HARDER case (subprocess): opaque session handles,
// mid-stream errors after partial output, tool events, working directories.

nonisolated struct ProviderID: Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    var description: String { raw }

    static let claudeCLI = ProviderID("claude-cli")
    static let codexCLI = ProviderID("codex-cli")
    static let geminiCLI = ProviderID("gemini-cli")
    static let openCodeCLI = ProviderID("opencode-cli")
    static let cursorCLI = ProviderID("cursor-cli")
    static let vibeCLI = ProviderID("vibe-cli")
    static let kimiCLI = ProviderID("kimi-cli")
    static let grokCLI = ProviderID("grok-cli")
    static let anthropicAPI = ProviderID("anthropic-api")
    static let openAIAPI = ProviderID("openai-api")
    static let xaiAPI = ProviderID("xai-api")
    static let geminiAPI = ProviderID("gemini-api")
    static let mistralAPI = ProviderID("mistral-api")
    static let kimiAPI = ProviderID("kimi-api")
    static let localLMStudio = ProviderID("local-lmstudio")
}

/// One entry in a provider's model picker. Value nil = the provider's default,
/// which for CLIs and `-latest`-style API aliases tracks the vendor's newest
/// model automatically — the app gets better as the models do.
nonisolated struct ModelOption: Codable, Sendable, Hashable {
    var label: String
    var value: String?

    init(_ label: String, _ value: String? = nil) {
        self.label = label
        self.value = value
    }
}

/// Opaque provider-owned continuation token (a CLI session id). nil for stateless HTTP.
nonisolated struct SessionHandle: Codable, Sendable, Hashable {
    let providerID: ProviderID
    let token: String
}

nonisolated struct ProviderCapabilities: Sendable {
    var isStateful = false
    var needsWorkingDirectory = false
    var emitsToolEvents = false
    var emitsUsage = true
    var supportsPersistentProcess = false
    var coldStartEstimate: Duration = .milliseconds(300)
}

nonisolated enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

nonisolated struct ChatMessage: Identifiable, Codable, Sendable, Hashable {
    var id = UUID()
    var role: ChatRole
    var text: String
}

nonisolated struct ChatRequest: Sendable {
    /// Full history. Stateful adapters may consume only the latest user turn + handle.
    var messages: [ChatMessage]
    var handle: SessionHandle?
    var system: String?
    var model: String?
    var workingDirectory: URL?
    var maxTokens: Int?

    var latestUserText: String {
        messages.last(where: { $0.role == .user })?.text ?? ""
    }
}

nonisolated struct TokenUsage: Sendable, Codable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var costUSD: Double?
}

nonisolated enum FinishReason: Sendable, Equatable {
    case completed
    case maxTokens
    case cancelled(partial: Bool)
    case error(String)
}

nonisolated enum StreamEvent: Sendable {
    case started(runID: UUID)
    /// The adapter reports the session id it created or resumed (subprocess only).
    case handleIssued(SessionHandle)
    case textDelta(String)
    case reasoningDelta(String)
    case toolUseStarted(name: String, detail: String)
    case toolUseFinished(name: String, resultText: String, isError: Bool)
    /// May arrive mid-stream (HTTP) or only in the terminal event (CLI).
    case usage(TokenUsage)
    /// Non-fatal: rate-limit warnings, stderr chatter, status changes.
    case notice(String)
    case finished(FinishReason)
}

nonisolated enum ProviderError: Error, Sendable, CustomStringConvertible {
    case notConfigured(String)
    case executableMissing(path: String)
    case executableFailed(path: String, exitCode: Int32, stderrTail: String)
    case http(status: Int, body: String)
    /// Keep the raw line: CLI schemas drift between releases and the raw bytes
    /// are the only way to debug a decode failure in the field.
    case decode(String, rawLine: String)
    case timedOut
    case cancelled
    case midStream(underlying: String, partialText: String)

    var description: String {
        switch self {
        case .notConfigured(let hint): hint
        case .executableMissing(let path): "Executable not found: \(path)"
        case .executableFailed(let path, let code, let tail):
            "\(URL(filePath: path).lastPathComponent) exited \(code)\(tail.isEmpty ? "" : ": \(tail)")"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(300))"
        case .decode(let msg, let raw): "Decode failed (\(msg)): \(raw.prefix(200))"
        case .timedOut: "No output before timeout"
        case .cancelled: "Cancelled"
        case .midStream(let underlying, _): "Stream failed: \(underlying)"
        }
    }
}

nonisolated protocol ChatProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    /// Model choices for pickers. Empty = provider default only.
    var models: [ModelOption] { get }
    /// Cheap health check: key present? binary runnable? Called before offering the
    /// provider in pickers, and mapped to actionable UI states.
    func preflight() async throws
    /// Returns synchronously so callers can render a "connecting" state on the same
    /// frame as submit. All failures flow through the stream itself.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

nonisolated extension ChatProvider {
    var models: [ModelOption] { [] }
}

/// Providers unlocked by an API key in the user's Keychain (HTTP adapters).
/// The Providers app renders key entry for anything conforming.
nonisolated protocol KeyBackedProvider {
    var keychainAccount: String { get }
    /// Placeholder shown in the key field, e.g. "sk-ant-…".
    var keyHint: String { get }
    /// Where the user creates a key.
    var keyConsoleURL: String { get }
    /// False for local servers (LM Studio, Ollama) that accept any/no bearer token,
    /// so they need no API-key card and run without one.
    var requiresKey: Bool { get }
}

extension KeyBackedProvider {
    nonisolated var requiresKey: Bool { true }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

// Direct-API adapters: bring your own key, streamed over SSE. Stateless — the
// full transcript is resent each turn (ChatRequest.messages). Model lists lean
// on vendor defaults/aliases so new SOTA models arrive as a data edit.

/// Anthropic Messages API.
nonisolated struct AnthropicHTTPProvider: ChatProvider, KeyBackedProvider {
    let id = ProviderID.anthropicAPI
    let displayName = "Anthropic API"
    let keychainAccount = "anthropic-api-key"
    let keyHint = "sk-ant-…"
    let keyConsoleURL = "https://console.anthropic.com/settings/keys"

    static let defaultModel = "claude-fable-5"

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(emitsUsage: true, coldStartEstimate: .milliseconds(600))
    }

    var models: [ModelOption] {
        [
            ModelOption("Fable 5"),
            ModelOption("Opus 5", "claude-opus-5"),
            ModelOption("Sonnet 5", "claude-sonnet-5"),
            ModelOption("Haiku 4.5", "claude-haiku-4-5-20251001"),
        ]
    }

    func preflight() async throws {
        guard let key = KeychainStore.get(account: keychainAccount), !key.isEmpty else {
            throw ProviderError.notConfigured("No API key — add one in the Providers app")
        }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = KeychainStore.get(account: keychainAccount), !key.isEmpty else {
                        throw ProviderError.notConfigured("No API key — add one in the Providers app")
                    }
                    continuation.yield(.started(runID: UUID()))

                    var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

                    var body: [String: Any] = [
                        "model": request.model ?? Self.defaultModel,
                        "max_tokens": request.maxTokens ?? 8192,
                        "stream": true,
                        "messages": request.messages
                            .filter { $0.role != .system }
                            .map { ["role": $0.role.rawValue, "content": $0.text] },
                    ]
                    if let system = request.system, !system.isEmpty {
                        body["system"] = system
                    }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await SSE.requireOK(response, bytes: bytes)

                    var usage = TokenUsage()
                    var finished = false
                    for try await line in bytes.lines {
                        guard let event = SSE.dataPayload(line) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
                              let type = json["type"] as? String
                        else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any] {
                                if let text = delta["text"] as? String {
                                    continuation.yield(.textDelta(text))
                                } else if let thinking = delta["thinking"] as? String {
                                    continuation.yield(.reasoningDelta(thinking))
                                }
                            }
                        case "message_start":
                            if let message = json["message"] as? [String: Any],
                               let u = message["usage"] as? [String: Any] {
                                usage.inputTokens = u["input_tokens"] as? Int ?? 0
                                usage.cacheReadTokens = u["cache_read_input_tokens"] as? Int ?? 0
                            }
                        case "message_delta":
                            if let u = json["usage"] as? [String: Any] {
                                usage.outputTokens = u["output_tokens"] as? Int ?? usage.outputTokens
                                continuation.yield(.usage(usage))
                            }
                        case "message_stop":
                            finished = true
                            continuation.yield(.finished(.completed))
                        case "error":
                            let message = (json["error"] as? [String: Any])?["message"] as? String ?? event
                            throw ProviderError.midStream(underlying: message, partialText: "")
                        default:
                            break
                        }
                    }
                    if !finished { continuation.yield(.finished(.completed)) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ProviderError.midStream(underlying: "\(error)", partialText: ""))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Google Gemini generateContent API. This direct route needs no local Gemini
/// CLI, so an AI Studio key works on a clean Mac immediately.
nonisolated struct GeminiHTTPProvider: ChatProvider, KeyBackedProvider {
    let id = ProviderID.geminiAPI
    let displayName = "Google Gemini API"
    let keychainAccount = "gemini-api-key"
    let keyHint = "AI Studio API key"
    let keyConsoleURL = "https://aistudio.google.com/apikey"

    static let defaultModel = "gemini-2.5-flash"

    var models: [ModelOption] {
        [
            ModelOption("Gemini 2.5 Flash"),
            ModelOption("Gemini 2.5 Pro", "gemini-2.5-pro"),
        ]
    }

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(emitsUsage: true, coldStartEstimate: .milliseconds(600))
    }

    func preflight() async throws {
        guard let key = KeychainStore.get(account: keychainAccount), !key.isEmpty else {
            throw ProviderError.notConfigured("No API key — add one in the Providers app")
        }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = KeychainStore.get(account: keychainAccount), !key.isEmpty else {
                        throw ProviderError.notConfigured("No API key — add one in the Providers app")
                    }
                    continuation.yield(.started(runID: UUID()))

                    let model = request.model ?? Self.defaultModel
                    var components = URLComponents(
                        string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent"
                    )!
                    components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
                    var urlRequest = URLRequest(url: components.url!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

                    var body: [String: Any] = [
                        "contents": request.messages
                            .filter { $0.role != .system }
                            .map { message in
                                [
                                    "role": message.role == .assistant ? "model" : "user",
                                    "parts": [["text": message.text]],
                                ] as [String: Any]
                            },
                        "generationConfig": ["maxOutputTokens": request.maxTokens ?? 8192],
                    ]
                    if let system = request.system, !system.isEmpty {
                        body["systemInstruction"] = ["parts": [["text": system]]]
                    }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await SSE.requireOK(response, bytes: bytes)
                    for try await line in bytes.lines {
                        guard let event = SSE.dataPayload(line),
                              let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any]
                        else { continue }
                        if let candidates = json["candidates"] as? [[String: Any]],
                           let content = candidates.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]] {
                            for text in parts.compactMap({ $0["text"] as? String }) where !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            }
                        }
                        if let metadata = json["usageMetadata"] as? [String: Any] {
                            continuation.yield(.usage(TokenUsage(
                                inputTokens: metadata["promptTokenCount"] as? Int ?? 0,
                                outputTokens: metadata["candidatesTokenCount"] as? Int ?? 0,
                                cacheReadTokens: metadata["cachedContentTokenCount"] as? Int ?? 0
                            )))
                        }
                    }
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ProviderError.midStream(underlying: "\(error)", partialText: ""))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Any OpenAI-compatible chat/completions endpoint: OpenAI itself, xAI, and
/// most self-hosted/open-model servers speak this dialect.
nonisolated struct OpenAICompatibleProvider: ChatProvider, KeyBackedProvider {
    let id: ProviderID
    let displayName: String
    let baseURL: String
    let defaultModel: String
    let keychainAccount: String
    let keyHint: String
    let keyConsoleURL: String
    let models: [ModelOption]
    /// Local servers (LM Studio, Ollama, llama.cpp) accept any/no bearer token and
    /// run keyless. Cloud APIs leave this true.
    var requiresKey: Bool = true
    /// Sent as `reasoning_effort` when set. Small local reasoning models can think
    /// for minutes before answering, and chat tiles show answer text only, so the
    /// local provider defaults to answer-first ("none").
    var reasoningEffort: String? = nil

    static let openAI = OpenAICompatibleProvider(
        id: .openAIAPI,
        displayName: "OpenAI API",
        baseURL: "https://api.openai.com/v1",
        defaultModel: "gpt-5.1",
        keychainAccount: "openai-api-key",
        keyHint: "sk-…",
        keyConsoleURL: "https://platform.openai.com/api-keys",
        models: [
            ModelOption("GPT-5.1"),
            ModelOption("GPT-4.1", "gpt-4.1"),
            ModelOption("o4-mini", "o4-mini"),
        ]
    )

    static let xAI = OpenAICompatibleProvider(
        id: .xaiAPI,
        displayName: "xAI Grok",
        baseURL: "https://api.x.ai/v1",
        defaultModel: "grok-4",
        keychainAccount: "xai-api-key",
        keyHint: "xai-…",
        keyConsoleURL: "https://console.x.ai",
        models: [ModelOption("Grok 4")]
    )

    static let mistral = OpenAICompatibleProvider(
        id: .mistralAPI,
        displayName: "Mistral API",
        baseURL: "https://api.mistral.ai/v1",
        defaultModel: "devstral-latest",
        keychainAccount: "mistral-api-key",
        keyHint: "Mistral API key",
        keyConsoleURL: "https://console.mistral.ai",
        models: [
            ModelOption("Devstral Latest"),
            ModelOption("Mistral Large Latest", "mistral-large-latest"),
            ModelOption("Codestral Latest", "codestral-latest"),
        ]
    )

    static let kimi = OpenAICompatibleProvider(
        id: .kimiAPI,
        displayName: "Kimi Platform API",
        baseURL: "https://api.moonshot.ai/v1",
        defaultModel: "kimi-k2.5",
        keychainAccount: "kimi-api-key",
        keyHint: "Kimi Platform API key",
        keyConsoleURL: "https://platform.moonshot.ai/console/api-keys",
        models: [ModelOption("Kimi K2.5")]
    )

    /// A local model served by LM Studio's OpenAI-compatible server — no API key,
    /// plain HTTP to localhost (allowed via NSAllowsLocalNetworking in Info.plist).
    /// Start it with `lms server start` and load a model; edit the model id/list to
    /// match whatever you've loaded.
    static let localLMStudio = OpenAICompatibleProvider(
        id: .localLMStudio,
        displayName: "Local (LM Studio)",
        baseURL: "http://localhost:1234/v1",
        defaultModel: "qwen/qwen3.5-9b",
        keychainAccount: "local-lmstudio-key",
        keyHint: "not needed for a local server",
        keyConsoleURL: "https://lmstudio.ai",
        models: [ModelOption("Qwen3.5 9B", "qwen/qwen3.5-9b")],
        requiresKey: false,
        reasoningEffort: "none"
    )

    var capabilities: ProviderCapabilities {
        ProviderCapabilities(emitsUsage: false, coldStartEstimate: .milliseconds(600))
    }

    func preflight() async throws {
        guard requiresKey else { return }
        guard let key = KeychainStore.get(account: keychainAccount), !key.isEmpty else {
            throw ProviderError.notConfigured("No API key — add one in the Providers app")
        }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key: String
                    if requiresKey {
                        guard let stored = KeychainStore.get(account: keychainAccount), !stored.isEmpty else {
                            throw ProviderError.notConfigured("No API key — add one in the Providers app")
                        }
                        key = stored
                    } else {
                        // Local servers ignore the bearer token.
                        key = KeychainStore.get(account: keychainAccount) ?? "local"
                    }
                    continuation.yield(.started(runID: UUID()))

                    var urlRequest = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

                    var messages: [[String: String]] = []
                    if let system = request.system, !system.isEmpty {
                        messages.append(["role": "system", "content": system])
                    }
                    messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
                    var body: [String: Any] = [
                        "model": request.model ?? defaultModel,
                        "stream": true,
                        "messages": messages,
                    ]
                    if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await SSE.requireOK(response, bytes: bytes)

                    for try await line in bytes.lines {
                        guard let event = SSE.dataPayload(line) else { continue }
                        if event == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }
                        if let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                            continuation.yield(.reasoningDelta(reasoning))
                        }
                    }
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ProviderError.midStream(underlying: "\(error)", partialText: ""))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Shared SSE plumbing.
private nonisolated enum SSE {
    /// Strips the "data:" prefix; nil for comments, event names, blank lines.
    static func dataPayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    /// Non-200: drain the body (it's the error message) and throw.
    static func requireOK(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count > 2000 { break }
        }
        throw ProviderError.http(status: http.statusCode, body: body)
    }
}

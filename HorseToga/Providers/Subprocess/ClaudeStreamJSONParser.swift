//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Parses `claude --print --output-format stream-json --include-partial-messages --verbose`.
///
/// Envelope kinds observed against claude 2.1.185 (fixture: claude-auth-error.jsonl):
///   {"type":"system","subtype":"init","session_id":...}         -> handleIssued
///   {"type":"system","subtype":"status","status":"requesting"}   -> ignored
///   {"type":"stream_event","event":{<anthropic SSE event>}}      -> deltas
///   {"type":"assistant","message":{...},"error":...}             -> full message (dedupe vs deltas)
///   {"type":"user","message":{content:[tool_result...]}}         -> tool results
///   {"type":"result","is_error":...,"usage":...,"total_cost_usd"} -> terminal
nonisolated final class ClaudeStreamJSONParser: SubprocessOutputParser {
    private let providerID: ProviderID
    private(set) var sawTerminal = false
    /// Deltas already streamed for the in-flight assistant message; the complete
    /// "assistant" envelope then duplicates that text and must be skipped.
    private var streamedTextThisMessage = false
    private var startedToolIDs: Set<String> = []

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    func parse(line: Data) -> [StreamEvent] {
        guard let obj = JSONLine.object(from: line), let type = obj["type"] as? String else {
            return [] // non-JSON chatter on stdout: ignore
        }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init",
                  let sessionID = obj["session_id"] as? String else { return [] }
            return [.handleIssued(SessionHandle(providerID: providerID, token: sessionID))]

        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return [] }
            return parseAnthropicEvent(event)

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return [] }
            var events: [StreamEvent] = []
            if let error = obj["error"] as? String {
                events.append(.notice("claude: \(error)"))
            }
            for block in (message["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "text":
                    if !streamedTextThisMessage, let text = block["text"] as? String, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    if !startedToolIDs.contains(id) {
                        startedToolIDs.insert(id)
                        let name = block["name"] as? String ?? "tool"
                        events.append(.toolUseStarted(name: name, detail: compactJSON(block["input"])))
                    }
                default:
                    break
                }
            }
            streamedTextThisMessage = false // message boundary
            return events

        case "user":
            guard let message = obj["message"] as? [String: Any] else { return [] }
            var events: [StreamEvent] = []
            for block in (message["content"] as? [[String: Any]]) ?? [] {
                guard block["type"] as? String == "tool_result" else { continue }
                let isError = block["is_error"] as? Bool ?? false
                events.append(.toolUseFinished(
                    name: "tool",
                    resultText: toolResultText(block["content"]),
                    isError: isError
                ))
            }
            return events

        case "result":
            sawTerminal = true
            var events: [StreamEvent] = []
            if let usage = obj["usage"] as? [String: Any] {
                var tokens = TokenUsage(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0
                )
                tokens.costUSD = obj["total_cost_usd"] as? Double
                events.append(.usage(tokens))
            }
            if let sessionID = obj["session_id"] as? String {
                events.append(.handleIssued(SessionHandle(providerID: providerID, token: sessionID)))
            }
            if obj["is_error"] as? Bool == true {
                events.append(.finished(.error(obj["result"] as? String ?? "unknown error")))
            } else {
                events.append(.finished(.completed))
            }
            return events

        default:
            return []
        }
    }

    private func parseAnthropicEvent(_ event: [String: Any]) -> [StreamEvent] {
        switch event["type"] as? String {
        case "message_start":
            streamedTextThisMessage = false
            return []
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use" else { return [] }
            let id = block["id"] as? String ?? UUID().uuidString
            startedToolIDs.insert(id)
            return [.toolUseStarted(
                name: block["name"] as? String ?? "tool",
                detail: ""
            )]
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                streamedTextThisMessage = true
                return [.textDelta(text)]
            case "thinking_delta":
                guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                return [.reasoningDelta(text)]
            default:
                return []
            }
        default:
            return []
        }
    }

    private func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private func compactJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(300))
    }
}

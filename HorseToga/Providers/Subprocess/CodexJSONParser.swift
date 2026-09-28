//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Parses `codex exec --json` output. Codex has shipped two envelope families;
/// this handles both defensively (the codex install on this machine is currently
/// broken, so this is written to the documented schemas and will be re-verified
/// against a live binary — the config seam means fixes are config/parser-local).
///
/// Family A (current): {"type":"thread.started","thread_id":...}
///                     {"type":"item.completed","item":{"item_type":"agent_message","text":...}}
///                     {"type":"turn.completed","usage":{...}}
/// Family B (legacy):  {"id":...,"msg":{"type":"agent_message_delta","delta":...}}
///                     {"id":...,"msg":{"type":"task_complete"}}
nonisolated final class CodexJSONParser: SubprocessOutputParser {
    private let providerID: ProviderID
    private(set) var sawTerminal = false
    private var streamedDelta = false

    init(providerID: ProviderID) {
        self.providerID = providerID
    }

    func parse(line: Data) -> [StreamEvent] {
        guard let obj = JSONLine.object(from: line) else { return [] }
        if let msg = obj["msg"] as? [String: Any] { return parseLegacy(msg) }
        guard let type = obj["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            guard let threadID = obj["thread_id"] as? String else { return [] }
            return [.handleIssued(SessionHandle(providerID: providerID, token: threadID))]

        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            let itemType = (item["item_type"] as? String) ?? (item["type"] as? String) ?? ""
            switch itemType {
            case "agent_message":
                guard type == "item.completed", !streamedDelta,
                      let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.textDelta(text)]
            case "command_execution":
                let command = item["command"] as? String ?? ""
                if type == "item.started" {
                    return [.toolUseStarted(name: "shell", detail: String(command.prefix(200)))]
                }
                if type == "item.completed" {
                    let output = item["aggregated_output"] as? String ?? ""
                    let exit = item["exit_code"] as? Int ?? 0
                    return [.toolUseFinished(name: "shell", resultText: String(output.suffix(500)), isError: exit != 0)]
                }
                return []
            case "reasoning":
                guard type == "item.completed", let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.reasoningDelta(text)]
            default:
                return []
            }

        case "turn.completed":
            sawTerminal = true
            var events: [StreamEvent] = []
            if let usage = obj["usage"] as? [String: Any] {
                events.append(.usage(TokenUsage(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    cacheReadTokens: usage["cached_input_tokens"] as? Int ?? 0
                )))
            }
            events.append(.finished(.completed))
            return events

        case "turn.failed", "error":
            sawTerminal = true
            let message = (obj["error"] as? [String: Any])?["message"] as? String
                ?? obj["message"] as? String ?? "codex error"
            return [.finished(.error(message))]

        default:
            return []
        }
    }

    private func parseLegacy(_ msg: [String: Any]) -> [StreamEvent] {
        switch msg["type"] as? String {
        case "session_configured":
            guard let sessionID = msg["session_id"] as? String else { return [] }
            return [.handleIssued(SessionHandle(providerID: providerID, token: sessionID))]
        case "agent_message_delta":
            guard let delta = msg["delta"] as? String, !delta.isEmpty else { return [] }
            streamedDelta = true
            return [.textDelta(delta)]
        case "agent_message":
            guard !streamedDelta, let text = msg["message"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "agent_reasoning_delta":
            guard let delta = msg["delta"] as? String, !delta.isEmpty else { return [] }
            return [.reasoningDelta(delta)]
        case "exec_command_begin":
            let command = (msg["command"] as? [String])?.joined(separator: " ") ?? ""
            return [.toolUseStarted(name: "shell", detail: String(command.prefix(200)))]
        case "exec_command_end":
            let output = msg["formatted_output"] as? String ?? msg["stdout"] as? String ?? ""
            let exit = msg["exit_code"] as? Int ?? 0
            return [.toolUseFinished(name: "shell", resultText: String(output.suffix(500)), isError: exit != 0)]
        case "token_count":
            guard let info = msg["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return [] }
            return [.usage(TokenUsage(
                inputTokens: total["input_tokens"] as? Int ?? 0,
                outputTokens: total["output_tokens"] as? Int ?? 0,
                cacheReadTokens: total["cached_input_tokens"] as? Int ?? 0
            ))]
        case "task_complete":
            sawTerminal = true
            return [.finished(.completed)]
        case "error":
            sawTerminal = true
            return [.finished(.error(msg["message"] as? String ?? "codex error"))]
        default:
            return []
        }
    }
}

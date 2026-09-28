//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// One instance per run; owned by a single task, so mutable state needs no locking.
/// Implementations must be tolerant: unknown event types are IGNORED, never fatal —
/// CLI schemas drift between releases and a new event kind must not break streaming.
nonisolated protocol SubprocessOutputParser: AnyObject {
    /// True once a terminal event (result / turn end) was parsed. If the process
    /// exits without one, the provider synthesizes success/failure from the exit code.
    var sawTerminal: Bool { get }
    func parse(line: Data) -> [StreamEvent]
}

/// The universal fallback: every stdout line is a text delta. Any CLI agent
/// with a non-interactive "print the answer" mode streams through this with
/// zero format knowledge — which is what makes new agents a config edit.
nonisolated final class PlainTextParser: SubprocessOutputParser {
    private(set) var sawTerminal = false

    func parse(line: Data) -> [StreamEvent] {
        let raw = String(decoding: line, as: UTF8.self)
        let text = raw.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
        return [.textDelta(text + "\n")]
    }
}

/// Shared JSON plumbing for the line-oriented parsers.
nonisolated enum JSONLine {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation

nonisolated struct ConversationID: Hashable, Codable, Sendable {
    let raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

enum RunStatus: Equatable {
    case idle
    case connecting
    case streaming
    case runningTool(String)
    case failed(String)
}

nonisolated struct TranscriptEntry: Identifiable, Equatable, Codable, Sendable {
    nonisolated enum Kind: Equatable, Codable, Sendable {
        case user(String)
        case assistant(String)
        case reasoning(String)
        case tool(name: String, detail: String, result: String?, isError: Bool)
        case notice(String)
        case error(String)
    }

    var id = UUID()
    var kind: Kind
}

/// Recovery actions that can be inferred from provider error text. Provider
/// CLIs do not share an error schema, so this deliberately recognizes the
/// small set of authentication phrases they emit in practice.
nonisolated enum ConversationErrorRecovery: Equatable, Sendable {
    case providerSignIn

    static func suggested(for message: String) -> Self? {
        let normalized = message
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        let authenticationMarkers = [
            "failed to authenticate",
            "authentication failed",
            "authentication required",
            "not authenticated",
            "not logged in",
            "login required",
            "log in to continue",
            "sign in to continue",
            "re authenticate",
            "oauth",
            "access token has expired",
            "token expired",
            "unauthorized",
            "invalid api key",
            "no api key",
            "api key required",
            "auth org not allowed",
            "subscription access for claude code",
        ]

        if authenticationMarkers.contains(where: normalized.contains) {
            return .providerSignIn
        }
        return nil
    }
}

/// The single source of truth a conversation renders from. The panel and any
/// workspace tile bind to the SAME instance, which is what makes panel -> tile
/// handoff free: the stream never learns the view changed.
@MainActor
@Observable
final class ConversationViewModel: Identifiable {
    let id: ConversationID
    var title: String
    var providerID: ProviderID
    var model: String?
    var handle: SessionHandle?
    var workingDirectory: URL?
    let createdAt: Date

    var entries: [TranscriptEntry] = []
    /// Streaming assistant text, promoted into `entries` when the run finishes.
    var liveText = ""
    var liveReasoning = ""
    var status: RunStatus = .idle
    var usage: TokenUsage?

    init(
        id: ConversationID = ConversationID(),
        title: String = "New Session",
        providerID: ProviderID,
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.providerID = providerID
        self.model = model
        self.createdAt = createdAt
        // Give CLIs a real, writable cwd instead of a Finder-launched app's "/",
        // so files they create (and the relative paths they print) actually land
        // somewhere — and resolve when the transcript renders them.
        self.workingDirectory = URL(filePath: NSHomeDirectory())
    }

    var isRunning: Bool {
        switch status {
        case .connecting, .streaming, .runningTool: true
        case .idle, .failed: false
        }
    }

    var hasContent: Bool {
        !entries.isEmpty || !liveText.isEmpty || status != .idle
    }
}

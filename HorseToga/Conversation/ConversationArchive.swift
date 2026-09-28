//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation

/// A conversation as it lives on disk: the whole transcript plus everything
/// needed to pick it back up (provider, model, CLI session handle, cwd).
nonisolated struct ConversationRecord: Codable, Identifiable, Sendable, Equatable {
    var id: ConversationID
    var title: String
    var providerID: ProviderID
    var model: String?
    var handle: SessionHandle?
    var workingDirectory: URL?
    var createdAt: Date
    var updatedAt: Date
    var entries: [TranscriptEntry]
    var usage: TokenUsage?

    var messageCount: Int {
        entries.filter {
            switch $0.kind {
            case .user, .assistant: true
            default: false
            }
        }.count
    }

    /// Last thing said, for list rows.
    var preview: String {
        for entry in entries.reversed() {
            switch entry.kind {
            case .assistant(let text), .user(let text):
                if !text.isEmpty { return text }
            default:
                continue
            }
        }
        return ""
    }

    func matches(_ query: String) -> Bool {
        if title.lowercased().contains(query) { return true }
        return entries.contains {
            switch $0.kind {
            case .user(let text), .assistant(let text): text.lowercased().contains(query)
            default: false
            }
        }
    }

    /// Rehydrate into a live view model; a fresh runner around it resumes the
    /// conversation (stateful CLIs via the handle, HTTP providers via entries).
    @MainActor
    func makeViewModel() -> ConversationViewModel {
        let vm = ConversationViewModel(id: id, title: title, providerID: providerID, model: model, createdAt: createdAt)
        vm.handle = handle
        vm.workingDirectory = workingDirectory
        vm.entries = entries
        vm.usage = usage
        return vm
    }
}

/// Every conversation that ever said anything, one JSON file each under
/// Application Support. Snapshots are taken by ConversationRunner as runs
/// finish, by WorkspaceStore when a tile closes, and at quit — so history is
/// a byproduct of using the app, never something you remember to save.
@MainActor
@Observable
final class ConversationArchive {
    /// Newest first.
    private(set) var records: [ConversationRecord] = []
    private var pendingWrites: [ConversationID: Task<Void, Never>] = [:]

    nonisolated static var directory: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/com.jasonchan.horsetoga/Conversations")
    }

    func load() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        records = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConversationRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ConversationRecord.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Snapshot a live conversation. Sessions nobody has spoken to yet aren't
    /// history, so they're skipped — an empty ⌘↩ tile leaves no trace.
    func save(_ vm: ConversationViewModel) {
        let hasUserMessage = vm.entries.contains {
            if case .user = $0.kind { return true } else { return false }
        }
        guard hasUserMessage else { return }
        let existing = records.first { $0.id == vm.id }
        let record = ConversationRecord(
            id: vm.id,
            title: vm.title,
            providerID: vm.providerID,
            model: vm.model,
            handle: vm.handle,
            workingDirectory: vm.workingDirectory,
            createdAt: existing?.createdAt ?? vm.createdAt,
            updatedAt: Date(),
            entries: vm.entries,
            usage: vm.usage
        )
        records.removeAll { $0.id == vm.id }
        records.insert(record, at: 0)
        scheduleWrite(record)
    }

    func delete(_ id: ConversationID) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.fileURL(for: id))
    }

    /// Records visible for a search query, in display order (newest first).
    /// One source of truth so the History list and its keyboard navigation
    /// can never disagree on ordering.
    func matching(_ query: String) -> [ConversationRecord] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter { $0.matches(query) }
    }

    /// Synchronous write of anything still coalescing — call before quit.
    func flush() {
        let ids = Array(pendingWrites.keys)
        for id in ids {
            pendingWrites[id]?.cancel()
            pendingWrites[id] = nil
            if let record = records.first(where: { $0.id == id }) {
                Self.write(record)
            }
        }
    }

    // MARK: - Disk

    private nonisolated static func fileURL(for id: ConversationID) -> URL {
        directory.appending(path: "\(id.raw.uuidString).json")
    }

    /// Writes coalesce over a short window so a streaming run doesn't thrash disk.
    private func scheduleWrite(_ record: ConversationRecord) {
        pendingWrites[record.id]?.cancel()
        pendingWrites[record.id] = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(record)
        }
    }

    private nonisolated static func write(_ record: ConversationRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL(for: record.id), options: .atomic)
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Owns one conversation's active run: consumes the provider stream off-view and
/// applies events to the view model. Views come and go; this object doesn't care.
@MainActor
final class ConversationRunner {
    /// Archive hook installed by AppServices; nil in tests. Called whenever the
    /// conversation reaches a stable point worth remembering.
    static var persist: ((ConversationViewModel) -> Void)?

    let viewModel: ConversationViewModel
    private var task: Task<Void, Never>?

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
    }

    func send(_ text: String, via provider: any ChatProvider) {
        guard !viewModel.isRunning else { return }
        let vm = viewModel
        vm.entries.append(TranscriptEntry(kind: .user(text)))
        if vm.title == "New Session" {
            vm.title = String(text.prefix(48))
        }
        vm.liveText = ""
        vm.liveReasoning = ""
        vm.status = .connecting
        Self.persist?(vm)

        let request = ChatRequest(
            messages: transcriptAsMessages() + [ChatMessage(role: .user, text: text)],
            handle: vm.handle,
            model: vm.model,
            workingDirectory: vm.workingDirectory
        )

        task = Task {
            do {
                for try await event in provider.stream(request) {
                    apply(event)
                }
                commitLiveText()
                if vm.status != .idle, case .failed = vm.status {} else { vm.status = .idle }
            } catch let error as ProviderError {
                commitLiveText()
                if case .cancelled = error {
                    vm.entries.append(TranscriptEntry(kind: .notice("cancelled")))
                    vm.status = .idle
                } else {
                    vm.entries.append(TranscriptEntry(kind: .error(error.description)))
                    vm.status = .failed(error.description)
                }
            } catch {
                commitLiveText()
                vm.entries.append(TranscriptEntry(kind: .error("\(error)")))
                vm.status = .failed("\(error)")
            }
            task = nil
            Self.persist?(vm)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func apply(_ event: StreamEvent) {
        let vm = viewModel
        switch event {
        case .started:
            vm.status = .connecting
        case .handleIssued(let handle):
            vm.handle = handle
        case .textDelta(let text):
            vm.liveText += text
            vm.status = .streaming
        case .reasoningDelta(let text):
            vm.liveReasoning += text
            if vm.status == .connecting { vm.status = .streaming }
        case .toolUseStarted(let name, let detail):
            // Text so far stays in place; tool call renders between text chunks.
            commitLiveText()
            vm.entries.append(TranscriptEntry(kind: .tool(name: name, detail: detail, result: nil, isError: false)))
            vm.status = .runningTool(name)
        case .toolUseFinished(let name, let result, let isError):
            if let index = vm.entries.lastIndex(where: {
                if case .tool(_, _, nil, _) = $0.kind { return true } else { return false }
            }), case .tool(let openName, let detail, nil, _) = vm.entries[index].kind {
                vm.entries[index].kind = .tool(
                    name: openName.isEmpty ? name : openName,
                    detail: detail,
                    result: result,
                    isError: isError
                )
            }
            vm.status = .streaming
        case .usage(let usage):
            vm.usage = usage
        case .notice(let text):
            vm.entries.append(TranscriptEntry(kind: .notice(text)))
        case .finished(let reason):
            commitLiveText()
            switch reason {
            case .completed:
                vm.status = .idle
            case .maxTokens:
                vm.entries.append(TranscriptEntry(kind: .notice("hit max tokens")))
                vm.status = .idle
            case .cancelled:
                vm.entries.append(TranscriptEntry(kind: .notice("cancelled")))
                vm.status = .idle
            case .error(let message):
                vm.entries.append(TranscriptEntry(kind: .error(message)))
                vm.status = .failed(message)
            }
        }
    }

    private func commitLiveText() {
        let vm = viewModel
        if !vm.liveReasoning.isEmpty {
            vm.entries.append(TranscriptEntry(kind: .reasoning(vm.liveReasoning)))
            vm.liveReasoning = ""
        }
        if !vm.liveText.isEmpty {
            vm.entries.append(TranscriptEntry(kind: .assistant(vm.liveText)))
            vm.liveText = ""
        }
    }

    /// History for stateless (HTTP) providers; stateful CLIs use the handle instead.
    private func transcriptAsMessages() -> [ChatMessage] {
        viewModel.entries.compactMap { entry in
            switch entry.kind {
            case .user(let text): ChatMessage(role: .user, text: text)
            case .assistant(let text): ChatMessage(role: .assistant, text: text)
            default: nil
            }
        }
    }
}

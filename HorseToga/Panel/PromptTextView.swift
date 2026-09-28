//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Focus bridge: the SwiftUI-hosted NSTextView registers itself here so
/// PanelController can make it first responder at summon time (no @FocusState races).
@MainActor
final class PanelFocus {
    weak var textView: NSTextView?
}

/// The prompt field. A hand-rolled NSTextView because the panel needs exact keyboard
/// semantics SwiftUI's TextField can't provide: Enter=submit, Shift-Enter=newline,
/// Escape=dismiss, ↑/↓ list navigation, and IME safety (never submit mid-composition).
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 20, weight: .regular)
    var textColor: NSColor = .labelColor
    var focus: PanelFocus?
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMoveUp: () -> Bool = { false }   // return true if consumed (list navigation)
    var onMoveDown: () -> Bool = { false }
    var onExpand: () -> Void = {}          // ⌘↩: expand into the workspace
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> KeyInterceptingTextView {
        let view = KeyInterceptingTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = .zero
        view.font = font
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.delegate = context.coordinator
        view.onSubmit = { context.coordinator.parent.onSubmit() }
        view.onCancel = { context.coordinator.parent.onCancel() }
        view.onMoveUp = { context.coordinator.parent.onMoveUp() }
        view.onMoveDown = { context.coordinator.parent.onMoveDown() }
        view.onExpand = { context.coordinator.parent.onExpand() }
        view.onHeightChange = { context.coordinator.parent.onHeightChange($0) }
        focus?.textView = view
        return view
    }

    func updateNSView(_ view: KeyInterceptingTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
        }
        view.font = font
        view.textColor = textColor
        view.insertionPointColor = textColor
        focus?.textView = view
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        init(parent: PromptTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class KeyInterceptingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveUp: (() -> Bool)?
    var onMoveDown: (() -> Bool)?
    var onExpand: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    override func didChangeText() {
        super.didChangeText()
        reportHeight()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportHeight()
    }

    private func reportHeight() {
        // TextKit 2: measure used height without tripping the TextKit 1 downgrade
        // that touching `.layoutManager` causes.
        guard let tlm = textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let height = tlm.usageBoundsForTextContainer.height
        if height > 0 { onHeightChange?(ceil(height)) }
    }

    /// Push-to-talk dictation: hold fn + Shift to speak, release to stop. Handled
    /// here (not via the window keymap) so it only fires while a chat composer has
    /// focus, and inserts straight into this field.
    override func flagsChanged(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.function) && mods.contains(.shift) {
            DictationController.shared.start(into: self)
        } else {
            DictationController.shared.stopIfRecording(from: self)
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        DictationController.shared.stopIfRecording(from: self)
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            // hasMarkedText = IME composition in flight; Enter then commits the
            // composition and must never submit.
            if !hasMarkedText() {
                if mods == .command {
                    onExpand?()
                    return
                }
                if !mods.contains(.shift) {
                    onSubmit?()
                    return
                }
            }
        case 53: // Escape
            if !hasMarkedText() {
                onCancel?()
                return
            }
        case 126: // Up
            if !hasMarkedText(), mods.isEmpty, onMoveUp?() == true { return }
        case 125: // Down
            if !hasMarkedText(), mods.isEmpty, onMoveDown?() == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - Push-to-talk dictation (hold fn + Shift)

/// Observable flag the composers watch to show the "Listening…" indicator, plus a
/// transient note used to surface a permission problem the one time it happens.
@MainActor
@Observable
final class DictationState {
    static let shared = DictationState()
    var isRecording = false
    var note: String?
    private init() {}
}

/// Live speech-to-text into the focused NSTextView. One shared engine — only one
/// field is ever first responder — driven by `KeyInterceptingTextView.flagsChanged`.
@MainActor
final class DictationController {
    static let shared = DictationController()

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private weak var target: NSTextView?
    private var base = 0        // UTF-16 offset where this utterance began
    private var span = 0        // UTF-16 length of the text inserted so far
    private var prefix = ""     // a leading space when joining onto existing text
    private var generation = 0  // guards against a quick press/release racing async auth
    private var noteToken = 0

    private init() {}

    func start(into textView: NSTextView) {
        guard !DictationState.shared.isRecording else { return }
        DictationState.shared.isRecording = true
        DictationState.shared.note = nil
        target = textView
        base = min(textView.selectedRange().location, (textView.string as NSString).length)
        span = 0
        let ns = textView.string as NSString
        let priorChar = base > 0 ? ns.substring(with: NSRange(location: base - 1, length: 1)) : " "
        prefix = (priorChar.first?.isWhitespace == false) ? " " : ""
        generation &+= 1
        let gen = generation
        authorize { [weak self] granted, message in
            guard let self else { return }
            guard granted, gen == self.generation, DictationState.shared.isRecording else {
                if !granted { self.flash(message) }
                DictationState.shared.isRecording = false
                self.teardown()
                return
            }
            self.beginCapture(gen: gen)
        }
    }

    func stopIfRecording(from textView: NSTextView) {
        guard DictationState.shared.isRecording, target === textView else { return }
        stop()
    }

    func stop() {
        guard DictationState.shared.isRecording else { return }
        DictationState.shared.isRecording = false
        generation &+= 1
        teardown()
    }

    // MARK: authorization

    private func authorize(_ done: @escaping @MainActor (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    done(false, "Turn on Speech Recognition for HorseToga in System Settings ▸ Privacy & Security.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                    Task { @MainActor in
                        done(micGranted, micGranted ? nil : "Turn on Microphone access for HorseToga in System Settings ▸ Privacy & Security.")
                    }
                }
            }
        }
    }

    // MARK: capture

    private func beginCapture(gen: Int) {
        guard let recognizer, recognizer.isAvailable else {
            flash("Speech recognition isn't available right now.")
            DictationState.shared.isRecording = false
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            flash("Couldn't start the microphone.")
            DictationState.shared.isRecording = false
            teardown()
            return
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.apply(text, gen: gen) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in if gen == self.generation { self.stop() } }
            }
        }
    }

    /// Replace the growing dictation span with the latest transcription, so partial
    /// results update live in place rather than appending duplicates.
    private func apply(_ transcript: String, gen: Int) {
        guard gen == generation, let tv = target else { return }
        let full = prefix + transcript
        let ns = tv.string as NSString
        let safeBase = min(base, ns.length)
        let range = NSRange(location: safeBase, length: min(span, ns.length - safeBase))
        guard tv.shouldChangeText(in: range, replacementString: full) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: full)
        tv.didChangeText()
        span = (full as NSString).length
        tv.setSelectedRange(NSRange(location: safeBase + span, length: 0))
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func flash(_ message: String?) {
        guard let message else { return }
        DictationState.shared.note = message
        noteToken &+= 1
        let token = noteToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if self.noteToken == token { DictationState.shared.note = nil }
        }
    }
}

/// The "Listening…" pill shown over a composer while dictation is active.
struct DictationPill: View {
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.95, green: 0.30, blue: 0.30))
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
            Text("Listening… fn⇧")
                .font(theme.font(10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.surface.opacity(0.92)))
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: theme.borderWidth))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// A transient note (e.g. a permission hint) shown where the pill would be.
struct DictationNoteView: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(theme.font(10))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(3)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 300, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface.opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: theme.borderWidth))
    }
}

//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`: consumes the keystroke system-wide
/// and needs zero TCC permission (unlike event taps). Handler installed exactly once;
/// registrations come and go per binding.
@MainActor
final class CarbonHotKeyCenter {
    nonisolated static let signature: OSType = 0x534C_4154 // 'SLAT'

    private struct Registration {
        let combo: KeyCombo
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    enum HotKeyError: Error, CustomStringConvertible {
        case registrationFailed(OSStatus)
        var description: String {
            switch self {
            case .registrationFailed(let status):
                // -9878 = already taken by another app, the common collision case
                return "Couldn't register hotkey (OSStatus \(status)). Another app may own this chord."
            }
        }
    }

    /// Registers `combo` globally. Returns a token used to unregister (e.g. on rebind).
    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) throws -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { throw HotKeyError.registrationFailed(status) }
        registrations[id] = Registration(combo: combo, ref: ref, action: action)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let reg = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reg.ref)
    }

    /// Hotkeys are silently suppressed while any app holds secure input (password fields).
    /// Surface this in the UI when a summon appears to fail.
    nonisolated static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    fileprivate func fire(id: UInt32) {
        registrations[id]?.action()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}

/// C callback: must be a context-free function. Hotkey events for the application
/// target arrive on the main run loop, so hopping to MainActor is an assertion, not a hop.
private nonisolated func hotKeyEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == CarbonHotKeyCenter.signature else { return status }
    let id = hotKeyID.id
    let center = Unmanaged<CarbonHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.fire(id: id)
    }
    return noErr
}

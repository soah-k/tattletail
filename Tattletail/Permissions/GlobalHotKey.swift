import Carbon
import Foundation

/// A system-wide hotkey registered through Carbon's `RegisterEventHotKey`.
/// Fires regardless of which app has focus and needs no TCC permission —
/// which is exactly what a panic-stop key must guarantee.
///
/// Multiple instances can coexist: every installed Carbon handler receives
/// every hotkey-pressed event, so each instance compares the event's
/// `EventHotKeyID` against its own and passes along everything else.
final class GlobalHotKey {
    typealias Handler = @Sendable () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: Handler
    private let keyCode: UInt32
    private let modifiers: UInt32

    /// Signature identifying our hotkeys to Carbon.
    private static let signature: OSType = 0x5454_4C31   // 'TTL1'
    /// Unique id per instance so handlers can tell hotkeys apart.
    private static var nextID: UInt32 = 1
    fileprivate let hotKeyID: UInt32

    init(preference: HotKeyPreference, handler: @escaping Handler) {
        self.keyCode = preference.keyCode
        self.modifiers = preference.modifiers
        self.handler = handler
        self.hotKeyID = Self.nextID
        Self.nextID += 1
    }

    /// A human-readable description of the binding, for UI display.
    var displayString: String {
        HotKeyPreference(keyCode: keyCode, modifiers: modifiers).displayString
    }

    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        let carbonID = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, carbonID,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        if registerStatus != noErr {
            // Roll back the handler so a failed registration leaves nothing behind.
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
    }

    fileprivate func fire() { handler() }

    deinit { unregister() }
}

/// Top-level Carbon callback; recovers the `GlobalHotKey` from userData and
/// fires it only if the event's hotkey id matches — other hotkeys' events are
/// passed to the next handler in the chain.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }

    var carbonID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &carbonID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    guard carbonID.id == hotKey.hotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    hotKey.fire()
    return noErr
}

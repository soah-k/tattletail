import AppKit
import Carbon
import CoreGraphics
import Foundation

enum CaptureError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            return "Couldn't start capturing input. Make sure Input Monitoring and Accessibility are granted."
        }
    }
}

/// Thread-safe accumulator that translates raw `CGEvent`s into `RecordedEvent`s.
/// All mutation happens under `lock`; the tap thread calls `ingest`, the main
/// thread reads `snapshot()` and calls `begin`/`finish`.
private final class CaptureSession: @unchecked Sendable {
    private let lock = NSLock()
    private let tracker: FrontmostAppTracker

    private var events: [RecordedEvent] = []
    private var isActive = false
    private var startNanos: UInt64 = 0
    private var lastEventNanos: UInt64 = 0
    private var lastMoveNanos: UInt64 = 0
    private var lastFrontBundleId: String?
    private var ownBundleId: String?
    /// When on, clicks/scrolls also record a window-relative anchor (resolved
    /// asynchronously so the tap thread never blocks on Accessibility calls).
    private var windowRelative = false
    /// Off-main serial queue for AX window resolution during capture, so it never
    /// floods the main thread. `anchorGroup` lets finish() drain in-flight work.
    private let axQueue = DispatchQueue(label: "com.soahk.Tattletail.captureAX")
    private let anchorGroup = DispatchGroup()
    private var lastScrollAnchorNanos: UInt64 = 0
    /// Coalesce scroll anchoring — the window under the cursor doesn't move during
    /// a scroll gesture, so one resolution per interval is plenty.
    private let minScrollAnchorInterval: TimeInterval = 0.15
    /// When a recording is started by a global hotkey, the user is still holding
    /// the chord's modifiers; suppress those release-flagsChanged events so the
    /// recording doesn't open with phantom modifier noise.
    private var suppressLeadingFlags = false

    /// Minimum spacing between recorded move samples (bounds file size while
    /// preserving path shape). ~8 ms ≈ 120 samples/second.
    private let minMoveInterval: TimeInterval = 0.008

    init(tracker: FrontmostAppTracker) {
        self.tracker = tracker
    }

    func begin(ownBundleId: String?, suppressLeadingModifierNoise: Bool = false,
               windowRelative: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
        startNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lastEventNanos = 0
        lastMoveNanos = 0
        lastScrollAnchorNanos = 0
        lastFrontBundleId = nil
        self.ownBundleId = ownBundleId
        suppressLeadingFlags = suppressLeadingModifierNoise
        self.windowRelative = windowRelative
        isActive = true
    }

    func finish() -> [RecordedEvent] {
        // Let in-flight anchor resolutions land so the final clicks keep their
        // window anchors — bounded so a hung app can't stall Stop. (The tap is
        // already stopped by the caller, so no new events arrive meanwhile.)
        _ = anchorGroup.wait(timeout: .now() + 0.3)
        lock.lock(); defer { lock.unlock() }
        isActive = false
        return events
    }

    func snapshot() -> (count: Int, duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (events.count, events.last?.offset ?? 0)
    }

    func ingest(type: CGEventType, event: CGEvent) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.lock(); defer { lock.unlock() }
        guard isActive else { return }

        // Don't record the user interacting with Tattletail's own windows.
        let front = tracker.current
        if let mine = ownBundleId, front.bundleId == mine { return }

        // Swallow the modifier releases from a start-recording hotkey chord.
        if suppressLeadingFlags {
            if type == .flagsChanged {
                let modifierMask: CGEventFlags = [
                    .maskShift, .maskControl, .maskAlternate, .maskCommand,
                ]
                if event.flags.intersection(modifierMask).isEmpty {
                    suppressLeadingFlags = false   // chord fully released
                }
                return
            }
            suppressLeadingFlags = false   // any real event ends suppression
        }

        let isMove = type == .mouseMoved
            || type == .leftMouseDragged
            || type == .rightMouseDragged
            || type == .otherMouseDragged
        if isMove {
            let dt = Double(now &- lastMoveNanos) / 1_000_000_000
            if dt < minMoveInterval { return }
        }

        guard var built = translate(type: type, event: event) else { return }

        // Insert an activation step whenever focus moved to a different app.
        if let fb = front.bundleId, fb != lastFrontBundleId {
            let ta = makeTimingLocked(now: now)
            events.append(.appActivate(
                bundleId: fb, appPath: front.path, appName: front.name,
                offset: ta.offset, delay: ta.delay))
            lastFrontBundleId = fb
        }

        let t = makeTimingLocked(now: now)
        built.offset = t.offset
        built.delay = t.delay
        events.append(built)
        if isMove { lastMoveNanos = now }

        // Record a window-relative anchor for targeted events (clicks/scroll).
        // Resolve on a background queue — AX calls can be slow — and backfill by
        // id. Scroll anchoring is coalesced so a fast scroll gesture can't flood.
        if windowRelative, Self.isTargeted(type) {
            var shouldAnchor = true
            if type == .scrollWheel {
                let dt = Double(now &- lastScrollAnchorNanos) / 1_000_000_000
                if dt < minScrollAnchorInterval { shouldAnchor = false }
                else { lastScrollAnchorNanos = now }
            }
            if shouldAnchor {
                let id = built.id
                let point = event.location
                let group = anchorGroup
                group.enter()
                axQueue.async { [weak self] in
                    defer { group.leave() }
                    let anchor = WindowResolver.anchor(at: point)
                    self?.applyAnchor(anchor, to: id)
                }
            }
        }
    }

    private static func isTargeted(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private func applyAnchor(_ anchor: WindowAnchor?, to id: UUID) {
        guard let anchor else { return }
        lock.lock(); defer { lock.unlock() }
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].windowBundleId = anchor.bundleId
        events[i].windowTitle = anchor.title
        events[i].windowOffsetX = anchor.offsetX
        events[i].windowOffsetY = anchor.offsetY
        events[i].windowWidth = anchor.width
        events[i].windowHeight = anchor.height
    }

    // MARK: - Private

    private func makeTimingLocked(now: UInt64) -> (offset: TimeInterval, delay: TimeInterval) {
        let offset = Double(now &- startNanos) / 1_000_000_000
        let delay = lastEventNanos == 0 ? 0 : Double(now &- lastEventNanos) / 1_000_000_000
        lastEventNanos = now
        return (offset, delay)
    }

    /// Convert a raw event into a `RecordedEvent` with zero timing (filled in by
    /// the caller). Returns nil for types we don't record.
    private func translate(type: CGEventType, event: CGEvent) -> RecordedEvent? {
        let loc = event.location
        switch type {
        case .mouseMoved:
            return .mouseMove(x: loc.x, y: loc.y, button: nil, offset: 0, delay: 0)
        case .leftMouseDragged:
            return .mouseMove(x: loc.x, y: loc.y, button: 0, offset: 0, delay: 0)
        case .rightMouseDragged:
            return .mouseMove(x: loc.x, y: loc.y, button: 1, offset: 0, delay: 0)
        case .otherMouseDragged:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return .mouseMove(x: loc.x, y: loc.y, button: n, offset: 0, delay: 0)

        case .leftMouseDown, .leftMouseUp:
            return .mouseButton(down: type == .leftMouseDown, x: loc.x, y: loc.y, button: 0,
                                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                                offset: 0, delay: 0)
        case .rightMouseDown, .rightMouseUp:
            return .mouseButton(down: type == .rightMouseDown, x: loc.x, y: loc.y, button: 1,
                                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                                offset: 0, delay: 0)
        case .otherMouseDown, .otherMouseUp:
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            return .mouseButton(down: type == .otherMouseDown, x: loc.x, y: loc.y, button: n,
                                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                                offset: 0, delay: 0)

        case .scrollWheel:
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            return .scroll(
                lineX: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
                lineY: event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
                pixelX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                pixelY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                continuous: continuous, x: loc.x, y: loc.y, offset: 0, delay: 0)

        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return .key(down: type == .keyDown, keyCode: code, flags: event.flags.rawValue,
                        isRepeat: isRepeat, characters: Self.characters(from: event),
                        offset: 0, delay: 0)

        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return .flagsChanged(keyCode: code, flags: event.flags.rawValue, offset: 0, delay: 0)

        default:
            return nil
        }
    }

    private static func characters(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buffer, count: length)
        // Ignore control characters that would render as noise in the UI.
        return s.unicodeScalars.allSatisfy { $0.value >= 32 } ? s : nil
    }
}

/// Owns the event tap and exposes observable recording state to the UI.
@MainActor
final class EventCaptureEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var liveEventCount = 0
    @Published private(set) var liveDuration: TimeInterval = 0
    /// True while macOS secure input mode is active (keystrokes can't be captured).
    @Published private(set) var secureInputActive = false
    /// Mirror of the user setting; when on, recordings capture window-relative
    /// anchors for clicks/scrolls.
    var windowRelativeEnabled = false

    private let tracker = FrontmostAppTracker()
    private lazy var session = CaptureSession(tracker: tracker)
    private var tap: EventTap?
    private var uiTimer: Timer?

    /// - Parameter viaHotkey: when true, the leading modifier-release noise from
    ///   the start-recording chord is suppressed so it never enters the timeline.
    func startRecording(viaHotkey: Bool = false) throws {
        guard !isRecording else { return }
        session.begin(ownBundleId: Bundle.main.bundleIdentifier,
                      suppressLeadingModifierNoise: viaHotkey,
                      windowRelative: windowRelativeEnabled)
        tracker.start()

        let session = self.session
        let tap = EventTap(eventMask: Self.recordingEventMask()) { type, event in
            session.ingest(type: type, event: event)
        }
        guard tap.start() else {
            tracker.stop()
            throw CaptureError.tapCreationFailed
        }
        self.tap = tap
        isRecording = true
        liveEventCount = 0
        liveDuration = 0
        startUITimer()
    }

    /// Stops recording and returns the captured timeline.
    ///
    /// - Parameter strippingChordKeyCode: when the stop was triggered by a
    ///   global hotkey, pass its key code so the chord's keystrokes (the key
    ///   press plus the modifier flag changes leading into it) are removed
    ///   from the tail of the timeline — the stop gesture itself must never
    ///   be part of the recording.
    @discardableResult
    func stopRecording(strippingChordKeyCode: Int? = nil) -> [RecordedEvent] {
        guard isRecording else { return [] }
        tap?.stop()
        tap = nil
        tracker.stop()
        var events = session.finish()
        if let chordKey = strippingChordKeyCode {
            events = Self.strippingTrailingChord(from: events, keyCode: chordKey)
        }
        isRecording = false
        stopUITimer()
        liveEventCount = events.count
        liveDuration = events.last?.offset ?? 0
        return events
    }

    /// Removes the trailing hotkey chord from a timeline: walking back from the
    /// end, drops key events matching `keyCode` and the `flagsChanged` events
    /// that pressed its modifiers, stopping at the first unrelated event.
    /// Bounded so a long genuine run of modifier changes can't be eaten.
    nonisolated static func strippingTrailingChord(
        from events: [RecordedEvent], keyCode: Int, limit: Int = 8
    ) -> [RecordedEvent] {
        var result = events
        var removed = 0
        while removed < limit, let last = result.last {
            switch last.kind {
            case .keyDown, .keyUp:
                guard last.keyCode == keyCode else { return result }
            case .flagsChanged:
                break
            default:
                return result
            }
            result.removeLast()
            removed += 1
        }
        return result
    }

    // MARK: - UI polling

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snap = self.session.snapshot()
                self.liveEventCount = snap.count
                self.liveDuration = snap.duration
                self.secureInputActive = IsSecureEventInputEnabled()
            }
        }
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
        secureInputActive = false
    }

    // MARK: - Mask

    private static func recordingEventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        return mask
    }
}

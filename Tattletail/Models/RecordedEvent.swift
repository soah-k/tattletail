import Foundation

/// The kind of a single recorded step. A flat, tagged representation is used
/// (rather than an enum with associated values) so the on-disk JSON stays
/// human-readable, diffable, and easy to version and hand-repair.
enum EventKind: String, Codable, Sendable {
    case mouseMove      // cursor moved; a non-nil `button` means it was a drag
    case mouseDown
    case mouseUp
    case scroll
    case keyDown
    case keyUp
    case flagsChanged   // a modifier key changed state
    case appActivate    // bring (and if needed launch) an app to the front
    case delay          // an explicit user-inserted pause
    case typeText       // type a string of text (manually added; not captured)
    case pasteText      // set the clipboard to a string and paste it (⌘V)
}

/// One step in a recording's timeline.
///
/// Timing is stored two ways on purpose: `offset` (seconds since the recording
/// began) drives display and seeking, while `delay` (seconds since the previous
/// event) drives faithful, drift-free playback and survives trimming/editing.
struct RecordedEvent: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var kind: EventKind
    var offset: TimeInterval
    var delay: TimeInterval
    /// When false, the step is skipped entirely on replay (its action AND its
    /// wait), as if commented out. Toggle back on to restore it.
    var enabled: Bool
    /// Optional human-friendly label the user can give a step (e.g. "Submit the
    /// form") so the timeline reads clearly. Display-only; never affects replay.
    var name: String?
    /// When set, consecutive steps sharing this id are collapsed into one
    /// manually-created block in the timeline (mirrors how cursor moves auto-group).
    /// Display/organization only; never affects replay.
    var groupID: UUID?
    /// Optional label for a manual group, shown on the collapsed block.
    var groupName: String?

    // MARK: Mouse
    /// Global screen position in CoreGraphics space (top-left origin, points).
    var x: Double?
    var y: Double?
    /// Button number: 0 left, 1 right, 2+ other. On `.mouseMove` a non-nil value
    /// indicates a drag of that button.
    var button: Int?
    var clickCount: Int?

    // MARK: Scroll
    var scrollLineX: Double?
    var scrollLineY: Double?
    var scrollPixelX: Double?
    var scrollPixelY: Double?
    var scrollContinuous: Bool?

    // MARK: Keyboard
    /// A `CGKeyCode` (virtual key code).
    var keyCode: Int?
    /// Raw `CGEventFlags` bit pattern for modifier state.
    var flags: UInt64?
    var isRepeat: Bool?
    /// Best-effort printable characters, for display only (never replayed).
    var characters: String?

    // MARK: App activation
    var bundleId: String?
    var appPath: String?
    var appName: String?

    // MARK: Window-relative anchor (clicks/scroll only)
    /// When set, replay re-aims this event at the window's CURRENT frame instead
    /// of the absolute x/y. The x/y are kept as a fallback when the window can't
    /// be found. See `WindowResolver`.
    var windowBundleId: String?
    var windowTitle: String?
    var windowOffsetX: Double?   // click.x - window.origin.x at capture
    var windowOffsetY: Double?
    var windowWidth: Double?     // window size at capture
    var windowHeight: Double?

    init(
        id: UUID = UUID(),
        kind: EventKind,
        offset: TimeInterval,
        delay: TimeInterval,
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.offset = offset
        self.delay = delay
        self.enabled = enabled
    }
}

// MARK: - Decoding tolerance

extension RecordedEvent {
    /// Custom decoding so that a missing `id` (e.g. a hand-authored file) is
    /// tolerated by minting a fresh one instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decode(EventKind.self, forKey: .kind)
        // Sanitize timing so a corrupt/hand-edited/imported file can't feed a
        // NaN/∞ into later Int()/UInt64() conversions and trap.
        let rawOffset = try c.decode(TimeInterval.self, forKey: .offset)
        self.offset = rawOffset.isFinite ? max(0, rawOffset) : 0
        let rawDelay = try c.decode(TimeInterval.self, forKey: .delay)
        self.delay = rawDelay.isFinite ? max(0, rawDelay) : 0
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        self.groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        // Drop non-finite coordinates so display/int conversions can't trap.
        self.x = (try c.decodeIfPresent(Double.self, forKey: .x)).flatMap { $0.isFinite ? $0 : nil }
        self.y = (try c.decodeIfPresent(Double.self, forKey: .y)).flatMap { $0.isFinite ? $0 : nil }
        self.button = try c.decodeIfPresent(Int.self, forKey: .button)
        self.clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount)
        self.scrollLineX = try c.decodeIfPresent(Double.self, forKey: .scrollLineX)
        self.scrollLineY = try c.decodeIfPresent(Double.self, forKey: .scrollLineY)
        self.scrollPixelX = try c.decodeIfPresent(Double.self, forKey: .scrollPixelX)
        self.scrollPixelY = try c.decodeIfPresent(Double.self, forKey: .scrollPixelY)
        self.scrollContinuous = try c.decodeIfPresent(Bool.self, forKey: .scrollContinuous)
        self.keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode)
        self.flags = try c.decodeIfPresent(UInt64.self, forKey: .flags)
        self.isRepeat = try c.decodeIfPresent(Bool.self, forKey: .isRepeat)
        self.characters = try c.decodeIfPresent(String.self, forKey: .characters)
        self.bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        self.appPath = try c.decodeIfPresent(String.self, forKey: .appPath)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName)
        self.windowBundleId = try c.decodeIfPresent(String.self, forKey: .windowBundleId)
        self.windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        self.windowOffsetX = (try c.decodeIfPresent(Double.self, forKey: .windowOffsetX)).flatMap { $0.isFinite ? $0 : nil }
        self.windowOffsetY = (try c.decodeIfPresent(Double.self, forKey: .windowOffsetY)).flatMap { $0.isFinite ? $0 : nil }
        self.windowWidth = (try c.decodeIfPresent(Double.self, forKey: .windowWidth)).flatMap { $0.isFinite ? $0 : nil }
        self.windowHeight = (try c.decodeIfPresent(Double.self, forKey: .windowHeight)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// Whether this event carries a usable window-relative anchor.
    var hasWindowAnchor: Bool {
        windowBundleId != nil && windowOffsetX != nil && windowOffsetY != nil
    }
}

// MARK: - Factories used by the capture engine

extension RecordedEvent {
    static func mouseMove(x: Double, y: Double, button: Int?, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .mouseMove, offset: offset, delay: delay)
        e.x = x; e.y = y; e.button = button
        return e
    }

    static func mouseButton(down: Bool, x: Double, y: Double, button: Int, clickCount: Int, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: down ? .mouseDown : .mouseUp, offset: offset, delay: delay)
        e.x = x; e.y = y; e.button = button; e.clickCount = clickCount
        return e
    }

    static func scroll(lineX: Double, lineY: Double, pixelX: Double, pixelY: Double, continuous: Bool, x: Double, y: Double, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .scroll, offset: offset, delay: delay)
        e.scrollLineX = lineX; e.scrollLineY = lineY
        e.scrollPixelX = pixelX; e.scrollPixelY = pixelY
        e.scrollContinuous = continuous
        e.x = x; e.y = y
        return e
    }

    static func key(down: Bool, keyCode: Int, flags: UInt64, isRepeat: Bool, characters: String?, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: down ? .keyDown : .keyUp, offset: offset, delay: delay)
        e.keyCode = keyCode; e.flags = flags; e.isRepeat = isRepeat; e.characters = characters
        return e
    }

    static func flagsChanged(keyCode: Int, flags: UInt64, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .flagsChanged, offset: offset, delay: delay)
        e.keyCode = keyCode; e.flags = flags
        return e
    }

    static func appActivate(bundleId: String?, appPath: String?, appName: String?, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .appActivate, offset: offset, delay: delay)
        e.bundleId = bundleId; e.appPath = appPath; e.appName = appName
        return e
    }

    static func delayStep(_ seconds: TimeInterval, offset: TimeInterval) -> RecordedEvent {
        RecordedEvent(kind: .delay, offset: offset, delay: seconds)
    }

    static func typeText(_ text: String, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .typeText, offset: offset, delay: delay)
        e.characters = text
        return e
    }

    static func pasteText(_ text: String, offset: TimeInterval, delay: TimeInterval) -> RecordedEvent {
        var e = RecordedEvent(kind: .pasteText, offset: offset, delay: delay)
        e.characters = text
        return e
    }
}

// MARK: - Display helpers

extension RecordedEvent {
    var mouseButton: MouseButton? {
        guard let button else { return nil }
        return MouseButton(rawValue: button)
    }

    /// A concise line describing the step for the timeline UI.
    var summary: String {
        switch kind {
        case .mouseMove:
            if let button { return "Drag (\(MouseButton(rawValue: button)?.label ?? "button \(button)"))" }
            return "Move"
        case .mouseDown, .mouseUp:
            let label = mouseButton?.label ?? "Button \(button ?? 0)"
            let verb = kind == .mouseDown ? "down" : "up"
            let clicks = (clickCount ?? 1) > 1 ? " ×\(clickCount ?? 1)" : ""
            return "\(label) \(verb)\(clicks)"
        case .scroll:
            return "Scroll"
        case .keyDown, .keyUp:
            let verb = kind == .keyDown ? "Key down" : "Key up"
            if let characters, !characters.isEmpty { return "\(verb) “\(characters)”" }
            if let keyCode { return "\(verb) [\(keyCode)]" }
            return verb
        case .flagsChanged:
            return "Modifiers"
        case .appActivate:
            return "Activate \(appName ?? bundleId ?? "app")"
        case .delay:
            return "Wait \(String(format: "%.2fs", delay))"
        case .typeText:
            let text = (characters ?? "").replacingOccurrences(of: "\n", with: "⏎")
            let shown = text.count > 28 ? String(text.prefix(28)) + "…" : text
            return "Type “\(shown)”"
        case .pasteText:
            let text = (characters ?? "").replacingOccurrences(of: "\n", with: "⏎")
            let shown = text.count > 28 ? String(text.prefix(28)) + "…" : text
            return "Paste “\(shown)”"
        }
    }

    var symbolName: String {
        switch kind {
        case .mouseMove: return button == nil ? "arrow.up.and.down.and.arrow.left.and.right" : "hand.draw"
        case .mouseDown, .mouseUp: return mouseButton?.symbolName ?? "cursorarrow.click"
        case .scroll: return "scroll"
        case .keyDown, .keyUp: return "keyboard"
        case .flagsChanged: return "command"
        case .appActivate: return "app.badge"
        case .delay: return "clock"
        case .typeText: return "text.cursor"
        case .pasteText: return "doc.on.clipboard"
        }
    }

    /// Low-level, high-frequency steps that the timeline collapses by default.
    var isLowLevel: Bool {
        switch kind {
        case .mouseMove, .flagsChanged: return true
        default: return false
        }
    }
}

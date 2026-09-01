import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Builds and posts synthetic `CGEvent`s that reproduce a recorded timeline.
/// Also tracks which buttons/modifiers are currently held so an abort can
/// release them and never leave the system stuck mid-drag or mid-chord.
final class EventSynthesizer: @unchecked Sendable {
    private let source: CGEventSource?

    /// Buttons currently held down by synthesis (button numbers).
    private var heldButtons: Set<Int> = []
    /// Modifier virtual key codes currently held down by synthesis.
    private var heldModifiers: Set<Int> = []
    /// Last known cursor position, for button-release cleanup.
    private var lastPosition = CGPoint.zero
    /// Union of the current displays (CG global space). When set, posted mouse
    /// points are clamped into it so a recording made on a different display
    /// arrangement can't fling clicks into dead off-screen space.
    var clampRect: CGRect?
    /// When on, clicks/scrolls with a window anchor are re-aimed at the window's
    /// current frame instead of the recorded absolute point.
    var windowRelativeEnabled = false
    /// Per-session cache of resolved window frames (keyed by bundleId|title) so a
    /// run of clicks into the same window triggers one AX resolution, not many.
    private var frameCache: [String: CGRect] = [:]

    init() {
        source = CGEventSource(stateID: .combinedSessionState)
        // Don't let our injected stream suppress the user's real input — the
        // panic hotkey must keep working while we replay.
        if let source {
            source.localEventsSuppressionInterval = 0
        }
    }

    // MARK: - Posting

    func post(_ recorded: RecordedEvent) {
        switch recorded.kind {
        case .mouseMove:
            guard let x = recorded.x, let y = recorded.y else { return }
            let point = clamped(CGPoint(x: x, y: y))
            let (type, button) = moveType(for: recorded.button)
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button)
            if let n = recorded.button, n >= 2 {
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n))
            }
            event?.post(tap: .cghidEventTap)
            lastPosition = point

        case .mouseDown, .mouseUp:
            guard let n = recorded.button else { return }
            let point = clamped(resolvedPoint(for: recorded))
            let down = recorded.kind == .mouseDown
            let (type, button) = buttonType(for: n, down: down)
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button)
            if let clicks = recorded.clickCount {
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            }
            if n >= 2 {
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n))
            }
            event?.post(tap: .cghidEventTap)
            lastPosition = point
            if down { heldButtons.insert(n) } else { heldButtons.remove(n) }

        case .scroll:
            // Scroll lands wherever the cursor is, so put it at the recorded
            // point first — matters when moves were skipped (Jump-to-clicks) or
            // throttled away during capture.
            if recorded.x != nil || recorded.hasWindowAnchor {
                let point = clamped(resolvedPoint(for: recorded))
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                lastPosition = point
            }
            let continuous = recorded.scrollContinuous ?? false
            let units: CGScrollEventUnit = continuous ? .pixel : .line
            let dy = Self.scrollDelta(continuous ? recorded.scrollPixelY : recorded.scrollLineY)
            let dx = Self.scrollDelta(continuous ? recorded.scrollPixelX : recorded.scrollLineX)
            let event = CGEvent(scrollWheelEvent2Source: source, units: units,
                                wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            event?.post(tap: .cghidEventTap)

        case .keyDown, .keyUp:
            // CGKeyCode is UInt16; an out-of-range value from a corrupt/edited
            // file must not trap. Bail rather than crash the playback thread.
            guard let code = recorded.keyCode, let vk = CGKeyCode(exactly: code) else { return }
            let down = recorded.kind == .keyDown
            let event = CGEvent(keyboardEventSource: source,
                                virtualKey: vk, keyDown: down)
            if let flags = recorded.flags {
                event?.flags = CGEventFlags(rawValue: flags)
            }
            if recorded.isRepeat == true {
                event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            event?.post(tap: .cghidEventTap)

        case .flagsChanged:
            guard let code = recorded.keyCode, let flags = recorded.flags,
                  let vk = CGKeyCode(exactly: code) else { return }
            // Determine press vs release: if the flag bit this key controls is
            // set in the new state, the modifier went down.
            let down = Self.isModifierDown(keyCode: code, flags: CGEventFlags(rawValue: flags))
            let event = CGEvent(keyboardEventSource: source,
                                virtualKey: vk, keyDown: down)
            event?.flags = CGEventFlags(rawValue: flags)
            event?.post(tap: .cghidEventTap)
            if down { heldModifiers.insert(code) } else { heldModifiers.remove(code) }

        case .appActivate, .delay, .typeText, .pasteText:
            // Handled by the playback engine, not synthesized here.
            break
        }
    }

    /// Put `text` on the clipboard, paste it with ⌘V into the focused app, then
    /// restore the previous clipboard — reliable for large or special text
    /// without leaking the pasted text or clobbering what the user had copied.
    func paste(_ text: String) {
        let pb = NSPasteboard.general

        // Snapshot the current clipboard (all items and their types) so we can
        // put it back afterward.
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        DispatchQueue.main.sync {
            for item in pb.pasteboardItems ?? [] {
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { if let data = item.data(forType: type) { byType[type] = data } }
                if !byType.isEmpty { saved.append(byType) }
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        let v = CGKeyCode(kVK_ANSI_V)
        let cmd = CGKeyCode(kVK_Command)
        for (key, down, flags): (CGKeyCode, Bool, CGEventFlags) in [
            (cmd, true, .maskCommand),
            (v, true, .maskCommand),
            (v, false, .maskCommand),
            (cmd, false, []),
        ] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }

        // Give the target app a beat to read the clipboard, then restore it.
        Thread.sleep(forTimeInterval: 0.15)
        DispatchQueue.main.sync {
            pb.clearContents()
            let items = saved.map { byType -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in byType { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Release anything still held (called on abort or completion) so the
    /// system is never left mid-drag or with a stuck modifier.
    func releaseHeldState() {
        for n in heldButtons {
            let (type, button) = buttonType(for: n, down: false)
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: lastPosition, mouseButton: button)
            if n >= 2 {
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n))
            }
            event?.post(tap: .cghidEventTap)
        }
        heldButtons.removeAll()

        for code in heldModifiers {
            guard let vk = CGKeyCode(exactly: code) else { continue }
            let event = CGEvent(keyboardEventSource: source,
                                virtualKey: vk, keyDown: false)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        heldModifiers.removeAll()
    }

    /// Type one character into the focused app. Return/Tab go through their key
    /// codes (so they behave as newline/tab), everything else is posted as a
    /// layout-independent Unicode keystroke — so any character or emoji works
    /// regardless of the user's keyboard layout.
    func typeCharacter(_ ch: Character) {
        switch ch {
        case "\n", "\r":
            postKeyCode(CGKeyCode(kVK_Return))
        case "\t":
            postKeyCode(CGKeyCode(kVK_Tab))
        default:
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                units.withUnsafeBufferPointer { buf in
                    event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func postKeyCode(_ vk: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
    }

    /// The point to post an event at: window-relative (re-aimed at the target
    /// window's current frame) when enabled and anchored, else the recorded
    /// absolute point. Falls back to absolute whenever the window can't be found.
    private func resolvedPoint(for e: RecordedEvent) -> CGPoint {
        let fallback = CGPoint(x: e.x ?? lastPosition.x, y: e.y ?? lastPosition.y)
        guard windowRelativeEnabled, e.hasWindowAnchor,
              let ox = e.windowOffsetX, let oy = e.windowOffsetY,
              let bundleId = e.windowBundleId else { return fallback }

        // Resolve on THIS (playback) thread — never main — so a slow AX call
        // can't block the panic hotkey. Cached per window for the session.
        let key = bundleId + "|" + (e.windowTitle ?? "")
        let frame: CGRect
        if let cached = frameCache[key] {
            frame = cached
        } else if let resolved = WindowResolver.currentFrame(bundleId: bundleId, title: e.windowTitle) {
            frame = resolved
            frameCache[key] = resolved
        } else {
            return fallback
        }

        // If the click's offset no longer fits the (possibly resized) window, the
        // target has likely moved within it — fall back to the absolute point.
        guard ox >= 0, oy >= 0, ox <= frame.width, oy <= frame.height else { return fallback }
        return CGPoint(x: frame.origin.x + ox, y: frame.origin.y + oy)
    }

    /// Clamp a point into the current display union, if one is set. A no-op when
    /// the point is already on-screen (the normal case), so it only pulls in
    /// coordinates left over from a different display arrangement.
    private func clamped(_ p: CGPoint) -> CGPoint {
        guard let r = clampRect, !r.isNull, !r.isEmpty else { return p }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1),
                       y: min(max(p.y, r.minY), r.maxY - 1))
    }

    /// Safe Double→Int32 for scroll deltas: a NaN/inf/out-of-range value in a
    /// hand-edited or corrupt recording must not trap the playback thread.
    static func scrollDelta(_ value: Double?) -> Int32 {
        guard let value, value.isFinite else { return 0 }
        return Int32(value.rounded().clamped(to: -100_000...100_000))
    }

    // MARK: - Type mapping

    private func moveType(for buttonNumber: Int?) -> (CGEventType, CGMouseButton) {
        switch buttonNumber {
        case nil: return (.mouseMoved, .left)
        case 0: return (.leftMouseDragged, .left)
        case 1: return (.rightMouseDragged, .right)
        default: return (.otherMouseDragged, .center)
        }
    }

    private func buttonType(for buttonNumber: Int, down: Bool) -> (CGEventType, CGMouseButton) {
        switch buttonNumber {
        case 0: return (down ? .leftMouseDown : .leftMouseUp, .left)
        case 1: return (down ? .rightMouseDown : .rightMouseUp, .right)
        default: return (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    /// Maps a modifier virtual key code to the `CGEventFlags` bit it controls,
    /// then reports whether that bit is set (i.e. the key went down).
    static func isModifierDown(keyCode: Int, flags: CGEventFlags) -> Bool {
        let bit: CGEventFlags
        switch keyCode {
        case kVK_Shift, kVK_RightShift: bit = .maskShift
        case kVK_Control, kVK_RightControl: bit = .maskControl
        case kVK_Option, kVK_RightOption: bit = .maskAlternate
        case kVK_Command, kVK_RightCommand: bit = .maskCommand
        case kVK_CapsLock: bit = .maskAlphaShift
        case kVK_Function: bit = .maskSecondaryFn
        default: return false
        }
        return flags.contains(bit)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

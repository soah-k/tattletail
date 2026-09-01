import AppKit
import Carbon
import Foundation

/// The global hotkey actions Tattletail supports.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case startRecording
    case stopRecording
    case panicStop
    case scheduleReplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .startRecording: return "Start recording"
        case .stopRecording: return "Stop recording"
        case .panicStop: return "Panic stop"
        case .scheduleReplay: return "Schedule replay"
        }
    }

    var detail: String {
        switch self {
        case .startRecording: return "Begins a new recording from anywhere."
        case .stopRecording: return "Stops and saves the current recording. The hotkey itself is never recorded."
        case .panicStop: return "Instantly halts any replay or countdown — and stops a recording too."
        case .scheduleReplay: return "Opens the Schedule a Replay window from anywhere."
        }
    }
}

/// A user-configurable key combination (Carbon key code + Carbon modifier mask).
struct HotKeyPreference: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey).
    var modifiers: UInt32

    static let defaults: [HotKeyAction: HotKeyPreference] = [
        .startRecording: HotKeyPreference(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)),
        .stopRecording: HotKeyPreference(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | optionKey)),
        .panicStop: HotKeyPreference(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey | optionKey)),
        .scheduleReplay: HotKeyPreference(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)),
    ]

    /// A human-readable rendering like "⌥⌘E".
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: keyCode))
        return parts.joined()
    }
}

/// Loads and saves hotkey preferences in UserDefaults.
enum HotKeyStore {
    private static func key(for action: HotKeyAction) -> String {
        "hotkey.\(action.rawValue)"
    }

    static func load(_ action: HotKeyAction) -> HotKeyPreference {
        guard let data = UserDefaults.standard.data(forKey: key(for: action)),
              let pref = try? JSONDecoder().decode(HotKeyPreference.self, from: data) else {
            return HotKeyPreference.defaults[action]!
        }
        return pref
    }

    static func save(_ pref: HotKeyPreference, for action: HotKeyAction) {
        if let data = try? JSONEncoder().encode(pref) {
            UserDefaults.standard.set(data, forKey: key(for: action))
        }
    }

    static func resetAll() {
        for action in HotKeyAction.allCases {
            UserDefaults.standard.removeObject(forKey: key(for: action))
        }
    }
}

/// Converts AppKit modifier flags (from an NSEvent in the shortcut recorder)
/// to the Carbon mask `RegisterEventHotKey` expects.
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    return mask
}

/// Human-readable names for virtual key codes (US ANSI layout).
enum KeyCodeNames {
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "key \(keyCode)"
    }
}

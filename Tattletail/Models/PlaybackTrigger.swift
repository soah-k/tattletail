import Foundation

/// What kicked off a replay. Lives in a shared file (not with `RunRecord`)
/// because both the playback engine and the scheduler reference it, and those
/// stay in every edition even though run history (`RunRecord`) is paid-only.
enum PlaybackTrigger: String, Codable, Sendable {
    case manual       // the Replay button / hotkey
    case countdown    // "Run in…" countdown
    case scheduled    // a saved schedule fired

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .countdown: return "Countdown"
        case .scheduled: return "Schedule"
        }
    }
}

import Foundation

/// A logical mouse button. Raw values line up with `CGMouseButton`
/// (left = 0, right = 1, center = 2); any value ≥ 2 is an "other" button
/// whose concrete number is preserved on the event itself.
enum MouseButton: Int, Codable, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case center = 2

    /// A short, human-friendly label for the timeline UI.
    var label: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Middle"
        }
    }

    /// SF Symbol used to represent this button in the timeline.
    var symbolName: String {
        switch self {
        case .left: return "cursorarrow.click"
        case .right: return "cursorarrow.click.2"
        case .center: return "cursorarrow.click.badge.clock"
        }
    }
}

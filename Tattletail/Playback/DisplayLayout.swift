import CoreGraphics

/// Helpers for reasoning about the screen arrangement. Recordings store absolute
/// CGEvent global-space coordinates (top-left origin), so a different display
/// layout at replay time can put clicks in the wrong place. We capture a
/// signature of the layout with each recording to warn on mismatch, and clamp
/// posted points to the current screens as a last-ditch guardrail.
enum DisplayLayout {
    /// A stable, order-independent description of the active displays' bounds in
    /// CG global (top-left) coordinates. Equal strings ⇒ the same arrangement.
    static func signature() -> String {
        bounds()
            .map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width))x\(Int($0.height))" }
            .sorted()
            .joined(separator: "|")
    }

    /// Union of all active displays' bounds in CG global (top-left) space, or
    /// `nil` when it can't be determined (never clamp in that case).
    static func unionBounds() -> CGRect? {
        let all = bounds()
        guard !all.isEmpty else { return nil }
        let union = all.reduce(CGRect.null) { $0.union($1) }
        return union.isNull ? nil : union
    }

    private static func bounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

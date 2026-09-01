import AppKit
import ApplicationServices

/// Where a click landed relative to a window, so a replay can re-aim it at the
/// window's CURRENT position/size instead of a fixed desktop point.
/// Coordinates are CGEvent/AX global space (top-left origin), so no conversion is
/// needed between capture, AX, and playback.
struct WindowAnchor: Sendable, Equatable {
    var bundleId: String?
    var title: String?
    var offsetX: Double   // click.x - window.origin.x
    var offsetY: Double   // click.y - window.origin.y
    var width: Double     // window size at capture (for validation/fallback)
    var height: Double
}

/// Resolves the on-screen window under a point (at capture) and re-resolves that
/// window's current frame (at replay), using the Accessibility API. Requires the
/// Accessibility grant the app already has — no Screen Recording permission.
///
/// AX messaging is synchronous IPC and thread-safe, so these run OFF the main
/// thread (a dedicated capture queue; the playback thread directly) — the main
/// run loop must stay free so the panic hotkey and abort always fire instantly.
/// A short messaging timeout keeps an unresponsive target app from hanging us.
enum WindowResolver {
    private static let timeout: Float = 0.4

    /// The window under `point` (top-left global coords), as a relative anchor.
    static func anchor(at point: CGPoint) -> WindowAnchor? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)

        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef,
              let window = windowElement(for: element),
              let frame = frame(of: window) else { return nil }

        return WindowAnchor(
            bundleId: bundleId(of: window),
            title: stringValue(window, kAXTitleAttribute),
            offsetX: point.x - frame.origin.x,
            offsetY: point.y - frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    /// The current frame of the window matching `bundleId`/`title`, for replay.
    static func currentFrame(bundleId: String?, title: String?) -> CGRect? {
        guard let bundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
              app.processIdentifier > 0 else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, timeout)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return nil }

        // Prefer an exact title match; then the app's main window; else the first.
        if let title, !title.isEmpty,
           let match = windows.first(where: { stringValue($0, kAXTitleAttribute) == title }),
           let f = frame(of: match) {
            return f
        }
        if let main = elementValue(axApp, kAXMainWindowAttribute), let f = frame(of: main) {
            return f
        }
        return frame(of: windows[0])
    }

    // MARK: - AX helpers

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        // Most elements expose their containing window directly; otherwise walk
        // up the parent chain until we reach a window-role element.
        if let win = elementValue(element, "AXWindow") { return win }
        var current: AXUIElement? = element
        var hops = 0
        while let el = current, hops < 25 {
            if stringValue(el, kAXRoleAttribute) == (kAXWindowRole as String) { return el }
            current = elementValue(el, kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let posRaw = rawValue(window, kAXPositionAttribute), CFGetTypeID(posRaw) == AXValueGetTypeID(),
              let sizeRaw = rawValue(window, kAXSizeAttribute), CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func bundleId(of window: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        rawValue(element, attribute) as? String
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = rawValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func rawValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

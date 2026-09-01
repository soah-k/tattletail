import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the two TCC grants Tattletail needs and offers deep links to the
/// right System Settings panes. Neither grant can be toggled programmatically.
@MainActor
final class PermissionsManager: ObservableObject {
    /// Accessibility — required to POST synthetic events into other apps.
    @Published private(set) var accessibilityGranted = false
    /// Input Monitoring — required to LISTEN via the event tap while recording.
    @Published private(set) var inputMonitoringGranted = false

    var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Grants usually take effect when the app regains focus after the user
        // flips the toggle in System Settings, so re-check on activation.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    /// Ask the system to show the Accessibility prompt (adds us to the list).
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Ask the system to show the Input Monitoring prompt.
    func requestInputMonitoring() {
        CGRequestListenEventAccess()
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

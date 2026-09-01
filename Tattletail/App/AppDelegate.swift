import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Re-open the main window when the Dock icon is clicked with no windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    /// Keep running when the last window closes — the menu bar extra remains,
    /// and scheduled runs require the app to stay alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

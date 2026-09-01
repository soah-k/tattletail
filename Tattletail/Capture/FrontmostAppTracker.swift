import AppKit

/// A snapshot of which application is frontmost.
struct FrontmostAppInfo: Sendable, Equatable {
    var bundleId: String?
    var path: String?
    var name: String?
}

/// Tracks the frontmost application by observing `NSWorkspace` on the main
/// thread and caching the result behind a lock so the capture thread can read
/// it cheaply without touching AppKit off-main.
final class FrontmostAppTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = FrontmostAppInfo()
    private var observer: NSObjectProtocol?

    /// The most recently observed frontmost app. Safe to read from any thread.
    var current: FrontmostAppInfo {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    /// Begin observing. Call on the main thread.
    @MainActor
    func start() {
        update(with: NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(with: app)
        }
    }

    /// Stop observing. Call on the main thread.
    @MainActor
    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func update(with app: NSRunningApplication?) {
        let info = FrontmostAppInfo(
            bundleId: app?.bundleIdentifier,
            path: app?.bundleURL?.path,
            name: app?.localizedName
        )
        lock.lock(); _current = info; lock.unlock()
    }
}

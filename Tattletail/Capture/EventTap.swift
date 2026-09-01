import CoreGraphics
import Foundation

/// A thin wrapper around a listen-only `CGEvent` session tap that runs its own
/// run loop on a dedicated thread and forwards raw events to a handler.
///
/// The tap is passive (`.listenOnly`): the user's real input passes through
/// untouched and the window server never blocks on the callback, which makes
/// `kCGEventTapDisabledByTimeout` rare.
///
/// Thread-safety: `start()`/`stop()` run on the main thread while the tap thread
/// (and the C callback on it) also touch the port and run-loop handles. All four
/// mutable handles are therefore guarded by `lock`, so teardown can't race the
/// callback or the just-spawned thread.
final class EventTap: @unchecked Sendable {
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Void

    fileprivate let handler: Handler
    private let eventMask: CGEventMask

    private let lock = NSLock()
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(eventMask: CGEventMask, handler: @escaping Handler) {
        self.eventMask = eventMask
        self.handler = handler
    }

    /// Create the tap and start pumping its run loop on a dedicated thread.
    /// Returns false if the tap could not be created (usually a missing
    /// Input Monitoring / Accessibility grant).
    func start() -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            return false
        }
        lock.lock(); machPort = port; lock.unlock()

        let thread = Thread { [weak self] in
            guard let self else { return }
            // If stop() invalidated the port in the window before this thread
            // ran, bail instead of installing a source for a dead port.
            self.lock.lock()
            let active = self.machPort != nil
            self.lock.unlock()
            guard active, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
            let rl = CFRunLoopGetCurrent()

            self.lock.lock()
            guard self.machPort != nil else { self.lock.unlock(); return }
            self.runLoopSource = source
            self.runLoop = rl
            self.lock.unlock()

            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.soahk.Tattletail.eventtap"
        thread.stackSize = 512 * 1024
        lock.lock(); self.thread = thread; lock.unlock()
        thread.start()
        return true
    }

    /// Disable the tap and tear down its run loop.
    func stop() {
        // Snapshot and clear the handles under the lock, then act on the
        // snapshots — so the callback (which locks too) never sees a half-freed
        // state, and a concurrent read gets nil rather than a dangling port.
        lock.lock()
        let port = machPort
        let rl = runLoop
        let source = runLoopSource
        machPort = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        lock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let rl, let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        if let rl { CFRunLoopStop(rl) }
    }

    /// Re-enable the tap after the system disabled it (called from the callback,
    /// on the tap thread). A no-op if we've since been stopped.
    fileprivate func reenable() {
        lock.lock()
        let port = machPort
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    deinit { stop() }
}

/// The C callback. Recovers the owning `EventTap` from `userInfo`, re-enables
/// the tap if the system disabled it, and forwards other events to the handler.
/// Being a top-level function with no captures, it is a valid `@convention(c)`
/// function pointer.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }

    tap.handler(type, event)
    return Unmanaged.passUnretained(event)
}

import AppKit
import Foundation

/// Where a replay currently stands, for UI display.
enum PlaybackPhase: Equatable, Sendable {
    case idle
    case countingDown(remaining: Int)
    case playing(pass: Int, totalPasses: Int?)   // totalPasses nil when looping
    case finished
    case aborted
}

/// Replays a recording by synthesizing events on a dedicated thread with
/// drift-free deadline timing, activating (and launching) target apps as
/// `appActivate` steps are encountered.
@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var progress: Double = 0   // 0...1 within current pass

    /// Called on the main actor each time a full pass finishes (never for an
    /// aborted pass). Used to increment the recording's run counter.
    var onPassCompleted: (@MainActor (UUID) -> Void)?
    /// Called on the main actor once playback fully ends (finished or aborted).
    var onPlaybackEnded: (@MainActor () -> Void)?

    /// Whether the current/last playback should pull the app back to the front
    /// when it ends. User-initiated replays do; background scheduled fires don't
    /// (so a scheduled run doesn't steal focus from whatever you're doing).
    private(set) var returnsFocusOnEnd = true

    /// Mirror of the user setting; when on, anchored clicks/scrolls are re-aimed
    /// at the target window's current position on replay.
    var windowRelativeEnabled = false

    // Context for the run-history entry logged when playback ends.
    private(set) var currentTrigger: PlaybackTrigger = .manual
    private(set) var currentRecordingID: UUID?
    private(set) var currentRecordingName = ""
    private(set) var currentStartedAt = Date()
    /// True once a real playback thread began (so a countdown cancelled before
    /// it fires isn't logged as a run).
    private(set) var lastRunDidStart = false

    var isBusy: Bool {
        switch phase {
        case .idle, .finished, .aborted: return false
        default: return true
        }
    }

    private let abortController = PlaybackAbortController()
    private var countdownTask: Task<Void, Never>?
    private var playbackThread: Thread?

    /// How long to wait for a launched app to become frontmost before giving up
    /// and continuing anyway.
    private let activationTimeout: TimeInterval = 15
    /// Settle delay after an app becomes frontmost, before posting into it.
    private let activationSettleDelay: TimeInterval = 0.35

    // MARK: - Public API

    /// Play immediately.
    func play(_ recording: Recording, options: PlaybackOptions = .default,
              trigger: PlaybackTrigger = .manual, returnFocusOnEnd: Bool = true) {
        guard !isBusy else { return }
        lastRunDidStart = false
        currentTrigger = trigger
        returnsFocusOnEnd = returnFocusOnEnd
        startPlayback(recording, options: options)
    }

    /// Play after `seconds` with a visible countdown.
    func play(_ recording: Recording, options: PlaybackOptions = .default, afterSeconds seconds: Int,
              trigger: PlaybackTrigger = .countdown, returnFocusOnEnd: Bool = true) {
        guard !isBusy, seconds > 0 else {
            play(recording, options: options, trigger: trigger, returnFocusOnEnd: returnFocusOnEnd)
            return
        }
        lastRunDidStart = false
        currentTrigger = trigger
        returnsFocusOnEnd = returnFocusOnEnd
        abortController.reset()
        phase = .countingDown(remaining: seconds)
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                // Check Task.isCancelled, not just the shared abort flag: a
                // cancelled task's sleeps return immediately, and the abort
                // flag may have been reset by a newer playback by the time
                // this zombie resumes — it must never touch state again.
                guard let self, !Task.isCancelled, !self.abortController.isAborted else { return }
                self.phase = .countingDown(remaining: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, !self.abortController.isAborted else { return }
            self.startPlayback(recording, options: options)
        }
    }

    /// Abort whatever is happening (countdown or replay). Safe to call anytime.
    func stop() {
        abortController.abort()
        countdownTask?.cancel()
        countdownTask = nil
        if case .countingDown = phase {
            // The playback thread never started, so it won't fire the end
            // callback — do it here so listeners (e.g. return-to-front) still run.
            phase = .aborted
            onPlaybackEnded?()
        }
    }

    // MARK: - Core playback

    private func startPlayback(_ recording: Recording, options: PlaybackOptions) {
        // Reentrancy guard: two playback threads must never coexist (the
        // countdown path reaches here without going through play()).
        if case .playing = phase { return }

        // Nothing that would actually execute → don't spin a thread. An empty,
        // all-disabled, or (with Jump-to-clicks on) all-moves recording would
        // otherwise loop forever posting nothing, un-abortable and CPU-pegging.
        #if FREE_BUILD
        let willRun = recording.events.contains { $0.enabled }
        #else
        let willRun = recording.events.contains {
            $0.enabled && !(options.jumpInstantly && $0.kind == .mouseMove && $0.button == nil)
        }
        #endif
        guard willRun else {
            phase = .finished
            return
        }
        abortController.reset()
        phase = .playing(pass: 1, totalPasses: options.loops ? nil : options.repeatCount)
        progress = 0

        let abort = abortController
        let events = recording.events
        let recordingID = recording.id
        let totalDuration = max(recording.duration, 0.001)
        let speed = max(options.speed, 0.01)
        let loops = options.loops
        let repeatCount = options.repeatCount
        #if !FREE_BUILD
        let jumpInstantly = options.jumpInstantly
        let humanize = options.humanize
        #endif

        // Snapshot context for the history entry logged when this session ends.
        currentRecordingID = recording.id
        currentRecordingName = recording.name
        currentStartedAt = Date()
        lastRunDidStart = true

        let clampRect = DisplayLayout.unionBounds()
        let windowRelative = windowRelativeEnabled
        let thread = Thread { [weak self] in
            let synthesizer = EventSynthesizer()
            synthesizer.clampRect = clampRect
            synthesizer.windowRelativeEnabled = windowRelative
            var pass = 0
            var wasAborted = false

            passLoop: while loops || pass < repeatCount {
                pass += 1
                if pass > 1 {
                    Task { @MainActor [weak self] in
                        self?.phase = .playing(pass: pass, totalPasses: loops ? nil : repeatCount)
                    }
                }

                let passStart = machAbsoluteNow()
                var deadline = machAbsoluteNow()
                var lastProgressPush: TimeInterval = -1

                for event in events {
                    if abort.isAborted { wasAborted = true; break passLoop }

                    // A disabled step is skipped completely — its action AND its
                    // wait — as if it weren't in the timeline at all.
                    if !event.enabled { continue }

                    #if !FREE_BUILD
                    // Jump-instantly: skip pure cursor moves (not drags) and
                    // their waits, so replay goes straight between clicks.
                    if jumpInstantly && event.kind == .mouseMove && event.button == nil { continue }
                    #endif

                    // Wait out this event's delay (scaled), without cumulative drift.
                    // Sanitize first: a NaN/∞/huge delay from a corrupt or hand-edited
                    // file must not trap UInt64() and crash the playback thread
                    // (which would skip releaseHeldState and leave a button stuck).
                    let rawDelay = event.delay.isFinite ? max(event.delay, 0) : 0
                    #if !FREE_BUILD
                    // Humanize: nudge each wait by a small random factor so the
                    // timing doesn't look mechanically perfect.
                    let jitter = humanize ? Double.random(in: 0.85...1.15) : 1.0
                    #else
                    let jitter = 1.0
                    #endif
                    let scaledDelay = max(rawDelay * jitter / speed, PlaybackOptions.minimumInterEventDelay)
                    let nanos = min(scaledDelay * 1_000_000_000, 1e18)
                    deadline = deadline &+ nanosToMachTime(UInt64(nanos))
                    machWaitUntil(deadline: deadline, abort: abort)
                    if abort.isAborted { wasAborted = true; break passLoop }

                    switch event.kind {
                    case .appActivate:
                        Self.performActivation(of: event, timeout: self?.activationTimeout ?? 15,
                                               settle: self?.activationSettleDelay ?? 0.35,
                                               abort: abort)
                        // Activation blocks for real time; restart the clock so
                        // subsequent delays stay relative.
                        deadline = machAbsoluteNow()
                    case .delay:
                        break   // its delay was already waited above
                    case .typeText:
                        // Type each character with a small gap (scaled by speed)
                        // so apps register them, checking abort between chars.
                        let perChar = nanosToMachTime(UInt64(6_000_000 / max(speed, 0.01)))
                        for ch in event.characters ?? "" {
                            if abort.isAborted { wasAborted = true; break passLoop }
                            synthesizer.typeCharacter(ch)
                            deadline = deadline &+ perChar
                            machWaitUntil(deadline: deadline, abort: abort)
                        }
                    case .pasteText:
                        synthesizer.paste(event.characters ?? "")
                        // The paste (⌘V) needs a beat to land before the next step.
                        deadline = deadline &+ nanosToMachTime(UInt64(40_000_000))
                        machWaitUntil(deadline: deadline, abort: abort)
                    default:
                        synthesizer.post(event)
                    }

                    // Push progress at most ~20×/second.
                    if event.offset - lastProgressPush > 0.05 {
                        lastProgressPush = event.offset
                        let p = min(event.offset / totalDuration, 1)
                        Task { @MainActor [weak self] in self?.progress = p }
                    }
                }

                // Floor each pass to ~10ms wall-clock so no configuration (e.g.
                // Jump-to-clicks + Loop on a nearly-instant recording) can spin a
                // tight loop that pegs a core and floods the main queue —
                // starving the Stop controls and the panic hotkey.
                let minPassTicks = nanosToMachTime(10_000_000)
                if machAbsoluteNow() &- passStart < minPassTicks {
                    machWaitUntil(deadline: passStart &+ minPassTicks, abort: abort)
                    if abort.isAborted { wasAborted = true; break passLoop }
                }

                // Reached here only if the pass ran to completion (an abort
                // breaks out of passLoop above), so count this play-through.
                // Use DispatchQueue.main (FIFO from this thread) rather than a
                // detached Task so the final pass's increment is guaranteed to
                // land before the end-of-session flush below.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onPassCompleted?(recordingID) }
                }
            }

            synthesizer.releaseHeldState()
            let aborted = wasAborted
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.phase = aborted ? .aborted : .finished
                    self?.progress = aborted ? self?.progress ?? 0 : 1
                    self?.playbackThread = nil
                    self?.onPlaybackEnded?()
                }
            }
        }
        thread.name = "com.soahk.Tattletail.playback"
        thread.qualityOfService = .userInteractive
        playbackThread = thread
        thread.start()
    }

    // MARK: - App activation (called from the playback thread)

    nonisolated private static func performActivation(of event: RecordedEvent, timeout: TimeInterval,
                                                      settle: TimeInterval, abort: PlaybackAbortController) {
        guard let bundleId = event.bundleId else { return }

        // Already frontmost? Nothing to do.
        if frontmostBundleId() == bundleId { return }

        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first

        if let running {
            DispatchQueue.main.sync { _ = running.activate() }
        } else {
            // Launch ONLY by resolving the bundle id through LaunchServices — never
            // launch the raw `appPath` stored in the recording. A shared/imported
            // recording could otherwise point appPath at an arbitrary executable;
            // resolving by bundle id means we only ever open the installed app for
            // that identifier (and open nothing if it isn't installed).
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            DispatchQueue.main.sync {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            }
        }

        // Poll until the app is frontmost (or timeout/abort), then settle.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !abort.isAborted {
            if frontmostBundleId() == bundleId {
                Thread.sleep(forTimeInterval: settle)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    nonisolated private static func frontmostBundleId() -> String? {
        DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }
}

// MARK: - Mach timing helpers

private func machTimebase() -> mach_timebase_info_data_t {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}

private let timebase = machTimebase()

func machAbsoluteNow() -> UInt64 { mach_absolute_time() }

/// Convert nanoseconds to mach absolute time units.
func nanosToMachTime(_ nanos: UInt64) -> UInt64 {
    // ticks = nanos * denom / numer
    nanos * UInt64(timebase.denom) / UInt64(timebase.numer)
}

/// Sleep until `deadline` (mach absolute time), waking periodically to honor
/// aborts. Long waits are chunked so the panic hotkey stays responsive.
func machWaitUntil(deadline: UInt64, abort: PlaybackAbortController) {
    let chunkNanos: UInt64 = 50_000_000   // re-check abort every 50 ms
    let chunkTicks = nanosToMachTime(chunkNanos)
    while true {
        if abort.isAborted { return }
        let now = mach_absolute_time()
        if now >= deadline { return }
        let remaining = deadline - now
        if remaining > chunkTicks {
            mach_wait_until(now + chunkTicks)
        } else {
            mach_wait_until(deadline)
            return
        }
    }
}

import AppKit
import CoreGraphics
import Foundation
import UserNotifications

/// Fires saved schedules while the app is running. v1 deliberately requires the
/// app to stay open (stated plainly in the UI); Launch at Login is offered so
/// it comes back after a reboot.
@MainActor
final class SchedulerService: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []

    /// User switch to pause every schedule at once without touching each one's
    /// own enabled state (e.g. before a meeting). Persisted.
    @Published var isPaused: Bool { didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) } }
    /// Post a heads-up notification a few seconds before a scheduled replay.
    @Published var notifyBeforeScheduled: Bool {
        didSet {
            UserDefaults.standard.set(notifyBeforeScheduled, forKey: Self.notifyKey)
            if notifyBeforeScheduled { requestNotificationAuth() }
        }
    }
    /// Defer a due schedule while the Mac is actively being used (within the
    /// missed-fire grace window), so a run doesn't fight your input.
    @Published var onlyRunWhenIdle: Bool { didSet { UserDefaults.standard.set(onlyRunWhenIdle, forKey: Self.idleKey) } }

    private static let pausedKey = "schedulesPaused"
    private static let notifyKey = "notifyBeforeScheduled"
    private static let idleKey = "onlyRunWhenIdle"

    private let store: RecordingStore
    private let playback: PlaybackEngine
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// A missed schedule older than this on wake is skipped rather than fired,
    /// so waking a laptop doesn't replay something from hours ago.
    private let missedFireGrace: TimeInterval = 5 * 60
    /// How far ahead of a fire to post the pre-fire notification.
    private let notifyLeadTime: TimeInterval = 10
    /// Seconds of no input required to count as "idle" for onlyRunWhenIdle.
    private let idleThreshold: TimeInterval = 30
    /// Occurrences already notified ("<id>|<fireEpoch>"), so we notify once each.
    private var notified: Set<String> = []

    init(store: RecordingStore, playback: PlaybackEngine) {
        self.store = store
        self.playback = playback
        self.isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        self.notifyBeforeScheduled = (UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool) ?? true
        self.onlyRunWhenIdle = UserDefaults.standard.bool(forKey: Self.idleKey)
        schedules = store.loadSchedules()

        // Tick once a second: cheap, and keeps "fires in 00:05" countdowns live.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }

        // Sleep pauses timers; re-evaluate on wake for missed/overdue schedules.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }

        if notifyBeforeScheduled { requestNotificationAuth() }
    }

    // MARK: - CRUD

    func add(_ schedule: Schedule) {
        schedules.append(schedule)
        persist()
    }

    func update(_ schedule: Schedule) {
        if let i = schedules.firstIndex(where: { $0.id == schedule.id }) {
            var updated = schedule
            // Re-enabling a repeater whose fire time passed while paused should
            // resume at the next future occurrence, not fire immediately.
            if updated.isEnabled && updated.repeatRule != .once && updated.fireDate <= Date() {
                updated.advance(now: Date())
            }
            schedules[i] = updated
            persist()
        }
    }

    func remove(id: UUID) {
        schedules.removeAll { $0.id == id }
        persist()
    }

    func removeAll(forRecording recordingID: UUID) {
        schedules.removeAll { $0.recordingID == recordingID }
        persist()
    }

    /// Schedules for one recording, soonest first.
    func schedules(forRecording recordingID: UUID) -> [Schedule] {
        schedules
            .filter { $0.recordingID == recordingID }
            .sorted { $0.fireDate < $1.fireDate }
    }

    /// The next enabled schedule across the library, if any.
    var nextUpcoming: Schedule? {
        schedules
            .filter { $0.isEnabled && $0.fireDate > Date() }
            .min { $0.fireDate < $1.fireDate }
    }

    // MARK: - Firing

    private func tick() {
        // Paused: nothing fires, advances, or notifies until resumed.
        guard !isPaused else { return }

        let now = Date()
        var mutated = false

        for i in schedules.indices where schedules[i].isEnabled && !schedules[i].completed {
            let schedule = schedules[i]

            // Pre-fire heads-up, once per occurrence.
            if notifyBeforeScheduled {
                let lead = schedule.fireDate.timeIntervalSince(now)
                if lead > 0 && lead <= notifyLeadTime {
                    let key = "\(schedule.id.uuidString)|\(Int(schedule.fireDate.timeIntervalSince1970))"
                    if notified.insert(key).inserted {
                        postPrefireNotification(name: schedule.recordingName)
                    }
                }
            }

            guard schedule.isDue(now: now) else { continue }
            let lateness = now.timeIntervalSince(schedule.fireDate)

            if lateness > missedFireGrace {
                // Hopelessly missed (deep sleep, app closed): don't replay
                // something from hours ago. Repeaters roll to their next
                // occurrence; one-shots are marked completed.
                schedules[i].advance(now: now)
                mutated = true
                continue
            }

            // Within the grace window but a replay is already running: leave
            // the schedule due so the next tick retries — never destroy a
            // pending fire just because playback was momentarily busy.
            guard !playback.isBusy else { continue }

            // Only-when-idle: defer (leave due) while the user is active, so the
            // run waits — up to the grace window — for a lull.
            if onlyRunWhenIdle && systemIdleSeconds() < idleThreshold { continue }

            if let recording = try? store.load(id: schedule.recordingID) {
                // A scheduled fire runs in the background — don't yank focus to
                // Tattletail when it finishes.
                playback.play(recording, options: schedule.options,
                              trigger: .scheduled, returnFocusOnEnd: false)
            }
            schedules[i].advance(now: now)
            mutated = true
        }

        // Prune only completed one-shots — a user-paused schedule is never
        // completed and must survive indefinitely.
        let before = schedules.count
        schedules.removeAll { $0.completed }
        if mutated || schedules.count != before {
            persist()
        }
        pruneNotified(now: now)
    }

    private func persist() {
        try? store.saveSchedules(schedules)
    }

    // MARK: - Notifications & idle

    private func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postPrefireNotification(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Tattletail"
        content.body = "About to replay “\(name)”."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Seconds since the most recent real hardware input (excludes our injected
    /// events, via `.hidSystemState`).
    private func systemIdleSeconds() -> CFTimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .keyDown, .flagsChanged, .scrollWheel, .leftMouseDragged, .rightMouseDragged,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }

    private func pruneNotified(now: Date) {
        guard notified.count > 200 else { return }
        let cutoff = now.timeIntervalSince1970 - 60
        notified = notified.filter { (Double($0.split(separator: "|").last.map(String.init) ?? "") ?? 0) > cutoff }
    }
}

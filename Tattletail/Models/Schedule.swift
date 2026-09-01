import Foundation

/// How a schedule repeats after it fires.
enum RepeatRule: String, Codable, Sendable, CaseIterable, Identifiable {
    case once
    case hourly
    case daily
    case weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .once: return "Once"
        case .hourly: return "Every hour"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        }
    }

    /// The next fire date after `date`, or nil for a one-shot schedule.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .once: return nil
        case .hourly: return calendar.date(byAdding: .hour, value: 1, to: date)
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        }
    }
}

/// A saved plan to replay a recording at a specific time.
struct Schedule: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var recordingID: UUID
    var recordingName: String   // denormalized for display without loading the recording
    var fireDate: Date
    var repeatRule: RepeatRule
    /// User-controlled pause switch. A paused schedule is never fired, never
    /// advanced, and never deleted — it just waits.
    var isEnabled: Bool
    /// Set when a one-shot has fired (or was hopelessly missed). Only completed
    /// schedules may be pruned; a user-paused schedule is NOT completed.
    var completed: Bool
    var options: PlaybackOptions

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        recordingName: String,
        fireDate: Date,
        repeatRule: RepeatRule = .once,
        isEnabled: Bool = true,
        options: PlaybackOptions = .default
    ) {
        self.id = id
        self.recordingID = recordingID
        self.recordingName = recordingName
        self.fireDate = fireDate
        self.repeatRule = repeatRule
        self.isEnabled = isEnabled
        self.completed = false
        self.options = options
    }

    /// Tolerant decoding: `completed` was added after 1.0 files existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.recordingID = try c.decode(UUID.self, forKey: .recordingID)
        self.recordingName = try c.decode(String.self, forKey: .recordingName)
        self.fireDate = try c.decode(Date.self, forKey: .fireDate)
        self.repeatRule = try c.decode(RepeatRule.self, forKey: .repeatRule)
        self.isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        self.completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        self.options = try c.decode(PlaybackOptions.self, forKey: .options)
    }

    /// True if this schedule is due to fire at or before `now`.
    func isDue(now: Date = Date()) -> Bool {
        isEnabled && !completed && fireDate <= now
    }

    /// Move past an occurrence: repeaters advance from the SCHEDULED time
    /// (stepping until strictly in the future so a daily 9:00 stays at 9:00
    /// instead of drifting to when the timer happened to tick); one-shots are
    /// marked completed.
    mutating func advance(now: Date = Date()) {
        if repeatRule == .once {
            completed = true
            return
        }
        guard fireDate <= now else { return }

        let calendar = Calendar.current
        let component: Calendar.Component
        let nominal: TimeInterval
        switch repeatRule {
        case .once: return
        case .hourly: (component, nominal) = (.hour, 3600)
        case .daily: (component, nominal) = (.day, 86400)
        case .weekly: (component, nominal) = (.weekOfYear, 7 * 86400)
        }

        // Jump most of the gap in one arithmetic step, then correct for
        // DST / month-length drift with a small bounded loop — so a fire date
        // far in the past can never spin the timer in an unbounded loop.
        let gap = now.timeIntervalSince(fireDate)
        let bulk = gap.isFinite ? max(0, Int(min(gap / nominal, 1e8))) : 0
        var next = calendar.date(byAdding: component, value: bulk, to: fireDate) ?? fireDate
        var steps = 0
        while next <= now, steps < 1000 {
            guard let stepped = calendar.date(byAdding: component, value: 1, to: next) else { break }
            next = stepped
            steps += 1
        }
        fireDate = next
    }
}

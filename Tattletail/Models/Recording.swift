import Foundation

/// The current on-disk schema version for a `Recording`. Bump when the shape
/// of `RecordedEvent` changes in a way that needs migration.
let kRecordingSchemaVersion = 1

/// A named, replayable timeline of captured input.
struct Recording: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
    var events: [RecordedEvent]

    // Cached, recomputed on save so the library can render without loading events.
    var duration: TimeInterval
    var eventCount: Int
    /// Resettable play-through counter (each pass of a repeat/loop counts,
    /// including scheduled and countdown runs). Cleared by "Reset Run Count".
    var runCount: Int
    /// Lifetime play-through total since the recording was created. Counts the
    /// same events as `runCount` but is NEVER reset — the full history.
    var totalRuns: Int
    /// Per-recording replay settings (speed, repeat count, loop). Stored here so
    /// each recording remembers its own choices instead of sharing one global set.
    var playbackOptions: PlaybackOptions
    /// Snapshot of the display arrangement when captured (see `DisplayLayout`).
    /// Absolute coordinates only line up if the screens still match; a mismatch
    /// at replay time is worth warning about. Nil for older files / blank ones.
    var displaySignature: String?
    /// The folder this recording belongs to, or nil for "Unfiled".
    var folderID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        events: [RecordedEvent]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.schemaVersion = kRecordingSchemaVersion
        self.events = events
        self.duration = events.last?.offset ?? 0
        self.eventCount = events.count
        self.runCount = 0
        self.totalRuns = 0
        self.playbackOptions = .default
        self.displaySignature = nil
        self.folderID = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, schemaVersion, events, duration, eventCount, runCount, totalRuns, playbackOptions, displaySignature, folderID
    }

    /// Tolerant decoding: `runCount` was added after 1.1 files existed,
    /// `totalRuns` after 1.2 (an older file's existing `runCount` seeds the
    /// lifetime total so no prior history is thrown away), and `playbackOptions`
    /// after 1.6 (older files fall back to the defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.events = try c.decode([RecordedEvent].self, forKey: .events)
        let rawDuration = try c.decode(TimeInterval.self, forKey: .duration)
        self.duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        self.eventCount = try c.decode(Int.self, forKey: .eventCount)
        self.runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.totalRuns = try c.decodeIfPresent(Int.self, forKey: .totalRuns) ?? self.runCount
        self.playbackOptions = try c.decodeIfPresent(PlaybackOptions.self, forKey: .playbackOptions) ?? .default
        self.displaySignature = try c.decodeIfPresent(String.self, forKey: .displaySignature)
        self.folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }

    /// Refresh cached metadata and the modified timestamp. Call before saving.
    mutating func touch(now: Date = Date()) {
        duration = events.last?.offset ?? 0
        eventCount = events.count
        updatedAt = now
    }

    /// Recompute each event's `offset` as the running sum of `delay`s, so the
    /// displayed timeline stays consistent after inserts, edits, and reorders.
    /// `delay` (gap-before-this-step) is the source of truth; `offset` is derived.
    mutating func recomputeTiming() {
        var t: TimeInterval = 0
        for i in events.indices {
            t += max(events[i].delay, 0)
            events[i].offset = t
        }
        duration = events.last?.offset ?? 0
        eventCount = events.count
    }

    /// Bring a decoded recording up to the current schema. Every change so far
    /// has been an additive, tolerantly-decoded field, so there's nothing to
    /// transform yet — this is the seam where future migrations go, switching on
    /// the stored `schemaVersion`. The bumped version persists on the next save.
    func migrated() -> Recording {
        guard schemaVersion < kRecordingSchemaVersion else { return self }
        var r = self
        // switch on r.schemaVersion here to transform older field shapes…
        r.schemaVersion = kRecordingSchemaVersion
        return r
    }

    // `imported()` lives in the paid-only `Recording+Import.swift` (Import/Export
    // is a paid feature). `folderID` above stays a shared field so recordings are
    // JSON-compatible across the free and paid editions.

    /// A lightweight summary for the library index and sidebar.
    var summary: RecordingSummary {
        RecordingSummary(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            duration: duration,
            eventCount: eventCount,
            appActivationCount: events.filter { $0.kind == .appActivate }.count,
            runCount: runCount,
            totalRuns: totalRuns,
            folderID: folderID
        )
    }

    /// A one-line breakdown like "134 moves · 12 clicks · 3 apps" for detail views.
    var breakdown: String {
        var moves = 0, clicks = 0, keys = 0, scrolls = 0, apps = 0
        for e in events {
            switch e.kind {
            case .mouseMove: moves += 1
            case .mouseDown: clicks += 1
            case .scroll: scrolls += 1
            case .keyDown: keys += 1
            case .appActivate: apps += 1
            default: break
            }
        }
        var parts: [String] = []
        if moves > 0 { parts.append("\(moves) moves") }
        if clicks > 0 { parts.append("\(clicks) clicks") }
        if keys > 0 { parts.append("\(keys) keys") }
        if scrolls > 0 { parts.append("\(scrolls) scrolls") }
        if apps > 0 { parts.append("\(apps) apps") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

/// Minimal metadata used to render the library list quickly.
struct RecordingSummary: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    var eventCount: Int
    var appActivationCount: Int
    var runCount: Int
    var totalRuns: Int
    var folderID: UUID?

    init(id: UUID, name: String, createdAt: Date, updatedAt: Date,
         duration: TimeInterval, eventCount: Int, appActivationCount: Int,
         runCount: Int, totalRuns: Int, folderID: UUID? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.eventCount = eventCount
        self.appActivationCount = appActivationCount
        self.runCount = runCount
        self.totalRuns = totalRuns
        self.folderID = folderID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, duration, eventCount, appActivationCount, runCount, totalRuns, folderID
    }

    /// Tolerant decoding so an older `library.json` (no `runCount`/`totalRuns`)
    /// still loads without forcing a full index rebuild; `totalRuns` seeds from
    /// `runCount` when absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        let rawDuration = try c.decode(TimeInterval.self, forKey: .duration)
        self.duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        self.eventCount = try c.decode(Int.self, forKey: .eventCount)
        self.appActivationCount = try c.decode(Int.self, forKey: .appActivationCount)
        self.runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.totalRuns = try c.decodeIfPresent(Int.self, forKey: .totalRuns) ?? self.runCount
        self.folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }
}

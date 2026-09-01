import XCTest
@testable import Tattletail

final class RecordingModelTests: XCTestCase {

    func testRecordedEventCodableRoundTrip() throws {
        var event = RecordedEvent.mouseButton(
            down: true, x: 100.5, y: 200.25, button: 0, clickCount: 2,
            offset: 1.5, delay: 0.05)
        event.characters = nil

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: data)

        XCTAssertEqual(decoded.kind, .mouseDown)
        XCTAssertEqual(decoded.x, 100.5)
        XCTAssertEqual(decoded.y, 200.25)
        XCTAssertEqual(decoded.button, 0)
        XCTAssertEqual(decoded.clickCount, 2)
        XCTAssertEqual(decoded.offset, 1.5)
        XCTAssertEqual(decoded.delay, 0.05)
    }

    func testRecordingCodableRoundTripPreservesEvents() throws {
        let events: [RecordedEvent] = [
            .appActivate(bundleId: "com.apple.TextEdit", appPath: "/System/Applications/TextEdit.app",
                         appName: "TextEdit", offset: 0, delay: 0),
            .mouseMove(x: 10, y: 20, button: nil, offset: 0.1, delay: 0.1),
            .key(down: true, keyCode: 0, flags: 0, isRepeat: false, characters: "a",
                 offset: 0.5, delay: 0.4),
            .key(down: false, keyCode: 0, flags: 0, isRepeat: false, characters: "a",
                 offset: 0.6, delay: 0.1),
        ]
        let recording = Recording(name: "Test", events: events)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(recording)
        let decoded = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(decoded.name, "Test")
        XCTAssertEqual(decoded.events.count, 4)
        XCTAssertEqual(decoded.events[0].kind, .appActivate)
        XCTAssertEqual(decoded.events[0].bundleId, "com.apple.TextEdit")
        XCTAssertEqual(decoded.events[2].characters, "a")
        XCTAssertEqual(decoded.duration, 0.6)
        XCTAssertEqual(decoded.eventCount, 4)
    }

    func testMissingEventIDToleratedOnDecode() throws {
        let json = """
        {"kind":"mouseMove","offset":0.5,"delay":0.1,"x":1,"y":2}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: json)
        XCTAssertEqual(decoded.kind, .mouseMove)
        XCTAssertEqual(decoded.offset, 0.5)
    }

    func testRecordingTouchRecomputesMetadata() {
        var recording = Recording(name: "T", events: [
            .mouseMove(x: 0, y: 0, button: nil, offset: 0.2, delay: 0.2),
        ])
        recording.events.append(.mouseMove(x: 5, y: 5, button: nil, offset: 3.0, delay: 2.8))
        recording.touch()
        XCTAssertEqual(recording.duration, 3.0)
        XCTAssertEqual(recording.eventCount, 2)
    }
}

final class ScheduleTests: XCTestCase {

    func testOneShotCompletesAfterAdvance() {
        var schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: Date(timeIntervalSinceNow: -10), repeatRule: .once)
        XCTAssertTrue(schedule.isDue())
        schedule.advance()
        XCTAssertTrue(schedule.completed)
        XCTAssertFalse(schedule.isDue(), "completed one-shot must never fire again")
    }

    func testDailyScheduleAdvancesOneDay() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: start, repeatRule: .daily)
        schedule.advance(now: start)
        XCTAssertTrue(schedule.isEnabled)
        XCTAssertFalse(schedule.completed)
        XCTAssertEqual(
            schedule.fireDate.timeIntervalSince(start), 86_400, accuracy: 3_700,
            "daily advance should be ~1 day (allowing DST wiggle)")
    }

    func testRepeaterAdvancesFromScheduledTimeNotTickTime() {
        // Fired 25 hours late: the next occurrence must land on the original
        // cadence (2 days after the scheduled time), not tick-time + 1 day.
        let scheduled = Date(timeIntervalSince1970: 1_700_000_000)
        let lateTick = scheduled.addingTimeInterval(25 * 3600)
        var schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: scheduled, repeatRule: .daily)
        schedule.advance(now: lateTick)
        XCTAssertGreaterThan(schedule.fireDate, lateTick)
        let drift = schedule.fireDate.timeIntervalSince(scheduled)
            .truncatingRemainder(dividingBy: 86_400)
        XCTAssertEqual(min(drift, 86_400 - drift), 0, accuracy: 3_700,
                       "cadence must stay anchored to the scheduled time")
    }

    func testPausedScheduleIsNeverDueAndNeverCompleted() {
        var schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: Date(timeIntervalSinceNow: -86_400), repeatRule: .daily)
        schedule.isEnabled = false
        XCTAssertFalse(schedule.isDue())
        XCTAssertFalse(schedule.completed,
                       "a paused schedule must not be prunable as completed")
    }

    func testScheduleDecodesWithoutCompletedField() throws {
        // Pre-1.1 schedules.json has no `completed` key — must decode as false.
        var schedule = Schedule(recordingID: UUID(), recordingName: "Old",
                                fireDate: Date(timeIntervalSinceNow: 60))
        schedule.completed = true
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(
            with: encoder.encode(schedule)) as! [String: Any]
        json.removeValue(forKey: "completed")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Schedule.self, from: stripped)
        XCTAssertFalse(decoded.completed)
    }

    func testDisabledScheduleNeverDue() {
        var schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: Date(timeIntervalSinceNow: -10))
        schedule.isEnabled = false
        XCTAssertFalse(schedule.isDue())
    }

    func testFutureScheduleNotDue() {
        let schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: Date(timeIntervalSinceNow: 60))
        XCTAssertFalse(schedule.isDue())
    }
}

final class PlaybackMathTests: XCTestCase {

    func testSpeedScalingHalvesDelaysAtDoubleSpeed() {
        let recordedDelay = 0.5
        let speed = 2.0
        let scaled = max(recordedDelay / speed, PlaybackOptions.minimumInterEventDelay)
        XCTAssertEqual(scaled, 0.25, accuracy: 0.0001)
    }

    func testSpeedScalingClampsToMinimumDelay() {
        let recordedDelay = 0.0001
        let speed = 4.0
        let scaled = max(recordedDelay / speed, PlaybackOptions.minimumInterEventDelay)
        XCTAssertEqual(scaled, PlaybackOptions.minimumInterEventDelay)
    }

    func testNanosToMachTimeIsMonotonicScale()  {
        let a = nanosToMachTime(1_000_000)
        let b = nanosToMachTime(2_000_000)
        XCTAssertGreaterThan(b, a)
        XCTAssertEqual(Double(b) / Double(a), 2.0, accuracy: 0.01)
    }

    func testRepeatCountClampsToAtLeastOne() {
        let options = PlaybackOptions(speed: 1, repeatCount: 0)
        XCTAssertEqual(options.repeatCount, 1)
    }
}

final class TimelineEditingTests: XCTestCase {

    private func move(_ x: Double, _ delay: TimeInterval) -> RecordedEvent {
        .mouseMove(x: x, y: x, button: nil, offset: 0, delay: delay)
    }
    private func click(_ delay: TimeInterval) -> RecordedEvent {
        .mouseButton(down: true, x: 5, y: 5, button: 0, clickCount: 1, offset: 0, delay: delay)
    }

    func testEnabledDefaultsTrueWhenMissingFromJSON() throws {
        let e = move(1, 0.1)
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(e)) as! [String: Any]
        json.removeValue(forKey: "enabled")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: stripped)
        XCTAssertTrue(decoded.enabled)
    }

    func testEnabledRoundTrips() throws {
        var e = click(0.2)
        e.enabled = false
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertFalse(decoded.enabled)
    }

    func testRecomputeTimingSumsDelaysIntoOffsets() {
        var rec = Recording(name: "R", events: [click(0), click(0.5), click(1.0), click(0.25)])
        rec.recomputeTiming()
        XCTAssertEqual(rec.events.map(\.offset), [0, 0.5, 1.5, 1.75])
        XCTAssertEqual(rec.duration, 1.75, accuracy: 1e-9)
        XCTAssertEqual(rec.eventCount, 4)
    }

    func testBuildTimelineItemsGroupsConsecutiveMoves() {
        let events = [click(0), move(1, 0.01), move(2, 0.01), move(3, 0.01), click(0.2), move(4, 0.01)]
        let items = buildTimelineItems(events)
        // click, [3-move block], click, [lone move as its own step]
        XCTAssertEqual(items.count, 4)
        XCTAssertFalse(items[0].isBlock)
        XCTAssertTrue(items[1].isBlock)
        XCTAssertEqual(items[1].events.count, 3)
        XCTAssertFalse(items[2].isBlock)
        XCTAssertFalse(items[3].isBlock, "a lone move is a step, not a block")
    }

    func testTimelineItemsFlattenBackToOriginalOrder() {
        let events = [click(0), move(1, 0.01), move(2, 0.01), click(0.2)]
        let flattened = buildTimelineItems(events).flatMap { $0.events }
        XCTAssertEqual(flattened.map(\.id), events.map(\.id),
                       "reorder relies on lossless flatten of items back to events")
    }

    func testTypeTextStepRoundTripsAndSummarizes() throws {
        let e = RecordedEvent.typeText("hello\nworld", offset: 1, delay: 0.2)
        XCTAssertEqual(e.kind, .typeText)
        XCTAssertEqual(e.characters, "hello\nworld")
        XCTAssertFalse(e.isLowLevel)
        XCTAssertTrue(e.summary.hasPrefix("Type"))
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded.kind, .typeText)
        XCTAssertEqual(decoded.characters, "hello\nworld")
        XCTAssertEqual(decoded.delay, 0.2)
    }

    func testPlaybackOptionsRoundTripPerRecording() throws {
        var rec = Recording(name: "R", events: [])
        rec.playbackOptions = PlaybackOptions(speed: 2.0, repeatCount: 5, loops: true)
        let decoded = try JSONDecoder().decode(
            Recording.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.playbackOptions.speed, 2.0)
        XCTAssertEqual(decoded.playbackOptions.repeatCount, 5)
        XCTAssertTrue(decoded.playbackOptions.loops)
    }

    // testImportedCopyResetsIdentityAndCounts moved to PaidFeatureTests.swift
    // (Import/Export is paid-only).

    func testDisplaySignatureRoundTripsAndDefaultsNil() throws {
        var rec = Recording(name: "R", events: [])
        XCTAssertNil(rec.displaySignature)
        rec.displaySignature = "0,0,1920x1080|1920,0,1440x900"
        let decoded = try JSONDecoder().decode(
            Recording.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.displaySignature, "0,0,1920x1080|1920,0,1440x900")
    }

    func testPlaybackOptionsNewFlagsRoundTrip() throws {
        let o = PlaybackOptions(speed: 3.0, repeatCount: 2, loops: false,
                                jumpInstantly: true, humanize: true)
        let decoded = try JSONDecoder().decode(PlaybackOptions.self, from: JSONEncoder().encode(o))
        XCTAssertTrue(decoded.jumpInstantly)
        XCTAssertTrue(decoded.humanize)
        XCTAssertEqual(decoded.speed, 3.0)
    }

    func testPlaybackOptionsToleratesMissingNewFlags() throws {
        // A pre-1.11 options blob has no jumpInstantly / humanize keys.
        let json = "{\"speed\":2,\"repeatCount\":3,\"loops\":true}"
        let decoded = try JSONDecoder().decode(PlaybackOptions.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.speed, 2)
        XCTAssertEqual(decoded.repeatCount, 3)
        XCTAssertTrue(decoded.loops)
        XCTAssertFalse(decoded.jumpInstantly)
        XCTAssertFalse(decoded.humanize)
    }

    func testWindowAnchorRoundTripsAndPreservesAbsoluteFallback() throws {
        var e = RecordedEvent.mouseButton(down: true, x: 100, y: 200, button: 0,
                                          clickCount: 1, offset: 0, delay: 0.1)
        XCTAssertFalse(e.hasWindowAnchor)
        e.windowBundleId = "com.apple.Safari"
        e.windowTitle = "Start Page"
        e.windowOffsetX = 40; e.windowOffsetY = 60
        e.windowWidth = 800; e.windowHeight = 600
        XCTAssertTrue(e.hasWindowAnchor)
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded.windowBundleId, "com.apple.Safari")
        XCTAssertEqual(decoded.windowTitle, "Start Page")
        XCTAssertEqual(decoded.windowOffsetX, 40)
        XCTAssertEqual(decoded.windowOffsetY, 60)
        XCTAssertTrue(decoded.hasWindowAnchor)
        XCTAssertEqual(decoded.x, 100)   // absolute fallback preserved
        XCTAssertEqual(decoded.y, 200)
    }

    func testWindowAnchorAbsentDecodesWithoutAnchor() throws {
        let e = RecordedEvent.mouseButton(down: true, x: 5, y: 6, button: 0,
                                          clickCount: 1, offset: 0, delay: 0)
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertFalse(decoded.hasWindowAnchor)
    }

    func testDecodeClampsNegativeTimingToZero() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"kind\":\"delay\",\"offset\":-5,\"delay\":-2}"
        let e = try JSONDecoder().decode(RecordedEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.offset, 0)
        XCTAssertEqual(e.delay, 0)
    }

    func testDecodeClampsNegativeDurationToZero() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"R","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","schemaVersion":1,"events":[],
         "duration":-10,"eventCount":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let r = try decoder.decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(r.duration, 0)
    }

    func testPasteTextStepRoundTripsAndSummarizes() throws {
        let e = RecordedEvent.pasteText("hello\nworld", offset: 1, delay: 0.2)
        XCTAssertEqual(e.kind, .pasteText)
        XCTAssertEqual(e.characters, "hello\nworld")
        XCTAssertTrue(e.summary.hasPrefix("Paste"))
        let decoded = try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded.kind, .pasteText)
        XCTAssertEqual(decoded.characters, "hello\nworld")
    }

    func testPlaybackOptionsDefaultWhenMissingFromJSON() throws {
        // A pre-1.6 recording file has no `playbackOptions` key.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","schemaVersion":1,"events":[],
         "duration":0,"eventCount":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.playbackOptions, .default)
    }

    func testBlockEnabledReflectsAnyEnabledChild() {
        var m1 = move(1, 0.01); var m2 = move(2, 0.01)
        m1.enabled = false; m2.enabled = false
        let block = TimelineItem(id: m1.id, events: [m1, m2], kind: .lowLevelBlock)
        XCTAssertFalse(block.isEnabled)
        m2.enabled = true
        XCTAssertTrue(TimelineItem(id: m1.id, events: [m1, m2], kind: .lowLevelBlock).isEnabled)
    }

    func testManualGroupCollapsesConsecutiveSteps() {
        let gid = UUID()
        var a = RecordedEvent.delayStep(0.2, offset: 0)
        var b = RecordedEvent.typeText("hi", offset: 0, delay: 0.1)
        let c = RecordedEvent.delayStep(0.3, offset: 0)   // ungrouped, standalone
        a.groupID = gid; b.groupID = gid
        let items = buildTimelineItems([a, b, c])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].groupID, gid)
        XCTAssertEqual(items[0].events.count, 2)
        XCTAssertTrue(items[0].isBlock)
        XCTAssertFalse(items[1].isBlock)
    }

    func testStepNameAndGroupFieldsRoundTrip() throws {
        var e = RecordedEvent.delayStep(0.5, offset: 0)
        e.name = "Let page load"
        e.groupID = UUID(); e.groupName = "Setup"
        let decoded = try JSONDecoder().decode(
            RecordedEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(decoded.name, "Let page load")
        XCTAssertEqual(decoded.groupID, e.groupID)
        XCTAssertEqual(decoded.groupName, "Setup")
    }
}

@MainActor
final class PairedPartnerSyncTests: XCTestCase {

    private func down(_ button: Int) -> RecordedEvent {
        .mouseButton(down: true, x: 10, y: 10, button: button, clickCount: 1, offset: 0, delay: 0.1)
    }
    private func up(_ button: Int) -> RecordedEvent {
        .mouseButton(down: false, x: 10, y: 10, button: button, clickCount: 1, offset: 0, delay: 0.05)
    }

    func testEditingClickDownRetargetsItsUp() {
        let d = down(0), u = up(0)
        var edited = d
        edited.button = 1; edited.x = 99; edited.y = 88
        // Mirror real usage: the edited event is already written into the array.
        let result = AppModel.syncingPairedPartner([edited, u], editedID: d.id, previous: d)
        // The up partner now matches the new button and position.
        XCTAssertEqual(result[1].button, 1)
        XCTAssertEqual(result[1].x, 99)
        XCTAssertEqual(result[1].y, 88)
    }

    func testEditingClickUpRetargetsItsDown() {
        let d = down(0), u = up(0)
        var edited = u
        edited.button = 2
        // Simulate the array already holding the edited up at index 1.
        let result = AppModel.syncingPairedPartner([d, edited], editedID: u.id, previous: u)
        XCTAssertEqual(result[0].button, 2, "the preceding down should follow the up's new button")
    }

    func testNonPairedNeighborIsLeftAlone() {
        // down(0) followed by an unrelated up(1) — not a matching pair.
        let d = down(0), other = up(1)
        var edited = d
        edited.button = 2
        let result = AppModel.syncingPairedPartner([edited, other], editedID: d.id, previous: d)
        XCTAssertEqual(result[1].button, 1, "an unrelated neighbor must not be rewritten")
    }

    func testKeyPairStaysInSync() {
        let kd = RecordedEvent.key(down: true, keyCode: 4, flags: 0, isRepeat: false,
                                   characters: "h", offset: 0, delay: 0.1)
        let ku = RecordedEvent.key(down: false, keyCode: 4, flags: 0, isRepeat: false,
                                   characters: "h", offset: 0, delay: 0.03)
        var edited = kd
        edited.keyCode = 5; edited.characters = "g"
        let result = AppModel.syncingPairedPartner([edited, ku], editedID: kd.id, previous: kd)
        XCTAssertEqual(result[1].keyCode, 5)
        XCTAssertEqual(result[1].characters, "g")
    }
}

final class RunCounterTests: XCTestCase {

    func testRunCountDefaultsToZeroWhenMissing() throws {
        var rec = Recording(name: "R", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0, delay: 0)])
        rec.runCount = 7
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(rec)) as! [String: Any]
        json.removeValue(forKey: "runCount")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: stripped)
        XCTAssertEqual(decoded.runCount, 0)
    }

    func testRunCountRoundTrips() throws {
        var rec = Recording(name: "R", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0, delay: 0)])
        rec.runCount = 42
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: encoder.encode(rec))
        XCTAssertEqual(decoded.runCount, 42)
    }

    func testSummaryDecodesWithoutRunCount() throws {
        let summary = RecordingSummary(
            id: UUID(), name: "R", createdAt: Date(), updatedAt: Date(),
            duration: 1, eventCount: 1, appActivationCount: 0, runCount: 3, totalRuns: 3)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(summary)) as! [String: Any]
        json.removeValue(forKey: "runCount")
        json.removeValue(forKey: "totalRuns")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingSummary.self, from: stripped)
        XCTAssertEqual(decoded.runCount, 0)
        XCTAssertEqual(decoded.totalRuns, 0)
    }

    private func encoderISO() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private func decoderISO() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    func testTotalRunsBackfillsFromRunCountWhenAbsent() throws {
        // A 1.2-era file has runCount but no totalRuns — the lifetime total
        // must seed from the existing runCount so prior history isn't lost.
        var rec = Recording(name: "R", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0, delay: 0)])
        rec.runCount = 9; rec.totalRuns = 9
        var json = try JSONSerialization.jsonObject(with: encoderISO().encode(rec)) as! [String: Any]
        json.removeValue(forKey: "totalRuns")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decoderISO().decode(Recording.self, from: stripped)
        XCTAssertEqual(decoded.totalRuns, 9, "totalRuns should seed from runCount")
        XCTAssertEqual(decoded.runCount, 9)
    }

    func testTotalRunsDefaultsZeroWhenNeitherPresent() throws {
        var rec = Recording(name: "R", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0, delay: 0)])
        rec.runCount = 4; rec.totalRuns = 4
        var json = try JSONSerialization.jsonObject(with: encoderISO().encode(rec)) as! [String: Any]
        json.removeValue(forKey: "runCount")
        json.removeValue(forKey: "totalRuns")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decoderISO().decode(Recording.self, from: stripped)
        XCTAssertEqual(decoded.totalRuns, 0)
        XCTAssertEqual(decoded.runCount, 0)
    }

    func testRunCountAndTotalRunsRoundTripIndependently() throws {
        var rec = Recording(name: "R", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0, delay: 0)])
        rec.runCount = 2       // after a reset
        rec.totalRuns = 37     // lifetime unaffected by the reset
        let decoded = try decoderISO().decode(Recording.self, from: encoderISO().encode(rec))
        XCTAssertEqual(decoded.runCount, 2)
        XCTAssertEqual(decoded.totalRuns, 37)
    }
}

final class ChordStrippingTests: XCTestCase {
    // kVK_ANSI_E = 14, kVK_Command = 55 (as flagsChanged), kVK_Option = 58

    private func click(_ offset: TimeInterval) -> RecordedEvent {
        .mouseButton(down: true, x: 5, y: 5, button: 0, clickCount: 1,
                     offset: offset, delay: 0.1)
    }

    func testStripsHotkeyChordFromTail() {
        let events: [RecordedEvent] = [
            click(0.5),
            .flagsChanged(keyCode: 55, flags: 0x100000, offset: 2.0, delay: 1.5),  // cmd down
            .flagsChanged(keyCode: 58, flags: 0x180000, offset: 2.1, delay: 0.1),  // opt down
            .key(down: true, keyCode: 14, flags: 0x180000, isRepeat: false,
                 characters: nil, offset: 2.2, delay: 0.1),                        // E down
        ]
        let stripped = EventCaptureEngine.strippingTrailingChord(from: events, keyCode: 14)
        XCTAssertEqual(stripped.count, 1)
        XCTAssertEqual(stripped[0].kind, .mouseDown)
    }

    func testStopsAtFirstUnrelatedEvent() {
        let events: [RecordedEvent] = [
            .key(down: true, keyCode: 0, flags: 0, isRepeat: false,
                 characters: "a", offset: 0.5, delay: 0.5),   // real typing survives
            .flagsChanged(keyCode: 55, flags: 0x100000, offset: 2.0, delay: 1.5),
            .key(down: true, keyCode: 14, flags: 0x100000, isRepeat: false,
                 characters: nil, offset: 2.1, delay: 0.1),
        ]
        let stripped = EventCaptureEngine.strippingTrailingChord(from: events, keyCode: 14)
        XCTAssertEqual(stripped.count, 1)
        XCTAssertEqual(stripped[0].characters, "a")
    }

    func testDoesNotStripUnrelatedKeyAtTail() {
        let events: [RecordedEvent] = [
            click(0.5),
            .key(down: true, keyCode: 0, flags: 0, isRepeat: false,
                 characters: "a", offset: 1.0, delay: 0.5),
        ]
        let stripped = EventCaptureEngine.strippingTrailingChord(from: events, keyCode: 14)
        XCTAssertEqual(stripped.count, 2)
    }

    func testStripLimitBoundsRemoval() {
        var events: [RecordedEvent] = [click(0.1)]
        for i in 0..<20 {
            events.append(.flagsChanged(keyCode: 55, flags: 0,
                                        offset: 0.2 + Double(i) * 0.01, delay: 0.01))
        }
        let stripped = EventCaptureEngine.strippingTrailingChord(
            from: events, keyCode: 14, limit: 8)
        XCTAssertEqual(stripped.count, events.count - 8)
    }

    func testEmptyTimelineSafe() {
        XCTAssertTrue(EventCaptureEngine.strippingTrailingChord(from: [], keyCode: 14).isEmpty)
    }
}

final class HotKeyPreferenceTests: XCTestCase {

    func testDisplayStringRendersModifiersAndKey() {
        // cmdKey = 0x100, optionKey = 0x800 (Carbon); kVK_ANSI_E = 14
        let pref = HotKeyPreference(keyCode: 14, modifiers: 0x100 | 0x800)
        XCTAssertEqual(pref.displayString, "⌥⌘E")
    }

    func testDefaultsExistForAllActions() {
        for action in HotKeyAction.allCases {
            XCTAssertNotNil(HotKeyPreference.defaults[action])
        }
    }

    func testCodableRoundTrip() throws {
        let pref = HotKeyPreference(keyCode: 46, modifiers: 0x900)
        let data = try JSONEncoder().encode(pref)
        let decoded = try JSONDecoder().decode(HotKeyPreference.self, from: data)
        XCTAssertEqual(decoded, pref)
    }
}

final class ModifierMappingTests: XCTestCase {

    func testShiftDownDetected() {
        // kVK_Shift = 56; maskShift bit set means the key went down.
        XCTAssertTrue(EventSynthesizer.isModifierDown(
            keyCode: 56, flags: CGEventFlags.maskShift))
        XCTAssertFalse(EventSynthesizer.isModifierDown(
            keyCode: 56, flags: []))
    }

    func testCommandDownDetected() {
        // kVK_Command = 55
        XCTAssertTrue(EventSynthesizer.isModifierDown(
            keyCode: 55, flags: CGEventFlags.maskCommand))
        XCTAssertFalse(EventSynthesizer.isModifierDown(
            keyCode: 55, flags: CGEventFlags.maskShift))
    }
}

final class RecordingStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TattletailTests-\(UUID().uuidString)")
        store = RecordingStore(rootURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveLoadRoundTrip() throws {
        let recording = Recording(name: "Round trip", events: [
            .mouseMove(x: 1, y: 2, button: nil, offset: 0.1, delay: 0.1),
        ])
        try store.save(recording)
        let loaded = try store.load(id: recording.id)
        XCTAssertEqual(loaded.name, "Round trip")
        XCTAssertEqual(loaded.events.count, 1)
    }

    func testListSummariesReflectsSaves() throws {
        try store.save(Recording(name: "One", events: []))
        try store.save(Recording(name: "Two", events: []))
        let names = Set(store.listSummaries().map(\.name))
        XCTAssertEqual(names, ["One", "Two"])
    }

    func testSavedRecordingIsOwnerOnlyReadable() throws {
        let recording = Recording(name: "Secret", events: [
            .key(down: true, keyCode: 4, flags: 0, isRepeat: false,
                 characters: "hunter2", offset: 0, delay: 0.1),
        ])
        try store.save(recording)
        let url = store.recordingsURL.appendingPathComponent("\(recording.id.uuidString).json")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.int16Value, 0o600,
                       "recordings can contain typed text and must be owner-only")
    }

    func testDeleteRemovesFromIndexAndDisk() throws {
        let recording = Recording(name: "Doomed", events: [])
        try store.save(recording)
        try store.delete(id: recording.id)
        XCTAssertTrue(store.listSummaries().isEmpty)
        XCTAssertThrowsError(try store.load(id: recording.id))
    }

    func testDuplicateCreatesDistinctCopy() throws {
        var original = Recording(name: "Original", events: [
            .mouseMove(x: 1, y: 1, button: nil, offset: 0.1, delay: 0.1),
        ])
        original.playbackOptions = PlaybackOptions(speed: 4.0, repeatCount: 3, loops: true)
        try store.save(original)
        let copy = try store.duplicate(id: original.id)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Original copy")
        XCTAssertEqual(copy.events.count, 1)
        XCTAssertEqual(copy.playbackOptions, original.playbackOptions)
        XCTAssertEqual(store.listSummaries().count, 2)
    }

    // testFoldersPersistence / testEmptyFoldersLoadAsEmpty moved to
    // PaidFeatureTests.swift (Folders are paid-only). The folderID data field
    // stays shared, so its round-trip test below remains here.

    func testRecordingFolderIDRoundTripsAndSummary() throws {
        let fid = UUID()
        var rec = Recording(name: "R", events: [])
        rec.folderID = fid
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.folderID, fid)
        XCTAssertEqual(decoded.summary.folderID, fid)
    }

    // testRunHistoryPersistence / testEmptyHistoryLoadsAsEmpty moved to
    // PaidFeatureTests.swift (run History is paid-only). Schedules persistence
    // stays below — scheduling is a free feature.

    func testSchedulePersistence() throws {
        let schedule = Schedule(
            recordingID: UUID(), recordingName: "R",
            fireDate: Date(timeIntervalSinceNow: 3600))
        try store.saveSchedules([schedule])
        let loaded = store.loadSchedules()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, schedule.id)
        XCTAssertEqual(loaded[0].recordingName, "R")
    }

    func testReconcileIndexPicksUpUntrackedRecordingFile() throws {
        let a = Recording(name: "A", events: [])
        try store.save(a)   // index knows about A only
        // Write B's file directly, bypassing save() so the index is out of sync.
        let b = Recording(name: "B", events: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = store.recordingsURL.appendingPathComponent("\(b.id.uuidString).json")
        try encoder.encode(b).write(to: url)
        XCTAssertEqual(store.listSummaries().count, 1)
        store.reconcileIndexIfNeeded()
        XCTAssertEqual(Set(store.listSummaries().map(\.name)), ["A", "B"])
    }

    func testMigrationStampsCurrentSchemaVersion() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","schemaVersion":0,"events":[],
         "duration":0,"eventCount":0}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let migrated = try decoder.decode(Recording.self, from: Data(json.utf8)).migrated()
        XCTAssertEqual(migrated.schemaVersion, kRecordingSchemaVersion)
    }

    func testIndexRebuildAfterIndexLoss() throws {
        let recording = Recording(name: "Survivor", events: [])
        try store.save(recording)
        // Simulate a lost index: delete library.json, keep the recording file.
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("library.json"))
        let summaries = store.listSummaries()
        XCTAssertEqual(summaries.map(\.name), ["Survivor"])
    }
}

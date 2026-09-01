import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Central app state: wires the capture/playback engines, store, scheduler,
/// permissions, and panic hotkey together, and exposes library state to views.
@MainActor
final class AppModel: ObservableObject {
    let store: RecordingStore
    let permissions: PermissionsManager
    let capture: EventCaptureEngine
    let playback: PlaybackEngine
    let scheduler: SchedulerService
    /// Screen-edge glow that signals Tattletail is recording/replaying.
    let glow = GlowOverlayController()

    private static let glowDefaultsKey = "showActivityGlow"
    /// User setting: whether to show the screen glow while active (default on).
    @Published var showActivityGlow: Bool {
        didSet {
            UserDefaults.standard.set(showActivityGlow, forKey: Self.glowDefaultsKey)
            refreshGlow()
        }
    }

    private static let windowRelativeKey = "useWindowRelative"
    /// User setting: capture window-relative anchors and re-aim replays at the
    /// target window's current position (default on). When off, Tattletail uses
    /// plain absolute screen coordinates, exactly as it did before.
    @Published var useWindowRelative: Bool {
        didSet {
            UserDefaults.standard.set(useWindowRelative, forKey: Self.windowRelativeKey)
            capture.windowRelativeEnabled = useWindowRelative
            playback.windowRelativeEnabled = useWindowRelative
        }
    }

    private static let hideOnRecordKey = "hideDuringRecording"
    /// User setting: hide Tattletail when recording starts (so you can work in
    /// other apps) and bring it back to the front when recording stops.
    @Published var hideDuringRecording: Bool {
        didSet { UserDefaults.standard.set(hideDuringRecording, forKey: Self.hideOnRecordKey) }
    }
    /// Tracks whether we hid the app for the current recording, so we only
    /// un-hide when we were the ones who hid it.
    private var didHideForRecording = false

    @Published var summaries: [RecordingSummary] = []
    #if !FREE_BUILD
    /// Folders for organizing recordings (a recording is in at most one). Paid —
    /// `folderID` on `Recording` stays a shared field for JSON compatibility.
    /// `var` (not `private(set)`) so `AppModel+Folders` (a separate paid file)
    /// can mutate it. History likewise for `AppModel+History`.
    @Published var folders: [Folder] = []
    /// Run history, newest first. One entry per replay session. Paid.
    @Published var history: [RunRecord] = []
    #endif
    @Published var selectedRecordingID: UUID?
    @Published var selectedRecording: Recording?
    /// Grouped timeline rows for the selected recording, recomputed only when the
    /// recording's events actually change — not on every view re-render or row
    /// selection — so large recordings stay smooth to scroll and select.
    @Published private(set) var selectedTimelineItems: [TimelineItem] = []
    @Published var lastError: String?
    /// True during the brief lead-in after the user starts recording, before
    /// capture actually begins — so the click/hotkey that started it isn't recorded.
    @Published private(set) var isArming = false

    /// How long to wait after "Start Recording" before capture actually begins.
    static let recordingLeadIn: TimeInterval = 1.0
    private var armingTask: Task<Void, Never>?

    private var hotKeys: [HotKeyAction: GlobalHotKey] = [:]
    /// Actions whose global hotkey failed to register — usually because another
    /// app already owns that chord. Surfaced in the UI so a dead panic key (a
    /// hard requirement) is never silent.
    @Published private(set) var hotKeyRegistrationFailed: Set<HotKeyAction> = []
    /// Bumped whenever a binding changes so views re-render hotkey labels.
    @Published private(set) var hotKeyRevision = 0
    /// Bumped when something (hotkey, menu) asks for the Schedule a Replay
    /// window. Observed by the always-alive menu bar label, which holds the
    /// `openWindow` environment needed to actually open it.
    @Published private(set) var scheduleWindowRequest = 0
    private var cancellables: Set<AnyCancellable> = []
    /// Run-count increments buffered during a replay session and flushed to disk
    /// once when it ends, so a loop/repeat doesn't rewrite the file every pass.
    /// Two buffers: the resettable `runCount` (dropped by a mid-session reset)
    /// and the permanent lifetime `totalRuns` (never dropped).
    /// `internal` (not `private`) so the paid `AppModel+History` extension can
    /// read the pending pass count when logging a run.
    var pendingRunIncrements: [UUID: Int] = [:]
    var pendingTotalIncrements: [UUID: Int] = [:]

    init() {
        let store = RecordingStore()
        let playback = PlaybackEngine()
        self.store = store
        self.playback = playback
        self.permissions = PermissionsManager()
        self.capture = EventCaptureEngine()
        self.scheduler = SchedulerService(store: store, playback: playback)
        self.showActivityGlow = (UserDefaults.standard.object(forKey: Self.glowDefaultsKey) as? Bool) ?? true
        self.hideDuringRecording = (UserDefaults.standard.object(forKey: Self.hideOnRecordKey) as? Bool) ?? true
        self.useWindowRelative = (UserDefaults.standard.object(forKey: Self.windowRelativeKey) as? Bool) ?? true
        // didSet doesn't run during init, so push the initial value to the engines.
        self.capture.windowRelativeEnabled = self.useWindowRelative
        self.playback.windowRelativeEnabled = self.useWindowRelative

        // Most views observe only AppModel (via .environmentObject), so changes
        // in the nested engines must be forwarded or those views never
        // re-render — the permissions gate would stay up after granting, and
        // the Record button would never flip to Stop. The same transitions also
        // drive the activity glow (refreshed async so we read post-change state).
        //
        // Permissions and the scheduler change infrequently, so forward them
        // wholesale. Capture and playback, however, publish high-frequency live
        // values (liveEventCount/liveDuration while recording, progress ~20×/sec
        // while replaying); forwarding those app-wide would re-render the entire
        // UI on every tick. Views that show the live values observe the engines
        // directly, so here we forward ONLY the coarse state transitions.
        for engine in [permissions.objectWillChange, scheduler.objectWillChange] {
            engine
                .sink { [weak self] _ in self?.forwardEngineChange() }
                .store(in: &cancellables)
        }
        capture.$isRecording.removeDuplicates()
            .sink { [weak self] _ in self?.forwardEngineChange() }.store(in: &cancellables)
        capture.$secureInputActive.removeDuplicates()
            .sink { [weak self] _ in self?.forwardEngineChange() }.store(in: &cancellables)
        playback.$phase.removeDuplicates()
            .sink { [weak self] _ in self?.forwardEngineChange() }.store(in: &cancellables)
        $isArming
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshGlow() } }
            .store(in: &cancellables)

        // Count every completed play-through toward the recording's run counter.
        playback.onPassCompleted = { [weak self] id in self?.notePassCompleted(id) }
        playback.onPlaybackEnded = { [weak self] in self?.handlePlaybackEnded() }

        store.reconcileIndexIfNeeded()
        reloadLibrary()
        #if !FREE_BUILD
        folders = store.loadFolders()
        reconcileFolderReferences()
        history = store.loadHistory()
        #endif
        reloadHotKeys()
        refreshGlow()
    }

    /// Republish an engine's coarse change to AppModel observers, and refresh
    /// the activity glow once the change has settled.
    private func forwardEngineChange() {
        objectWillChange.send()
        DispatchQueue.main.async { self.refreshGlow() }
    }

    // MARK: - Activity glow

    /// Update the screen glow to match the current state: amber while recording
    /// (or arming), red while replaying/counting down, off otherwise.
    private func refreshGlow() {
        guard showActivityGlow else { glow.setState(nil); return }
        if capture.isRecording || isArming {
            glow.setState(.recording)
        } else if playback.isBusy {
            glow.setState(.replaying)
        } else {
            glow.setState(nil)
        }
    }

    // MARK: - Hotkeys

    var panicHotKeyDisplay: String { hotKeyDisplay(.panicStop) }

    func hotKeyDisplay(_ action: HotKeyAction) -> String {
        HotKeyStore.load(action).displayString
    }

    func hotKeyPreference(_ action: HotKeyAction) -> HotKeyPreference {
        HotKeyStore.load(action)
    }

    func setHotKey(_ preference: HotKeyPreference, for action: HotKeyAction) {
        HotKeyStore.save(preference, for: action)
        reloadHotKeys()
    }

    func resetHotKeys() {
        HotKeyStore.resetAll()
        reloadHotKeys()
    }

    /// (Re)register all global hotkeys from stored preferences.
    private func reloadHotKeys() {
        for hotKey in hotKeys.values { hotKey.unregister() }
        hotKeys.removeAll()

        var failed: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            let pref = HotKeyStore.load(action)
            let hotKey = GlobalHotKey(preference: pref) { [weak self] in
                Task { @MainActor [weak self] in self?.perform(action) }
            }
            if hotKey.register() {
                hotKeys[action] = hotKey
            } else {
                failed.insert(action)
            }
        }
        hotKeyRegistrationFailed = failed
        hotKeyRevision += 1
    }

    /// Whether the panic-stop global hotkey is actually registered. When false,
    /// another app likely owns the chord; the Stop button and menu still work.
    var panicHotKeyRegistered: Bool { !hotKeyRegistrationFailed.contains(.panicStop) }

    /// Actions bound to the same chord as another action — a conflict where one
    /// of them silently won't register. Surfaced in Settings.
    var hotKeyConflicts: Set<HotKeyAction> {
        var byChord: [String: [HotKeyAction]] = [:]
        for action in HotKeyAction.allCases {
            let pref = HotKeyStore.load(action)
            byChord["\(pref.keyCode)-\(pref.modifiers)", default: []].append(action)
        }
        var conflicts: Set<HotKeyAction> = []
        for (_, actions) in byChord where actions.count > 1 { conflicts.formUnion(actions) }
        return conflicts
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .startRecording:
            guard !capture.isRecording, !isArming, !playback.isBusy else { return }
            startRecording(viaHotkey: true)
        case .stopRecording:
            if isArming { cancelArming(); return }
            guard capture.isRecording else { return }
            finishRecording(strippingChordKeyCode: Int(HotKeyStore.load(.stopRecording).keyCode))
        case .panicStop:
            panicStop()
        case .scheduleReplay:
            requestScheduleWindow()
        }
    }

    /// Ask for the Schedule a Replay window to be opened.
    func requestScheduleWindow() {
        scheduleWindowRequest += 1
    }

    /// Instantly abort any replay or countdown, and stop recording if active.
    func panicStop() {
        cancelArming()
        playback.stop()
        if capture.isRecording {
            // Triggered by the panic hotkey chord — keep it out of the timeline.
            finishRecording(strippingChordKeyCode: Int(HotKeyStore.load(.panicStop).keyCode))
        }
    }

    // MARK: - Recording

    func startRecording(viaHotkey: Bool = false) {
        guard permissions.allGranted, !capture.isRecording, !isArming, !playback.isBusy else { return }
        // Lead-in: wait a beat before the tap goes live so the click or hotkey
        // that started recording (and any move away from Tattletail) is never
        // captured. Cancelable via Stop / panic.
        isArming = true
        // Get Tattletail out of the way so you can work in the target app; it
        // comes back to the front when recording stops.
        if hideDuringRecording {
            didHideForRecording = true
            NSApp.hide(nil)
        }
        armingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.recordingLeadIn))
            guard let self, self.isArming, !Task.isCancelled else { return }
            self.isArming = false
            self.armingTask = nil
            do {
                try self.capture.startRecording(viaHotkey: viaHotkey)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Cancel a pending recording lead-in (before capture has begun).
    func cancelArming() {
        armingTask?.cancel()
        armingTask = nil
        isArming = false
        unhideIfNeeded()
    }

    /// Bring Tattletail back to the front if we hid it for a recording.
    private func unhideIfNeeded() {
        guard didHideForRecording else { return }
        didHideForRecording = false
        returnToFront()
    }

    /// Reliably pull Tattletail back to the front. Whenever the app steps aside
    /// for an action — hidden while recording, or backgrounded because a replay
    /// activated other apps — it must return to focus once that action is done.
    /// The plain cooperative `activate()` is ignored when another app is
    /// frontmost (the usual state at the end of a replay), so force it; a short
    /// delay lets the last app-activation settle first so ours isn't overridden.
    private func returnToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
    }

    /// Create an empty recording and select it, for building a timeline by hand.
    /// Deliberately low-key (File ▸ New Blank Recording / the library's empty
    /// state) — the Record button stays the primary way to make a recording.
    func createBlankRecording() {
        guard !capture.isRecording, !isArming else { return }
        let recording = Recording(name: Self.defaultBlankName(for: Date()), events: [])
        do {
            try store.save(recording)
            reloadLibrary()
            selectedRecordingID = recording.id
            selectedRecording = recording
            refreshTimelineItems()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stop recording and save the result as a new library entry.
    func finishRecording(strippingChordKeyCode: Int? = nil) {
        let events = capture.stopRecording(strippingChordKeyCode: strippingChordKeyCode)
        unhideIfNeeded()
        guard !events.isEmpty else {
            lastError = "Nothing to save — no activity was captured. (Actions inside Tattletail's own windows aren't recorded.)"
            return
        }
        let name = Self.defaultName(for: Date())
        var recording = Recording(name: name, events: events)
        // Remember the screen arrangement so replay can warn if it later changes.
        recording.displaySignature = DisplayLayout.signature()
        do {
            try store.save(recording)
            reloadLibrary()
            selectedRecordingID = recording.id
            selectedRecording = recording
            refreshTimelineItems()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Schedule state (for the library badge)

    enum ScheduleState { case none, paused, active }

    /// Whether a recording has schedules, and if any are enabled — drives the
    /// small calendar badge in the Recordings list.
    func scheduleState(for id: UUID) -> ScheduleState {
        // Single allocation-free scan — this runs for every library row on render.
        var found = false
        for schedule in scheduler.schedules where schedule.recordingID == id {
            if schedule.isEnabled { return .active }
            found = true
        }
        return found ? .paused : .none
    }

    // MARK: - Library

    func reloadLibrary() {
        summaries = store.listSummaries()
    }

    func selectRecording(id: UUID?) {
        selectedRecordingID = id
        guard let id else {
            selectedRecording = nil
            refreshTimelineItems()
            return
        }
        do {
            selectedRecording = try store.load(id: id)
        } catch {
            selectedRecording = nil
            lastError = error.localizedDescription
        }
        refreshTimelineItems()
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var recording = try store.load(id: id)
            recording.name = trimmed
            try store.save(recording)
            reloadLibrary()
            if selectedRecordingID == id { selectedRecording = recording }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Recording the user has asked to delete, pending confirmation.
    @Published var pendingDeleteID: UUID?

    /// Name shown in the delete confirmation dialog.
    var pendingDeleteName: String? {
        guard let id = pendingDeleteID else { return nil }
        return summaries.first { $0.id == id }?.name ?? "this recording"
    }

    func requestDelete(id: UUID) { pendingDeleteID = id }

    func confirmDelete() {
        if let id = pendingDeleteID { delete(id: id) }
        pendingDeleteID = nil
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
            scheduler.removeAll(forRecording: id)
            undoStacks[id] = nil
            redoStacks[id] = nil
            if selectedRecordingID == id {
                selectedRecordingID = nil
                selectedRecording = nil
                refreshTimelineItems()
            }
            reloadLibrary()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func duplicate(id: UUID) {
        do {
            let copy = try store.duplicate(id: id)
            reloadLibrary()
            selectedRecordingID = copy.id
            selectedRecording = copy
            refreshTimelineItems()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Folder management (createFolder/renameFolder/deleteFolder/moveRecordings/
    // reconcileFolderReferences) lives in the paid-only `AppModel+Folders.swift`.

    // MARK: - Bulk actions

    func deleteRecordings(ids: Set<UUID>) {
        for id in ids {
            try? store.delete(id: id)
            scheduler.removeAll(forRecording: id)
            undoStacks[id] = nil
            redoStacks[id] = nil
        }
        if let sel = selectedRecordingID, ids.contains(sel) {
            selectedRecordingID = nil
            selectedRecording = nil
            refreshTimelineItems()
        }
        reloadLibrary()
    }

    func duplicateRecordings(ids: Set<UUID>) {
        for id in ids { _ = try? store.duplicate(id: id) }
        reloadLibrary()
    }

    // Import/Export (exportRecordings/importRecordings) lives in the paid-only
    // `AppModel+ImportExport.swift`.

    /// Persist edits made to the currently selected recording's timeline.
    func saveSelectedRecording() {
        guard var recording = selectedRecording else { return }
        recording.touch()
        // Persist the on-disk counter baseline (not the live-bumped value) so an
        // edit made mid-replay can't bake a live count into the file and
        // double-count at flush. The baseline is reconstructible in memory —
        // selectedRecording's counters include the live bumps and the pending
        // buffers hold exactly those un-flushed deltas — so subtract them rather
        // than paying a full-recording decode on every edit.
        recording.runCount -= pendingRunIncrements[recording.id] ?? 0
        recording.totalRuns -= pendingTotalIncrements[recording.id] ?? 0
        do {
            try store.save(recording)
            reloadLibrary()   // keep `selectedRecording` (with its live count) for display
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Playback options

    /// Replay settings (speed/repeat/loop) for the selected recording. Defaults
    /// when nothing is selected.
    var selectedPlaybackOptions: PlaybackOptions {
        selectedRecording?.playbackOptions ?? .default
    }

    /// Persist a change to the selected recording's replay settings. These are a
    /// per-recording preference, not a content edit, so it doesn't bump
    /// `updatedAt` (the library keeps its order) and it preserves the on-disk run
    /// counters so a live replay's buffered increments aren't clobbered.
    func setPlaybackOptions(_ options: PlaybackOptions) {
        guard var recording = selectedRecording, recording.playbackOptions != options else { return }
        recording.playbackOptions = options
        selectedRecording = recording   // keep any live run counts for display
        var toSave = recording
        // Write the on-disk counter baseline (see saveSelectedRecording).
        toSave.runCount -= pendingRunIncrements[recording.id] ?? 0
        toSave.totalRuns -= pendingTotalIncrements[recording.id] ?? 0
        do {
            try store.save(toSave, touch: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Timeline edits

    /// Apply a mutation to the selected recording's events, recompute derived
    /// timing, and persist — the single funnel every timeline edit goes through.
    private func mutateSelectedTimeline(_ body: (inout [RecordedEvent]) -> Void) {
        guard var recording = selectedRecording else { return }
        pushUndoSnapshot(recording.events, for: recording.id)
        body(&recording.events)
        recording.recomputeTiming()
        selectedRecording = recording
        refreshTimelineItems()
        saveSelectedRecording()
    }

    /// Recompute the cached grouped timeline rows from the selected recording's
    /// events. Call only when the events actually change.
    private func refreshTimelineItems() {
        selectedTimelineItems = selectedRecording.map { buildTimelineItems($0.events) } ?? []
    }

    // MARK: - Undo / redo (timeline edits)

    /// Pre-edit event snapshots per recording. Keyed by id so switching
    /// recordings keeps each one's history intact for the session.
    private var undoStacks: [UUID: [[RecordedEvent]]] = [:]
    private var redoStacks: [UUID: [[RecordedEvent]]] = [:]
    private let maxUndoDepth = 50
    // Undo/redo menu items re-evaluate via the @Published `selectedRecording`
    // assignment that every undo/redo/edit already makes — no separate revision
    // counter is needed.

    var canUndo: Bool {
        guard let id = selectedRecordingID else { return false }
        return !(undoStacks[id]?.isEmpty ?? true)
    }

    var canRedo: Bool {
        guard let id = selectedRecordingID else { return false }
        return !(redoStacks[id]?.isEmpty ?? true)
    }

    private func pushUndoSnapshot(_ events: [RecordedEvent], for id: UUID) {
        var stack = undoStacks[id] ?? []
        stack.append(events)
        if stack.count > maxUndoDepth { stack.removeFirst(stack.count - maxUndoDepth) }
        undoStacks[id] = stack
        redoStacks[id] = []   // a fresh edit invalidates the redo branch
    }

    /// Restore the selected recording's timeline to its state before the last
    /// edit, moving the current state onto the redo stack.
    func undo() {
        guard let id = selectedRecordingID, var recording = selectedRecording,
              var undo = undoStacks[id], let previous = undo.popLast() else { return }
        var redo = redoStacks[id] ?? []
        redo.append(recording.events)
        redoStacks[id] = redo
        undoStacks[id] = undo
        recording.events = previous
        recording.recomputeTiming()
        selectedRecording = recording
        refreshTimelineItems()
        saveSelectedRecording()
    }

    /// Re-apply the last undone edit.
    func redo() {
        guard let id = selectedRecordingID, var recording = selectedRecording,
              var redo = redoStacks[id], let next = redo.popLast() else { return }
        var undo = undoStacks[id] ?? []
        undo.append(recording.events)
        undoStacks[id] = undo
        redoStacks[id] = redo
        recording.events = next
        recording.recomputeTiming()
        selectedRecording = recording
        refreshTimelineItems()
        saveSelectedRecording()
    }

    /// Insert a step at a flat-array index (clamped).
    func insertStep(_ step: RecordedEvent, at index: Int) {
        insertSteps([step], at: index)
    }

    /// Insert several steps together (e.g. a click's down+up pair) at an index.
    func insertSteps(_ steps: [RecordedEvent], at index: Int) {
        guard !steps.isEmpty else { return }
        mutateSelectedTimeline { events in
            events.insert(contentsOf: steps, at: max(0, min(index, events.count)))
        }
    }

    func insertAppActivateStep(bundleId: String, appPath: String?, appName: String?, at index: Int) {
        insertStep(.appActivate(bundleId: bundleId, appPath: appPath, appName: appName,
                                offset: 0, delay: 0.1), at: index)
    }

    func insertDelayStep(seconds: TimeInterval, at index: Int) {
        insertStep(.delayStep(seconds, offset: 0), at: index)
    }

    /// Replace an existing event (matched by id) with an edited version, keeping
    /// a paired down/up partner in sync so a click or key press stays coherent.
    func updateEvent(_ event: RecordedEvent) {
        mutateSelectedTimeline { events in
            guard let i = events.firstIndex(where: { $0.id == event.id }) else { return }
            let previous = events[i]
            events[i] = event
            events = Self.syncingPairedPartner(events, editedID: event.id, previous: previous)
        }
    }

    /// When a mouse/key event that's half of an adjacent down+up pair has its
    /// button/keyCode (or position) changed, update its immediate partner to
    /// match — otherwise the up releases a different button than the down
    /// pressed, leaving a phantom button held for the rest of the replay.
    nonisolated static func syncingPairedPartner(
        _ events: [RecordedEvent], editedID: UUID, previous: RecordedEvent
    ) -> [RecordedEvent] {
        guard let i = events.firstIndex(where: { $0.id == editedID }) else { return events }
        let edited = events[i]
        var result = events

        switch edited.kind {
        case .mouseDown, .mouseUp:
            let partnerIndex = edited.kind == .mouseDown ? i + 1 : i - 1
            guard result.indices.contains(partnerIndex) else { return result }
            var partner = result[partnerIndex]
            let opposite = edited.kind == .mouseDown ? EventKind.mouseUp : .mouseDown
            guard partner.kind == opposite, partner.button == previous.button else { return result }
            partner.button = edited.button
            partner.x = edited.x
            partner.y = edited.y
            partner.clickCount = edited.clickCount
            result[partnerIndex] = partner

        case .keyDown, .keyUp:
            let partnerIndex = edited.kind == .keyDown ? i + 1 : i - 1
            guard result.indices.contains(partnerIndex) else { return result }
            var partner = result[partnerIndex]
            let opposite = edited.kind == .keyDown ? EventKind.keyUp : .keyDown
            guard partner.kind == opposite, partner.keyCode == previous.keyCode else { return result }
            partner.keyCode = edited.keyCode
            partner.flags = edited.flags
            partner.characters = edited.characters
            result[partnerIndex] = partner

        default:
            break
        }
        return result
    }

    /// Duplicate one step, inserting the copy (with a fresh id) right after it.
    func duplicateEvent(id: UUID) {
        mutateSelectedTimeline { events in
            guard let i = events.firstIndex(where: { $0.id == id }) else { return }
            var copy = events[i]
            copy.id = UUID()
            events.insert(copy, at: i + 1)
        }
    }

    /// Duplicate a contiguous group of steps (a move-block), inserting fresh-id
    /// copies immediately after the last one, in order.
    func duplicateEvents(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutateSelectedTimeline { events in
            let indices = events.indices.filter { ids.contains(events[$0].id) }
            guard let last = indices.last else { return }
            let copies = indices.map { i -> RecordedEvent in
                var c = events[i]; c.id = UUID(); return c
            }
            events.insert(contentsOf: copies, at: last + 1)
        }
    }

    /// Collapse the given steps into one manual group (a fresh group id). The
    /// caller passes a contiguous run of steps; consecutive steps sharing the id
    /// render as a single collapsible block, like auto-grouped cursor moves.
    func groupEvents(ids: Set<UUID>, name: String? = nil) {
        guard ids.count >= 2 else { return }
        let gid = UUID()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        mutateSelectedTimeline { events in
            for i in events.indices where ids.contains(events[i].id) {
                events[i].groupID = gid
                events[i].groupName = cleanName
            }
        }
    }

    /// Dissolve a manual group, returning its steps to standalone rows.
    func ungroup(groupID: UUID) {
        mutateSelectedTimeline { events in
            for i in events.indices where events[i].groupID == groupID {
                events[i].groupID = nil
                events[i].groupName = nil
            }
        }
    }

    /// Rename a manual group (nil/empty clears the label).
    func renameGroup(groupID: UUID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        mutateSelectedTimeline { events in
            for i in events.indices where events[i].groupID == groupID {
                events[i].groupName = cleanName
            }
        }
    }

    /// Enable or disable one or more steps.
    func setEventsEnabled(ids: Set<UUID>, enabled: Bool) {
        mutateSelectedTimeline { events in
            for i in events.indices where ids.contains(events[i].id) {
                events[i].enabled = enabled
            }
        }
    }

    func removeEvents(ids: Set<UUID>) {
        mutateSelectedTimeline { events in
            events.removeAll { ids.contains($0.id) }
        }
    }

    /// Replace the whole event list (used by drag-to-reorder), preserving each
    /// step's gap-before (`delay`); offsets are recomputed from those delays.
    func replaceTimeline(with events: [RecordedEvent]) {
        mutateSelectedTimeline { $0 = events }
    }

    // MARK: - Run counter

    private func notePassCompleted(_ id: UUID) {
        pendingRunIncrements[id, default: 0] += 1
        pendingTotalIncrements[id, default: 0] += 1
        // Live UI bump so both counters tick up as it plays.
        if let i = summaries.firstIndex(where: { $0.id == id }) {
            summaries[i].runCount += 1
            summaries[i].totalRuns += 1
        }
        if selectedRecording?.id == id {
            selectedRecording?.runCount += 1
            selectedRecording?.totalRuns += 1
        }
    }

    /// Called when a replay session fully ends — finished, aborted, or
    /// panic-stopped, including a cancelled countdown.
    private func handlePlaybackEnded() {
        #if !FREE_BUILD
        logRunToHistory()   // must read pending pass counts before the flush clears them
        #endif
        flushRunIncrements()
        // Bring Tattletail back to the front when a user-initiated replay ends,
        // so you land back in the app the moment it's done. Scheduled/background
        // fires deliberately don't, so they never steal focus from your work.
        if playback.returnsFocusOnEnd { returnToFront() }
    }

    // Run history (logRunToHistory/clearHistory) lives in the paid-only
    // `AppModel+History.swift`.

    private func flushRunIncrements() {
        let runDeltas = pendingRunIncrements
        let totalDeltas = pendingTotalIncrements
        pendingRunIncrements.removeAll()
        pendingTotalIncrements.removeAll()
        let ids = Set(runDeltas.keys).union(totalDeltas.keys)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard var rec = try? store.load(id: id) else { continue }
            rec.runCount += runDeltas[id] ?? 0
            rec.totalRuns += totalDeltas[id] ?? 0
            try? store.save(rec, touch: false)   // don't reorder the library
        }
        reloadLibrary()
        // Keep the open recording's counters in sync with the authoritative value.
        if let sel = selectedRecordingID, let disk = try? store.load(id: sel) {
            selectedRecording?.runCount = disk.runCount
            selectedRecording?.totalRuns = disk.totalRuns
        }
    }

    /// Resets only the resettable counter. The lifetime `totalRuns` is left
    /// intact — it's a permanent record of every run since creation.
    func resetRunCount(id: UUID) {
        guard var rec = try? store.load(id: id) else { return }
        rec.runCount = 0
        try? store.save(rec, touch: false)
        // Drop only the resettable pending so an in-flight replay can't
        // resurrect it; the lifetime pending is intentionally kept.
        pendingRunIncrements[id] = nil
        if selectedRecording?.id == id { selectedRecording?.runCount = 0 }
        reloadLibrary()
    }

    // MARK: - Naming

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return "Recording \(formatter.string(from: date))"
    }

    private static func defaultBlankName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return "Untitled \(formatter.string(from: date))"
    }
}

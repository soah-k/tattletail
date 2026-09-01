import AppKit
import Carbon
import CoreGraphics
import SwiftUI

/// What a freshly-added step should be. Mouse clicks and key presses expand to
/// a down+up pair; the rest are single events.
enum StepTemplate: String, CaseIterable, Identifiable {
    case move, click, scroll, key, text, paste, app, wait
    var id: String { rawValue }

    var label: String {
        switch self {
        case .move: return "Move to Point"
        case .click: return "Click"
        case .scroll: return "Scroll"
        case .key: return "Key Press"
        case .text: return "Type Text"
        case .paste: return "Paste Text"
        case .app: return "Activate App"
        case .wait: return "Wait"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .click: return "cursorarrow.click"
        case .scroll: return "scroll"
        case .key: return "keyboard"
        case .text: return "text.cursor"
        case .paste: return "doc.on.clipboard"
        case .app: return "app.badge"
        case .wait: return "clock"
        }
    }
}

/// Adaptive editor for creating a new step or editing an existing one. Shows
/// only the fields relevant to the step's kind.
struct StepEditorSheet: View {
    enum Mode {
        case create(StepTemplate, insertIndex: Int)
        case edit(RecordedEvent)
    }

    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Editable fields (a superset; only the relevant ones are shown).
    @State private var x: Double = 200
    @State private var y: Double = 200
    @State private var button: Int = 0
    @State private var clickCount: Int = 1
    @State private var isDown: Bool = true          // for click / key: press vs release
    @State private var delay: Double = 0.5
    @State private var keyCode: Int = 0
    @State private var flags: UInt64 = 0
    @State private var characters: String = ""
    @State private var textToType: String = ""       // for the Type Text step
    @State private var stepName: String = ""          // optional per-step label
    @State private var scrollY: Double = -3          // negative = scroll down
    @State private var scrollX: Double = 0
    @State private var scrollContinuous = false      // trackpad (pixel) vs mouse (line)
    @State private var seconds: Double = 1.0
    @State private var appBundleId: String?
    @State private var appPath: String?
    @State private var appName: String?
    @State private var showAppPicker = false

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let e) = mode {
            _x = State(initialValue: e.x ?? 200)
            _y = State(initialValue: e.y ?? 200)
            _button = State(initialValue: e.button ?? 0)
            _clickCount = State(initialValue: e.clickCount ?? 1)
            _isDown = State(initialValue: e.kind == .mouseDown || e.kind == .keyDown)
            _delay = State(initialValue: e.delay)
            _keyCode = State(initialValue: e.keyCode ?? 0)
            _flags = State(initialValue: e.flags ?? 0)
            _characters = State(initialValue: e.characters ?? "")
            _textToType = State(initialValue: (e.kind == .typeText || e.kind == .pasteText) ? (e.characters ?? "") : "")
            _stepName = State(initialValue: e.name ?? "")
            // Trackpad scrolls carry their real deltas in the pixel fields;
            // edit whichever unit the event actually uses so Save can't downgrade
            // a precise continuous scroll to a coarse line scroll.
            let continuous = e.scrollContinuous ?? false
            _scrollContinuous = State(initialValue: continuous)
            _scrollY = State(initialValue: continuous ? (e.scrollPixelY ?? 0) : (e.scrollLineY ?? -3))
            _scrollX = State(initialValue: continuous ? (e.scrollPixelX ?? 0) : (e.scrollLineX ?? 0))
            _seconds = State(initialValue: e.kind == .delay ? e.delay : 1.0)
            _appBundleId = State(initialValue: e.bundleId)
            _appPath = State(initialValue: e.appPath)
            _appName = State(initialValue: e.appName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.ink)

            Form {
                LabeledContent("Name") {
                    TextField("Optional", text: $stepName)
                }
                fields
                if template != .wait && template != .app {
                    waitField
                }
            }
            .formStyle(.grouped)
            .frame(height: formHeight)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Add Step" : "Save") { save() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(Theme.sectionSpacing)
        .frame(width: 420)
        .background(Theme.background)
        .sheet(isPresented: $showAppPicker) {
            AppPickerSheet { bundleId, path, name in
                appBundleId = bundleId; appPath = path; appName = name
            }
        }
    }

    // MARK: - Field groups

    @ViewBuilder
    private var fields: some View {
        switch template {
        case .move:
            pointFields
        case .click:
            Picker("Button", selection: $button) {
                Text("Left").tag(0); Text("Right").tag(1); Text("Middle").tag(2)
            }
            pointFields
            Stepper(value: $clickCount, in: 1...5) {
                Text("Click count: \(clickCount)")
            }
            if isEditingSingleMouseEvent {
                Picker("Action", selection: $isDown) {
                    Text("Press").tag(true); Text("Release").tag(false)
                }
                .pickerStyle(.segmented)
            }
            windowAnchorNoteView
        case .scroll:
            pointFields
            LabeledContent("Vertical") {
                TextField("", value: $scrollY, format: .number).frame(width: 80)
            }
            LabeledContent("Horizontal") {
                TextField("", value: $scrollX, format: .number).frame(width: 80)
            }
            Text(scrollContinuous
                 ? "Pixel deltas (trackpad). Negative scrolls down / right."
                 : "Line deltas (mouse wheel). Negative scrolls down / right.")
                .font(Theme.body(11)).foregroundStyle(Theme.inkSecondary)
            windowAnchorNoteView
        case .key:
            KeyCaptureField(keyCode: $keyCode, flags: $flags, characters: $characters)
            if isEditingSingleKeyEvent {
                Picker("Action", selection: $isDown) {
                    Text("Press").tag(true); Text("Release").tag(false)
                }
                .pickerStyle(.segmented)
            }
        case .text:
            textBox(label: "Text to type",
                    note: "Typed into whatever app is focused, so put an Activate App step (or a click) before it. Password fields can't be filled.")
        case .paste:
            textBox(label: "Text to paste",
                    note: "Pastes this text (⌘V) into the focused app — reliable for large or special text. Your clipboard is used briefly and then restored.")
        case .app:
            LabeledContent("App") {
                Button(appName ?? appBundleId ?? "Choose App…") { showAppPicker = true }
                    .buttonStyle(.link)
            }
            waitField
        case .wait:
            LabeledContent("Wait") {
                HStack(spacing: 4) {
                    TextField("", value: $seconds, format: .number).frame(width: 70)
                    Text("seconds").foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private var pointFields: some View {
        PointGrabberField(x: $x, y: $y)
    }

    /// Read-only note shown when editing a click/scroll that carries a
    /// window-relative anchor, so the user can see it follows its window.
    private var windowAnchorNote: String? {
        if case .edit(let e) = mode, e.hasWindowAnchor {
            return "Window-relative: anchored to “\(e.windowTitle ?? e.windowBundleId ?? "its window")”. Replay re-aims at the window's current position; the point above is the fallback."
        }
        return nil
    }

    @ViewBuilder
    private var windowAnchorNoteView: some View {
        if let note = windowAnchorNote {
            Text(note).font(Theme.body(10.5)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func textBox(label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.label(12)).foregroundStyle(Theme.inkSecondary)
            TextEditor(text: $textToType)
                .font(Theme.mono(12))
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            Text(note)
                .font(Theme.body(10.5)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private var waitField: some View {
        LabeledContent("Wait before") {
            HStack(spacing: 4) {
                TextField("", value: $delay, format: .number).frame(width: 70)
                Text("seconds").foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    // MARK: - Derived

    private var isCreate: Bool { if case .create = mode { return true }; return false }

    private var template: StepTemplate {
        switch mode {
        case .create(let t, _): return t
        case .edit(let e):
            switch e.kind {
            case .mouseMove: return .move
            case .mouseDown, .mouseUp: return .click
            case .scroll: return .scroll
            case .keyDown, .keyUp, .flagsChanged: return .key
            case .typeText: return .text
            case .pasteText: return .paste
            case .appActivate: return .app
            case .delay: return .wait
            }
        }
    }

    private var isEditingSingleMouseEvent: Bool {
        if case .edit(let e) = mode { return e.kind == .mouseDown || e.kind == .mouseUp }
        return false
    }

    private var isEditingSingleKeyEvent: Bool {
        if case .edit(let e) = mode { return e.kind == .keyDown || e.kind == .keyUp }
        return false
    }

    private var title: String {
        switch mode {
        case .create(let t, _): return "Add \(t.label)"
        case .edit: return "Edit \(template.label)"
        }
    }

    private var formHeight: CGFloat {
        // Base height per template, plus room for the always-present Name row.
        let nameRow: CGFloat = 52
        let base: CGFloat
        switch template {
        case .move: base = 150
        case .click: base = isEditingSingleMouseEvent ? 260 : 210
        case .scroll: base = 230
        case .key: base = isEditingSingleKeyEvent ? 190 : 150
        case .text: base = 240
        case .paste: base = 240
        case .app: base = 130
        case .wait: base = 90
        }
        // Scale with the global text size so taller rows don't get clipped.
        return (base + nameRow) * Theme.textScale
    }

    private var isValid: Bool {
        switch template {
        case .app: return appBundleId != nil
        case .wait: return seconds > 0
        case .text, .paste: return !textToType.isEmpty
        default: return true
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = stepName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmedName.isEmpty ? nil : trimmedName
        switch mode {
        case .create(let t, let index):
            var events = buildNewEvents(for: t)
            // A step maps to one row per event; label the first so the name shows
            // once (e.g. on the "down" of a click, not on both down and up).
            if !events.isEmpty { events[0].name = name }
            model.insertSteps(events, at: index)
        case .edit(let original):
            var e = applyEdits(to: original)
            e.name = name
            model.updateEvent(e)
        }
        dismiss()
    }

    /// Build the event(s) for a new step. Clicks and key presses become a
    /// down+up pair so replay actually completes the gesture.
    private func buildNewEvents(for template: StepTemplate) -> [RecordedEvent] {
        switch template {
        case .move:
            return [.mouseMove(x: x, y: y, button: nil, offset: 0, delay: delay)]
        case .click:
            return [
                .mouseButton(down: true, x: x, y: y, button: button, clickCount: clickCount,
                             offset: 0, delay: delay),
                .mouseButton(down: false, x: x, y: y, button: button, clickCount: clickCount,
                             offset: 0, delay: 0.05),
            ]
        case .scroll:
            return [.scroll(lineX: scrollX, lineY: scrollY, pixelX: 0, pixelY: 0,
                            continuous: false, x: x, y: y, offset: 0, delay: delay)]
        case .key:
            return [
                .key(down: true, keyCode: keyCode, flags: flags, isRepeat: false,
                     characters: characters.isEmpty ? nil : characters, offset: 0, delay: delay),
                .key(down: false, keyCode: keyCode, flags: flags, isRepeat: false,
                     characters: characters.isEmpty ? nil : characters, offset: 0, delay: 0.03),
            ]
        case .text:
            return [.typeText(textToType, offset: 0, delay: delay)]
        case .paste:
            return [.pasteText(textToType, offset: 0, delay: delay)]
        case .app:
            return [.appActivate(bundleId: appBundleId, appPath: appPath, appName: appName,
                                 offset: 0, delay: delay)]
        case .wait:
            return [.delayStep(seconds, offset: 0)]
        }
    }

    /// Apply edits back onto an existing event, preserving its id.
    private func applyEdits(to original: RecordedEvent) -> RecordedEvent {
        var e = original
        switch original.kind {
        case .mouseMove:
            e.x = x; e.y = y; e.delay = delay
        case .mouseDown, .mouseUp:
            e.kind = isDown ? .mouseDown : .mouseUp
            e.button = button; e.x = x; e.y = y; e.clickCount = clickCount; e.delay = delay
        case .scroll:
            if scrollContinuous {
                e.scrollPixelY = scrollY; e.scrollPixelX = scrollX
                e.scrollLineY = 0; e.scrollLineX = 0; e.scrollContinuous = true
            } else {
                e.scrollLineY = scrollY; e.scrollLineX = scrollX
                e.scrollPixelY = 0; e.scrollPixelX = 0; e.scrollContinuous = false
            }
            e.x = x; e.y = y; e.delay = delay
        case .keyDown, .keyUp:
            e.kind = isDown ? .keyDown : .keyUp
            e.keyCode = keyCode; e.flags = flags
            e.characters = characters.isEmpty ? nil : characters
            e.delay = delay
        case .flagsChanged:
            e.keyCode = keyCode; e.flags = flags; e.delay = delay
        case .appActivate:
            e.bundleId = appBundleId; e.appPath = appPath; e.appName = appName; e.delay = delay
        case .delay:
            e.delay = seconds
        case .typeText, .pasteText:
            e.characters = textToType; e.delay = delay
        }
        return e
    }
}

// MARK: - Point grabber

/// X/Y numeric fields plus a "Grab" button that captures the live cursor
/// position after a short countdown (so you can place the pointer first).
struct PointGrabberField: View {
    @Binding var x: Double
    @Binding var y: Double
    @State private var countdown: Int?
    @State private var grabTask: Task<Void, Never>?

    var body: some View {
        LabeledContent("Position") {
            HStack(spacing: 6) {
                Text("X").foregroundStyle(Theme.inkSecondary)
                TextField("", value: $x, format: .number).frame(width: 64)
                Text("Y").foregroundStyle(Theme.inkSecondary)
                TextField("", value: $y, format: .number).frame(width: 64)
                Button(grabTitle) { startGrab() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(countdown != nil)
                    .help("Move your pointer where you want it, then it's captured after a 3-second countdown.")
            }
        }
        .onDisappear { grabTask?.cancel(); grabTask = nil }
    }

    private var grabTitle: String {
        if let countdown { return "\(countdown)…" }
        return "Grab"
    }

    private func startGrab() {
        countdown = 3
        grabTask = Task { @MainActor in
            while let c = countdown, c > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if let c = countdown { countdown = c - 1 }
            }
            if Task.isCancelled { return }
            if let loc = CGEvent(source: nil)?.location {
                x = loc.x.rounded()
                y = loc.y.rounded()
            }
            countdown = nil
        }
    }
}

// MARK: - Key capture

/// A click-to-capture control that records the next key press into a keyCode +
/// modifier flags (+ characters for display).
struct KeyCaptureField: View {
    @Binding var keyCode: Int
    @Binding var flags: UInt64
    @Binding var characters: String
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Key") {
            Button(capturing ? "Press a key…" : display) { capturing ? stop() : start() }
                .font(Theme.mono(12))
                .frame(minWidth: 120)
        }
        .onDisappear(perform: stop)
    }

    private var display: String {
        var parts: [String] = []
        let f = CGEventFlags(rawValue: flags)
        if f.contains(.maskControl) { parts.append("⌃") }
        if f.contains(.maskAlternate) { parts.append("⌥") }
        if f.contains(.maskShift) { parts.append("⇧") }
        if f.contains(.maskCommand) { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: UInt32(keyCode)))
        return parts.joined()
    }

    private func start() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            keyCode = Int(event.keyCode)
            flags = cgFlags(from: event.modifierFlags)
            characters = event.charactersIgnoringModifiers ?? ""
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }

    /// Map AppKit modifier flags to the `CGEventFlags` bit pattern we store.
    private func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var f = CGEventFlags()
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        return f.rawValue
    }
}

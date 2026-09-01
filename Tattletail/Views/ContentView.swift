import SwiftUI

/// Root view: permissions onboarding until granted, then the main split view.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.permissions.allGranted {
                MainSplitView()
            } else {
                PermissionsOnboardingView()
            }
        }
        .background(Theme.background)
        .background(WindowConfigurator())
        .alert("Tattletail hit a snag", isPresented: errorBinding) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(
            "Forget this recording?",
            isPresented: deleteBinding,
            presenting: model.pendingDeleteName
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Keep It", role: .cancel) { model.pendingDeleteID = nil }
        } message: { name in
            Text("“\(name)” and any schedules for it will be gone for good — Tattletail can't get it back.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeleteID != nil },
            set: { if !$0 { model.pendingDeleteID = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

/// The left column: a Recordings / History switch over the library list or the
/// run-history list.
struct SidebarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case recordings = "Recordings"
        #if !FREE_BUILD
        case scheduled = "Scheduled"
        case history = "History"
        #endif
        var id: String { rawValue }
    }
    @State private var mode: Mode = .recordings

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider()
            switch mode {
            case .recordings: LibraryView()
            #if !FREE_BUILD
            case .scheduled: ScheduledView()
            case .history: HistoryView()
            #endif
            }
        }
        .background(Theme.background)
    }
}

/// Sets the hosting window's collection behavior so that reopening Tattletail
/// (from the menu bar or Dock) brings the window to the CURRENT Space instead of
/// switching the user to whatever Space the window was last on.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.collectionBehavior.insert(.moveToActiveSpace)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Sidebar (library) + detail layout with the record control in the toolbar.
struct MainSplitView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if model.selectedRecording != nil {
                RecordingDetailView()
            } else {
                EmptyDetailView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.createBlankRecording()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Blank Recording — build a recording by hand")
                .accessibilityLabel("New Blank Recording")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Tattletail Settings")
                .accessibilityLabel("Tattletail Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .overlay(alignment: .bottom) {
            StatusBarContent(capture: model.capture, playback: model.playback,
                             isArming: model.isArming,
                             panicKey: model.panicHotKeyDisplay,
                             stopRecordingKey: model.hotKeyDisplay(.stopRecording)) {
                model.panicStop()
            }
        }
    }
}

/// The prominent record/stop control.
struct RecordButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            if model.isArming {
                model.cancelArming()
            } else if model.capture.isRecording {
                model.finishRecording()
            } else {
                model.startRecording()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .fixedSize()
        }
        .buttonStyle(WarmButtonStyle(color: tint))
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help(helpText)
    }

    private var symbol: String {
        if model.isArming { return "hourglass" }
        return model.capture.isRecording ? "stop.fill" : "record.circle"
    }
    private var title: String {
        if model.isArming { return "Starting…" }
        return model.capture.isRecording ? "Stop" : "Record"
    }
    private var tint: Color {
        if model.isArming { return Theme.amberButton }
        return model.capture.isRecording ? Theme.brickButton : Theme.accentButton
    }
    private var helpText: String {
        if model.isArming { return "Get ready — recording starts in a moment. Click to cancel." }
        return model.capture.isRecording
            ? "Stop recording and save to your library"
            : "Start recording your mouse and keyboard"
    }
}

/// Placeholder detail pane when nothing is selected.
struct EmptyDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent.opacity(0.5))
            Text(model.summaries.isEmpty ? "Nothing on record. Yet." : "Pick a recording")
                .font(Theme.title(18))
                .foregroundStyle(Theme.ink)
            Text(model.summaries.isEmpty
                 ? "Hit Record and do your thing — Tattletail will remember every move and repeat it on command."
                 : "Choose a recording from the sidebar to replay, edit, or schedule it.")
                .font(Theme.body())
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// Bottom overlay showing live recording or replay state, with a stop control.
struct StatusBarContent: View {
    @ObservedObject var capture: EventCaptureEngine
    @ObservedObject var playback: PlaybackEngine
    var isArming: Bool = false
    let panicKey: String
    let stopRecordingKey: String
    let onStop: () -> Void

    var body: some View {
        Group {
            if isArming {
                bar(icon: "hourglass", tint: Theme.amber,
                    title: "Get ready…",
                    subtitle: "Recording starts in a moment — this click won't be recorded")
            } else if capture.isRecording {
                bar(
                    icon: "record.circle.fill", tint: Theme.brick,
                    title: "Recording — \(capture.liveEventCount) events · \(format(capture.liveDuration))",
                    subtitle: capture.secureInputActive
                        ? "A secure field is focused — keystrokes there can't be recorded"
                        : "Everything you do is going on the record — \(stopRecordingKey) stops (and stays off it)"
                )
            } else {
                switch playback.phase {
                case .countingDown(let remaining):
                    bar(icon: "timer", tint: Theme.amber,
                        title: "Replaying in \(remaining)s…",
                        subtitle: "Press \(panicKey) to cancel")
                case .playing(let pass, let total):
                    bar(icon: "play.fill", tint: Theme.sage,
                        title: total.map { "Replaying — pass \(pass) of \($0)" }
                            ?? "Replaying — pass \(pass) (looping)",
                        subtitle: "Press \(panicKey) to stop",
                        progress: playback.progress)
                default:
                    EmptyView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: capture.isRecording)
        .animation(.easeInOut(duration: 0.2), value: isArming)
    }

    @ViewBuilder
    private func bar(icon: String, tint: Color, title: String,
                     subtitle: String, progress: Double? = nil) -> some View {
        HStack(spacing: Theme.spacing) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.label(13))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.inkSecondary)
            }
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 140)
                    .tint(tint)
            }
            Spacer()
            Button("Stop", action: onStop)
                .buttonStyle(WarmButtonStyle(color: Theme.brickButton))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .card()
        .padding(.horizontal, Theme.sectionSpacing)
        .padding(.bottom, Theme.spacing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let whole = Int(min(t, 8.64e6))   // cap so Int() can't trap on a huge value
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

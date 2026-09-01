import SwiftUI

@main
struct TattletailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Tattletail", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            // A low-key way to start a hand-built recording. Record stays the
            // primary path; this just lives in File ▸ New (⌘N).
            CommandGroup(replacing: .newItem) {
                Button("New Blank Recording") { model.createBlankRecording() }
                    .keyboardShortcut("n", modifiers: .command)
                #if !FREE_BUILD
                Divider()
                Button("Import Recordings…") { model.importRecordings() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                #endif
            }
            // Undo/redo for timeline edits (insert, delete, reorder, toggle,
            // edit-a-step). Replaces the no-op default Edit-menu entries.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
        }

        Window("Schedule a Replay", id: "schedule") {
            ScheduleComposerView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// The status-item icon. This view is alive for the whole app lifetime, which
/// makes it the reliable holder of the `openWindow` environment for requests
/// that originate outside any window — like the schedule-replay hotkey.
private struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onChange(of: model.scheduleWindowRequest) {
                openWindow(id: "schedule")
                NSApp.activate()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.playback.phase {
        case .playing(let pass, let total):
            // Show which round a replay is on, e.g. "1/4" (or "1/∞" while looping).
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                Text("\(pass)/\(total.map(String.init) ?? "∞")")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        case .countingDown(let remaining):
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text("\(remaining)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        default:
            Image(systemName: model.capture.isRecording
                  ? "record.circle.fill" : "cursorarrow.click.badge.clock")
        }
    }
}

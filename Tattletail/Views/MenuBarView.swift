import SwiftUI

/// Contents of the menu bar extra: quick record/stop, panic stop, recent
/// recordings, settings, about, and a way back to the main window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.isArming {
                Button("Starting… (Cancel)") { model.cancelArming() }
            } else if model.capture.isRecording {
                Button("Stop Recording  \(model.hotKeyDisplay(.stopRecording))") {
                    model.finishRecording()
                }
            } else {
                Button("Start Recording  \(model.hotKeyDisplay(.startRecording))") {
                    model.startRecording()
                }
                .disabled(!model.permissions.allGranted)
            }

            if model.playback.isBusy {
                Button("Stop Replay  \(model.hotKeyDisplay(.panicStop))") {
                    model.panicStop()
                }
            }

            Divider()

            if !model.summaries.isEmpty {
                Menu("Replay") {
                    ForEach(model.summaries.prefix(8)) { summary in
                        Button(summary.name) {
                            if let recording = try? model.store.load(id: summary.id) {
                                model.playback.play(recording, options: recording.playbackOptions)
                            }
                        }
                    }
                }
            }

            Button("Schedule Replay…  \(model.hotKeyDisplay(.scheduleReplay))") {
                openWindow(id: "schedule")
                NSApp.activate()
            }

            if model.scheduler.schedules.contains(where: { !$0.completed }) {
                Button(model.scheduler.isPaused ? "Resume All Schedules" : "Pause All Schedules") {
                    model.scheduler.isPaused.toggle()
                }
            }

            if model.scheduler.isPaused {
                Text("Schedules paused")
            } else if let next = model.scheduler.nextUpcoming {
                Text("Next: \(next.recordingName) — \(next.fireDate.formatted(.dateTime.month().day().hour().minute()))")
            }

            Divider()

            Button("Open Tattletail") {
                openWindow(id: "main")
                NSApp.activate()
            }

            Button("Settings…") {
                openSettings()
                NSApp.activate()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("About Tattletail") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            }

            Divider()

            Button("Quit Tattletail") {
                NSApp.terminate(nil)
            }
        }
    }
}

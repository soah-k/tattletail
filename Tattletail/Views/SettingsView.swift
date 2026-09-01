import Carbon
import ServiceManagement
import SwiftUI

/// App settings, organized into native macOS preference tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            SchedulingSettingsTab()
                .tabItem { Label("Scheduling", systemImage: "calendar") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500)
    }
}

/// One muted caption line under a setting.
private struct SettingNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.body(11)).foregroundStyle(Theme.inkSecondary)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Show a screen glow while recording or replaying", isOn: $model.showActivityGlow)
                SettingNote("A glow around the screen edges — amber while recording, red while replaying — so you always know Tattletail is running. Honors Reduce Motion.")

                Toggle("Hide Tattletail while recording", isOn: $model.hideDuringRecording)
                SettingNote("When you start recording, Tattletail moves out of the way so you can work in other apps, then returns to the front when you stop.")
            }

            Section {
                Toggle("Use window-relative positioning", isOn: $model.useWindowRelative)
                SettingNote("Records where each click lands inside its window, so replays follow the window if it moves or resizes — and adapt across screen setups. Falls back to screen coordinates when the window can't be found. Turn off to use plain screen coordinates, exactly as before.")
            }

            Section {
                Toggle("Launch Tattletail at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                SettingNote("Recommended if you use scheduled replays — they only fire while Tattletail is running.")
            }

            Section {
                LabeledContent("Recordings folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.recordingsURL])
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hotkeys

private struct HotkeysSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    HotKeyRow(action: action)
                }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { model.resetHotKeys() }
                        .buttonStyle(.link)
                }
                if !model.hotKeyConflicts.isEmpty {
                    warningLabel("Two actions are bound to the same chord, so one of them won't work. Give each a different combination above.")
                }
                if !model.hotKeyRegistrationFailed.isEmpty {
                    warningLabel(model.hotKeyRegistrationFailed.contains(.panicStop)
                        ? "The panic-stop hotkey couldn't be registered — another app is likely using that chord. Pick a different combination above so panic-stop always works."
                        : "A hotkey couldn't be registered — another app may be using that chord. Try a different combination above.")
                }
                SettingNote("Hotkeys work from anywhere. Recording start/stop chords are automatically kept out of your recordings.")
            }
        }
        .formStyle(.grouped)
    }

    private func warningLabel(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.brick)
        }
        .font(Theme.body(11))
        .foregroundStyle(Theme.ink)
    }
}

// MARK: - Scheduling

private struct SchedulingSettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Notify before scheduled replays", isOn: Binding(
                    get: { model.scheduler.notifyBeforeScheduled },
                    set: { model.scheduler.notifyBeforeScheduled = $0 }))
                SettingNote("Posts a heads-up notification a few seconds before a scheduled replay fires. macOS will ask permission the first time.")

                Toggle("Only run when the Mac is idle", isOn: Binding(
                    get: { model.scheduler.onlyRunWhenIdle },
                    set: { model.scheduler.onlyRunWhenIdle = $0 }))
                SettingNote("Waits for a lull in your typing and clicking before firing a due schedule, so a run doesn't fight your input. If you stay active for more than 5 minutes past the scheduled time, that run is skipped.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section { AboutCard() }
        }
        .formStyle(.grouped)
    }
}

/// Standard macOS-style About block: icon, name, version, copyright.
private struct AboutCard: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tattletail"
    }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Tattletail. All rights reserved."
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(appName)
                .font(Theme.title(20))
                .foregroundStyle(Theme.ink)
            Text("Version \(version) (\(build))")
                .font(Theme.body(12))
                .foregroundStyle(Theme.inkSecondary)
            Text(copyright)
                .font(Theme.body(11))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)

            Text("Open source under the MIT License")
                .font(Theme.body(11))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 2)
            HStack(spacing: 14) {
                Link("View Source", destination: Self.repoURL)
                Text("·").foregroundStyle(Theme.inkSecondary)
                Link("License", destination: Self.licenseURL)
            }
            .font(Theme.body(11))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private static let repoURL = URL(string: "https://github.com/soah-k/tattletail")!
    private static let licenseURL = URL(string: "https://github.com/soah-k/tattletail/blob/main/LICENSE")!
}

/// One hotkey binding row: label, description, and a click-to-rebind recorder.
private struct HotKeyRow: View {
    @EnvironmentObject private var model: AppModel
    let action: HotKeyAction

    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent {
            Button {
                isCapturing ? stopCapture() : startCapture()
            } label: {
                Text(isCapturing ? "Press shortcut…" : currentDisplay)
                    .font(Theme.mono(12))
                    .frame(minWidth: 90)
            }
            .help(isCapturing
                  ? "Press a key combination with at least one modifier — Esc cancels"
                  : "Click, then press the new shortcut")
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(action.label)
                    if model.hotKeyConflicts.contains(action) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.brick)
                            .help("This chord is also used by another action.")
                    }
                }
                Text(action.detail)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .onDisappear { stopCapture() }
    }

    private var currentDisplay: String {
        _ = model.hotKeyRevision   // re-render when bindings change
        return model.hotKeyDisplay(action)
    }

    private func startCapture() {
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopCapture() }
            // Esc with no modifiers cancels.
            let mods = carbonModifiers(from: event.modifierFlags)
            if event.keyCode == UInt32(kVK_Escape) && mods == 0 {
                return nil
            }
            // Require at least one modifier so a bare letter can't become a
            // global hotkey and swallow normal typing system-wide.
            guard mods != 0 else {
                NSSound.beep()
                return nil
            }
            model.setHotKey(
                HotKeyPreference(keyCode: UInt32(event.keyCode), modifiers: mods),
                for: action
            )
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
    }
}

import SwiftUI

/// Play / speed / repeat / countdown / schedule / delete controls for the
/// selected recording.
///
/// Layout note: this view lives inside the detail `List`. It uses a fixed
/// three-row `VStack` (never `ViewThatFits`) — `ViewThatFits` inside a List row
/// can oscillate between candidates and hang the main thread. Labels are
/// `.fixedSize()` so text never breaks mid-word when the pane is narrow, and the
/// rows are grouped so each fits comfortably at the minimum detail width.
struct ReplayControlsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var options: PlaybackOptions
    @Binding var showScheduleSheet: Bool
    @Binding var showCountdownPopover: Bool
    @State private var countdownSeconds = 5
    /// Live slider value, committed to `options.speed` only when the drag ends —
    /// so a drag doesn't fire a load+save of the whole recording on every tick.
    @State private var liveSpeed: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            // Row 1 — actions
            HStack(spacing: Theme.spacing) {
                replayButton
                runInButton
                scheduleButton
                Spacer(minLength: Theme.spacing)
                deleteButton
            }

            // Row 2 — speed presets + panic (fills the deadspace on the right)
            HStack(spacing: 6) {
                Text("Speed")
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize()
                Picker("Speed", selection: presetBinding) {
                    ForEach(PlaybackOptions.speedChoices, id: \.self) { choice in
                        Text(SpeedFormat.label(choice)).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer(minLength: Theme.spacing)
                panicChip
            }

            // Row 3 — fine speed slider + repeat/loop (fills the deadspace)
            HStack(spacing: 8) {
                Slider(value: $liveSpeed, in: PlaybackOptions.minSpeed...PlaybackOptions.maxSpeed, step: 0.05,
                       onEditingChanged: { editing in if !editing { options.speed = liveSpeed } })
                    .frame(maxWidth: 200)
                Text(speedText(liveSpeed))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(minWidth: 40, alignment: .leading)
                Spacer(minLength: Theme.spacing)
                HStack(spacing: 6) {
                    Text("Repeat")
                        .font(Theme.label(12))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize()
                    Stepper(value: $options.repeatCount, in: 1...999) {
                        Text("\(options.repeatCount)×")
                            .font(Theme.mono(12))
                            .frame(minWidth: 32)
                    }
                    .disabled(options.loops)
                    .fixedSize()
                    Toggle("Loop", isOn: $options.loops)
                        .toggleStyle(.checkbox)
                        .font(Theme.label(12))
                        .fixedSize()
                }
            }

            #if !FREE_BUILD
            // Row 4 — playback style toggles (paid: Jump-to-clicks + Natural timing)
            HStack(spacing: Theme.sectionSpacing) {
                Toggle("Jump to clicks", isOn: $options.jumpInstantly)
                    .toggleStyle(.checkbox)
                    .font(Theme.label(12))
                    .fixedSize()
                    .help("Skip the recorded cursor path and jump straight between clicks (faster).")
                Toggle("Natural timing", isOn: $options.humanize)
                    .toggleStyle(.checkbox)
                    .font(Theme.label(12))
                    .fixedSize()
                    .help("Add slight random variation to the timing between steps.")
                Spacer(minLength: 0)
            }
            #endif
        }
        .padding(16)
        .card()
        .onAppear { liveSpeed = options.speed }
        .onChange(of: options.speed) { _, v in if v != liveSpeed { liveSpeed = v } }
    }

    /// The segmented picker snaps to the preset nearest the current speed, so a
    /// segment always stays highlighted even when the slider sets an off-preset
    /// value; tapping a preset sets that exact speed.
    private var presetBinding: Binding<Double> {
        Binding(
            get: {
                PlaybackOptions.speedChoices.min(by: { abs($0 - options.speed) < abs($1 - options.speed) }) ?? 1.0
            },
            set: { options.speed = $0; liveSpeed = $0 }
        )
    }

    /// Speed label for the slider readout: "2×" for whole steps, "2.35×" else.
    private func speedText(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.2f×", s)
    }

    // MARK: - Buttons

    private var replayButton: some View {
        Button {
            if let recording = model.selectedRecording {
                model.playback.play(recording, options: options)
            }
        } label: {
            Label("Replay", systemImage: "play.fill").fixedSize()
        }
        .buttonStyle(WarmButtonStyle(color: Theme.sageButton))
        .disabled(model.playback.isBusy)
    }

    private var runInButton: some View {
        Button { showCountdownPopover = true } label: {
            Label("Run in…", systemImage: "timer").fixedSize()
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(model.playback.isBusy)
        .popover(isPresented: $showCountdownPopover) { countdownPopover }
    }

    private var scheduleButton: some View {
        Button { showScheduleSheet = true } label: {
            Label("Schedule…", systemImage: "calendar.badge.clock").fixedSize()
        }
        .buttonStyle(QuietButtonStyle())
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let recording = model.selectedRecording {
                model.requestDelete(id: recording.id)
            }
        } label: {
            Label("Delete", systemImage: "trash").fixedSize()
        }
        .buttonStyle(QuietButtonStyle())
        .help("Delete this recording")
        .accessibilityLabel("Delete this recording")
    }

    @ViewBuilder
    private var panicChip: some View {
        let ok = model.panicHotKeyRegistered
        HStack(spacing: 4) {
            if !ok {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.brick)
            }
            Text(ok ? "Panic stop: \(model.panicHotKeyDisplay)" : "Panic hotkey unavailable")
                .font(Theme.mono(11))
                .foregroundStyle(ok ? Theme.inkSecondary : Theme.ink)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.brick.opacity(ok ? 0.10 : 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.brick.opacity(ok ? 0.25 : 0.45), lineWidth: 1))
        .help(ok
              ? "Global panic-stop hotkey — aborts any replay instantly."
              : "\(model.panicHotKeyDisplay) is already used by another app, so the global panic hotkey isn't active. Change it in Settings ▸ Hotkeys. The Replay Stop button and the menu-bar Stop still work.")
    }

    // MARK: - Countdown popover

    private var countdownPopover: some View {
        VStack(spacing: Theme.spacing) {
            Text("Run after a countdown")
                .font(Theme.label(13))
            Stepper(value: $countdownSeconds, in: 1...300) {
                Text("\(countdownSeconds) seconds")
                    .font(Theme.mono(13))
                    .frame(minWidth: 90)
            }
            Button("Start Countdown") {
                showCountdownPopover = false
                if let recording = model.selectedRecording {
                    model.playback.play(recording, options: options, afterSeconds: countdownSeconds)
                }
            }
            .buttonStyle(WarmButtonStyle(color: Theme.amberButton))
        }
        .padding(16)
        .frame(width: 220)
    }
}

/// One shared speed formatter so every screen renders speeds identically.
enum SpeedFormat {
    static func label(_ speed: Double) -> String {
        if speed == floor(speed) { return "\(Int(speed))×" }
        // Drop the leading zero: 0.25 → .25×
        return "\(speed)×".replacingOccurrences(of: "0.", with: ".")
    }
}

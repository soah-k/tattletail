import SwiftUI

/// Standalone "Schedule a Replay" window: pick any recording from the library,
/// choose when it should run, how it repeats, and how many times it plays.
/// Reachable from the menu bar and the schedule-replay hotkey.
struct ScheduleComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRecordingID: UUID?
    @State private var fireDate = Date().addingTimeInterval(60)
    @State private var repeatRule: RepeatRule = .once
    @State private var repeatCount = 1
    @State private var loops = false
    @State private var speed = 1.0
    @State private var editingSchedule: Schedule?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if model.summaries.isEmpty {
                emptyState
            } else {
                composer
            }
        }
        .padding(Theme.sectionSpacing)
        .frame(width: 420)
        .background(Theme.background)
        .onAppear {
            if selectedRecordingID == nil {
                selectedRecordingID = model.summaries.first?.id
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            ScheduleSheet(editing: schedule)
        }
    }

    // MARK: - Empty library

    private var emptyState: some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(Theme.inkSecondary.opacity(0.6))
            Text("Nothing to schedule yet")
                .font(Theme.title(16))
                .foregroundStyle(Theme.ink)
            Text("Record something first — then come back here to put it on the calendar.")
                .font(Theme.body(12))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.sectionSpacing)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule a Replay")
                    .font(Theme.title(18))
                    .foregroundStyle(Theme.ink)
                Text("Tattletail must be running (even just in the menu bar) when the time comes.")
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.inkSecondary)
            }

            Picker("Recording", selection: $selectedRecordingID) {
                ForEach(model.summaries) { summary in
                    Text(summary.name).tag(Optional(summary.id))
                }
            }
            .pickerStyle(.menu)
            .font(Theme.body(13))

            DatePicker(
                "Run at",
                selection: $fireDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .font(Theme.body(13))

            Picker("Repeat", selection: $repeatRule) {
                ForEach(RepeatRule.allCases) { rule in
                    Text(rule.label).tag(rule)
                }
            }
            .pickerStyle(.menu)
            .font(Theme.body(13))

            HStack(spacing: Theme.spacing) {
                Text("Plays")
                    .font(Theme.body(13))
                Stepper(value: $repeatCount, in: 1...999) {
                    Text("\(repeatCount)×")
                        .font(Theme.mono(12))
                        .frame(minWidth: 32)
                }
                .disabled(loops)
                Toggle("Loop until stopped", isOn: $loops)
                    .toggleStyle(.checkbox)
                    .font(Theme.label(12))
                    .fixedSize()
                Spacer()
                Picker("Speed", selection: $speed) {
                    ForEach(PlaybackOptions.speedChoices, id: \.self) { choice in
                        Text(SpeedFormat.label(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") { schedule() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRecordingID == nil || fireDate <= Date())
            }

            upcomingList
        }
    }

    private func schedule() {
        guard let id = selectedRecordingID,
              let summary = model.summaries.first(where: { $0.id == id }) else { return }
        let schedule = Schedule(
            recordingID: id,
            recordingName: summary.name,
            fireDate: fireDate,
            repeatRule: repeatRule,
            options: PlaybackOptions(speed: speed, repeatCount: repeatCount, loops: loops)
        )
        model.scheduler.add(schedule)
        dismiss()
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingList: some View {
        let upcoming = model.scheduler.schedules
            .filter { !$0.completed }
            .sorted { $0.fireDate < $1.fireDate }
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Upcoming")
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.inkSecondary)
                ForEach(upcoming) { schedule in
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 11))
                            .foregroundStyle(schedule.isEnabled ? Theme.amber : Theme.inkSecondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(schedule.recordingName)
                                .font(Theme.label(12))
                                .foregroundStyle(Theme.ink)
                            Text(scheduleSubtitle(schedule))
                                .font(Theme.body(10.5))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Button {
                            editingSchedule = schedule
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                        .help("Edit this schedule's time and repeat")
                        .accessibilityLabel("Edit this schedule")
                        Button {
                            model.scheduler.remove(id: schedule.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                        .help("Delete this schedule")
                        .accessibilityLabel("Delete this schedule")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.inset)
                    )
                }
            }
        }
    }

    private func scheduleSubtitle(_ schedule: Schedule) -> String {
        var parts = [schedule.fireDate.formatted(.dateTime.weekday().month().day().hour().minute())]
        if schedule.repeatRule != .once { parts.append(schedule.repeatRule.label.lowercased()) }
        if schedule.options.loops {
            parts.append("loops")
        } else if schedule.options.repeatCount > 1 {
            parts.append("\(schedule.options.repeatCount)× plays")
        }
        if !schedule.isEnabled { parts.append("paused") }
        return parts.joined(separator: " · ")
    }
}

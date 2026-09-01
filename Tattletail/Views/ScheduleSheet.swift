import SwiftUI

/// Sheet for scheduling a recording to run at a specific date and time — used
/// both to create a new schedule and to edit an existing one's time and repeat.
struct ScheduleSheet: View {
    enum Mode {
        case create(recordingID: UUID, name: String, options: PlaybackOptions)
        case edit(Schedule)
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var fireDate: Date
    @State private var repeatRule: RepeatRule

    /// Create a schedule for a recording.
    init(recording: Recording, options: PlaybackOptions) {
        self.mode = .create(recordingID: recording.id, name: recording.name, options: options)
        _fireDate = State(initialValue: Date().addingTimeInterval(60))
        _repeatRule = State(initialValue: .once)
    }

    /// Edit an existing schedule's time and occurrence.
    init(editing schedule: Schedule) {
        self.mode = .edit(schedule)
        // A paused schedule's time may be in the past; start from a valid future
        // moment so the date picker (which is future-only) opens sensibly.
        _fireDate = State(initialValue: max(schedule.fireDate, Date().addingTimeInterval(60)))
        _repeatRule = State(initialValue: schedule.repeatRule)
    }

    private var isEditing: Bool { if case .edit = mode { return true }; return false }

    private var recordingName: String {
        switch mode {
        case .create(_, let name, _): return name
        case .edit(let s): return s.recordingName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(isEditing ? "Edit Schedule for" : "Schedule") “\(recordingName)”")
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.ink)
                Text("Tattletail must be running (even just in the menu bar) for scheduled replays to fire.")
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.inkSecondary)
            }

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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Schedule") { save() }
                    .buttonStyle(WarmButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(fireDate <= Date())
            }
        }
        .padding(Theme.sectionSpacing)
        .frame(width: 380)
        .background(Theme.background)
    }

    private func save() {
        switch mode {
        case .create(let recordingID, let name, let options):
            model.scheduler.add(Schedule(
                recordingID: recordingID,
                recordingName: name,
                fireDate: fireDate,
                repeatRule: repeatRule,
                options: options
            ))
        case .edit(var schedule):
            // Preserve id, enabled state, and playback options; update time +
            // occurrence. A fresh future time clears any "completed" state.
            schedule.fireDate = fireDate
            schedule.repeatRule = repeatRule
            schedule.completed = false
            model.scheduler.update(schedule)
        }
        dismiss()
    }
}

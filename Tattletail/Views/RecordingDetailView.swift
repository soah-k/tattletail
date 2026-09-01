import SwiftUI

/// Detail pane for a selected recording: header, replay controls, schedules,
/// and the editable, reorderable timeline.
struct RecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showScheduleSheet = false
    @State private var showCountdownPopover = false
    @State private var nameDraft = ""
    @State private var expandedBlocks: Set<UUID> = []
    @State private var editorRequest: EditorRequest?
    @State private var editingSchedule: Schedule?
    @State private var selection: Set<UUID> = []

    var body: some View {
        if let recording = model.selectedRecording {
            // Precomputed in the model and refreshed only when events change, so
            // scrolling/selecting a large recording doesn't rebuild the grouping.
            let items = model.selectedTimelineItems

            List(selection: $selection) {
                Section {
                    header(recording)
                    if let sig = recording.displaySignature, sig != DisplayLayout.signature() {
                        displayLayoutWarning
                    }
                    ReplayControlsView(
                        options: optionsBinding,
                        showScheduleSheet: $showScheduleSheet,
                        showCountdownPopover: $showCountdownPopover
                    )
                    schedulesSection(recording)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .selectionDisabled()

                Section {
                    if items.isEmpty {
                        Text("This recording is empty. Use Add Step to build one by hand.")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.inkSecondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(items) { item in
                        row(for: item, items: items)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
                    }
                    .onMove { from, to in performMove(items: items, from: from, to: to) }
                    .onDelete { offsets in performDelete(items: items, offsets: offsets) }
                } header: {
                    timelineHeader(insertIndex: recording.events.count, items: items)
                }
            }
            .onExitCommand {
                // Esc deselects highlighted steps.
                if !selection.isEmpty { selection.removeAll() }
            }
            .onChange(of: recording.id) { _, _ in
                // Switching recordings must not carry step selection/expansion over.
                selection.removeAll()
                expandedBlocks.removeAll()
            }
            .listStyle(.plain)
            // Give the List a per-recording identity so switching recordings
            // recreates it fresh at the top instead of keeping the previous
            // scroll offset.
            .id(recording.id)
            .environment(\.defaultMinListRowHeight, 30)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(isPresented: $showScheduleSheet) {
                ScheduleSheet(recording: recording, options: recording.playbackOptions)
            }
            .sheet(item: $editorRequest) { request in
                StepEditorSheet(mode: request.mode)
            }
            .sheet(item: $editingSchedule) { schedule in
                ScheduleSheet(editing: schedule)
            }
        }
    }

    /// Two-way binding to the selected recording's own replay settings, so the
    /// controls read and persist per-recording state (each recording keeps its
    /// own speed/repeat/loop) rather than a single view-local default that would
    /// bleed across selections.
    private var optionsBinding: Binding<PlaybackOptions> {
        Binding(
            get: { model.selectedPlaybackOptions },
            set: { model.setPlaybackOptions($0) }
        )
    }

    // MARK: - Timeline rows

    @ViewBuilder
    private func row(for item: TimelineItem, items: [TimelineItem]) -> some View {
        let isSelected = selection.contains(item.id)
        let count = selection.count
        let groupAction: (() -> Void)? = canGroupSelection(items) ? { groupSelection(items) } : nil
        if item.isBlock {
            TimelineBlockRow(
                item: item, expanded: $expandedBlocks,
                selectionCount: count, isSelected: isSelected,
                onDeleteSelection: { deleteSelection(items) },
                onGroupSelection: groupAction
            )
        } else if let event = item.events.first {
            TimelineStepRow(
                event: event,
                selectionCount: count, isSelected: isSelected,
                onDeleteSelection: { deleteSelection(items) },
                onGroupSelection: groupAction,
                onEdit: { editorRequest = EditorRequest(mode: .edit(event)) }
            )
        }
    }

    private func timelineHeader(insertIndex: Int, items: [TimelineItem]) -> some View {
        HStack {
            Text("Timeline")
                .font(Theme.label(12))
                .foregroundStyle(Theme.inkSecondary)
            Text(selection.isEmpty ? "· drag to reorder" : "· \(selection.count) selected")
                .font(Theme.body(11))
                .foregroundStyle(Theme.inkSecondary.opacity(0.7))
            Spacer()
            if canGroupSelection(items) {
                Button { groupSelection(items) } label: {
                    Label("Group", systemImage: "square.stack.3d.up")
                        .font(Theme.label(12))
                }
                .buttonStyle(.plain)
                .help("Group the selected steps into one collapsible block")
            }
            if !selection.isEmpty {
                Button(role: .destructive) { deleteSelection(items) } label: {
                    Label("Delete", systemImage: "trash")
                        .font(Theme.label(12))
                }
                .buttonStyle(.plain)
                .help("Delete the selected steps")
            }
            Menu {
                ForEach(StepTemplate.allCases) { template in
                    Button {
                        editorRequest = EditorRequest(mode: .create(template, insertIndex: insertIndex))
                    } label: {
                        Label(template.label, systemImage: template.symbol)
                    }
                }
            } label: {
                Label("Add Step", systemImage: "plus")
                    .font(Theme.label(12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    /// Grouping is offered only for a contiguous run of two or more selected
    /// rows — the same shape as an auto-grouped block, so it stays one clean run.
    private func canGroupSelection(_ items: [TimelineItem]) -> Bool {
        let idx = items.enumerated()
            .filter { selection.contains($0.element.id) }
            .map(\.offset)
        guard idx.count >= 2 else { return false }
        return (idx.max()! - idx.min()! + 1) == idx.count
    }

    private func groupSelection(_ items: [TimelineItem]) {
        let ids = Set(items.filter { selection.contains($0.id) }.flatMap { $0.events.map(\.id) })
        model.groupEvents(ids: ids)
        selection.removeAll()
    }

    private func deleteSelection(_ items: [TimelineItem]) {
        let ids = Set(items.filter { selection.contains($0.id) }.flatMap { $0.events.map(\.id) })
        guard !ids.isEmpty else { return }
        model.removeEvents(ids: ids)
        selection.removeAll()
    }

    private func performMove(items: [TimelineItem], from: IndexSet, to: Int) {
        var reordered = items
        reordered.move(fromOffsets: from, toOffset: to)
        model.replaceTimeline(with: reordered.flatMap { $0.events })
    }

    private func performDelete(items: [TimelineItem], offsets: IndexSet) {
        let ids = offsets.flatMap { items[$0].events.map(\.id) }
        model.removeEvents(ids: Set(ids))
    }

    private var displayLayoutWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            Text("Your display arrangement changed since this was recorded. It uses absolute screen positions, so clicks may land in the wrong place — re-record if it misbehaves.")
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.12)))
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Edit a local draft and commit once — writing the whole recording
            // to disk on every keystroke (and round-tripping the trimmed name
            // back into the field) made typing laggy and ate spaces.
            TextField("Name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(Theme.title(24))
                .foregroundStyle(Theme.ink)
                .onSubmit { commitRename(recording) }
                .onAppear { nameDraft = recording.name }
                .onChange(of: recording.id) { nameDraft = recording.name }
                .onDisappear { commitRename(recording) }
            HStack(spacing: 10) {
                Text(recording.createdAt, style: .date)
                Text("·")
                Text(durationString(recording.duration))
                Text("·")
                Text(recording.breakdown)
                if recording.events.contains(where: { $0.hasWindowAnchor }) {
                    Text("·")
                    Label("window-relative", systemImage: "macwindow")
                        .help("Some clicks are anchored to their window and follow it on replay.")
                }
                if recording.totalRuns > 0 {
                    Text("·")
                    if recording.runCount != recording.totalRuns {
                        // A reset happened, so distinguish lifetime from current.
                        Text("\(runsText(recording.totalRuns)) all-time")
                        Text("·")
                        Text("\(recording.runCount) since reset")
                    } else {
                        Text(runsText(recording.totalRuns))
                    }
                }
            }
            .font(Theme.body(12))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    private func commitRename(_ recording: Recording) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.name else { return }
        model.rename(id: recording.id, to: trimmed)
    }

    // MARK: - Schedules

    @ViewBuilder
    private func schedulesSection(_ recording: Recording) -> some View {
        let schedules = model.scheduler.schedules(forRecording: recording.id)
        if !schedules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduled")
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.inkSecondary)
                ForEach(schedules) { schedule in
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(Theme.amber)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(schedule.fireDate, format: .dateTime.weekday(.wide).month().day().hour().minute())
                                .font(Theme.label(12.5))
                                .foregroundStyle(Theme.ink)
                            if schedule.repeatRule != .once {
                                Text(schedule.repeatRule.label)
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(schedule))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .accessibilityLabel("Schedule enabled")
                        Button {
                            editingSchedule = schedule
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                        .help("Edit this schedule's time and repeat")
                        .accessibilityLabel("Edit this schedule")
                        Button {
                            model.scheduler.remove(id: schedule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                        .help("Delete this schedule")
                        .accessibilityLabel("Delete this schedule")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .card()
                }
            }
        }
    }

    private func enabledBinding(_ schedule: Schedule) -> Binding<Bool> {
        Binding(
            get: {
                model.scheduler.schedules.first { $0.id == schedule.id }?.isEnabled ?? false
            },
            set: { newValue in
                guard var current = model.scheduler.schedules.first(where: { $0.id == schedule.id }) else { return }
                current.isEnabled = newValue
                model.scheduler.update(current)
            }
        )
    }

    private func durationString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "—" }
        if t < 60 { return String(format: "%.1fs", t) }
        let whole = Int(min(t, 8.64e6))   // cap so Int() can't trap on a huge value
        return String(format: "%dm %02ds", whole / 60, whole % 60)
    }

    private func runsText(_ n: Int) -> String {
        "\(n) run\(n == 1 ? "" : "s")"
    }
}

/// Wraps an editor invocation so it can drive `.sheet(item:)`.
private struct EditorRequest: Identifiable {
    let id = UUID()
    let mode: StepEditorSheet.Mode
}

import SwiftUI

/// How a timeline row was formed.
enum TimelineItemKind: Equatable {
    case standalone            // a single discrete step
    case lowLevelBlock         // auto-grouped consecutive cursor moves / modifiers
    case group(UUID)           // a manual group the user created
}

/// One row in the editable timeline: either a single discrete step, or a
/// collapsible block — auto-formed from consecutive low-level events (cursor
/// moves / modifier flickers), or a manual group the user grouped by hand.
struct TimelineItem: Identifiable {
    let id: UUID          // step: the event's id; block: its first event's id
    let events: [RecordedEvent]
    let kind: TimelineItemKind

    var isBlock: Bool {
        switch kind {
        case .standalone: return false
        case .lowLevelBlock, .group: return true
        }
    }
    var isEnabled: Bool { events.contains { $0.enabled } }
    var groupID: UUID? { if case .group(let g) = kind { return g }; return nil }
    var groupName: String? { events.first?.groupName }
}

/// Build display rows: consecutive steps sharing a manual `groupID` collapse into
/// one group block; consecutive low-level events (≥1) collapse into an auto
/// block; everything else is its own step row.
func buildTimelineItems(_ events: [RecordedEvent]) -> [TimelineItem] {
    var items: [TimelineItem] = []
    var run: [RecordedEvent] = []
    var runKind: TimelineItemKind = .standalone

    func flush() {
        guard !run.isEmpty else { return }
        items.append(TimelineItem(id: run[0].id, events: run, kind: runKind))
        run.removeAll()
    }

    for event in events {
        if let gid = event.groupID {
            if case .group(gid) = runKind { run.append(event) }
            else { flush(); run = [event]; runKind = .group(gid) }
        } else if event.isLowLevel {
            if case .lowLevelBlock = runKind { run.append(event) }
            else { flush(); run = [event]; runKind = .lowLevelBlock }
        } else {
            flush()
            items.append(TimelineItem(id: event.id, events: [event], kind: .standalone))
        }
    }
    flush()
    // A lone low-level event isn't worth a collapsible block — show it as a step.
    return items.map { item in
        if case .lowLevelBlock = item.kind, item.events.count == 1 {
            return TimelineItem(id: item.id, events: item.events, kind: .standalone)
        }
        return item
    }
}

// MARK: - Step row

struct TimelineStepRow: View {
    @EnvironmentObject private var model: AppModel
    let event: RecordedEvent
    var selectionCount: Int = 0
    var isSelected: Bool = false
    var onDeleteSelection: () -> Void = {}
    var onGroupSelection: (() -> Void)? = nil
    let onEdit: () -> Void

    /// True when this row is part of a live multi-selection.
    private var inMultiSelection: Bool { selectionCount > 1 && isSelected }

    // When selected, the row background clears so the system accent shows, and
    // text/icons switch to semantic styles that auto-contrast on any accent.
    private var titleStyle: AnyShapeStyle { isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.ink) }
    private var secondaryStyle: AnyShapeStyle { isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.inkSecondary) }
    private var iconStyle: AnyShapeStyle { isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(tint) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(event.enabled ? "Enabled — included on replay" : "Disabled — skipped on replay")
                .accessibilityLabel("Include this step on replay")

            Image(systemName: event.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(iconStyle)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.summary)
                        .font(Theme.body(12.5))
                        .foregroundStyle(titleStyle)
                        .strikethrough(!event.enabled, color: Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let x = event.x, let y = event.y, event.kind != .scroll {
                        Text(String(format: "(%.0f, %.0f)", x, y))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(secondaryStyle)
                    }
                    if event.hasWindowAnchor {
                        Image(systemName: "macwindow")
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryStyle)
                            .help("Window-relative — anchored to “\(event.windowTitle ?? event.windowBundleId ?? "its window")”")
                    }
                }
                if let name = event.name, !name.isEmpty {
                    Text(name)
                        .font(Theme.body(10.5))
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Text(String(format: "%.2fs", event.offset))
                .font(Theme.mono(10.5))
                .foregroundStyle(secondaryStyle)

            Button { model.duplicateEvent(id: event.id) } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryStyle)
            .help("Duplicate this step")
            .accessibilityLabel("Duplicate this step")

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryStyle)
            .help("Edit this step")
            .accessibilityLabel("Edit this step")
        }
        .opacity(event.enabled ? 1 : 0.45)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.clear : Theme.surface)
        )
        .contentShape(Rectangle())
        .contextMenu {
            if inMultiSelection {
                if let onGroupSelection {
                    Button("Group \(selectionCount) Selected") { onGroupSelection() }
                }
                Button("Delete \(selectionCount) Selected", role: .destructive) { onDeleteSelection() }
            } else {
                Button("Edit…", action: onEdit)
                Button("Duplicate") { model.duplicateEvent(id: event.id) }
                Button(event.enabled ? "Disable" : "Enable") {
                    model.setEventsEnabled(ids: [event.id], enabled: !event.enabled)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    model.removeEvents(ids: [event.id])
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { event.enabled },
            set: { model.setEventsEnabled(ids: [event.id], enabled: $0) }
        )
    }

    private var tint: Color {
        switch event.kind {
        case .appActivate: return Theme.amber
        case .delay: return Theme.sage
        case .mouseDown, .mouseUp: return Theme.accent
        default: return Theme.inkSecondary
        }
    }
}

// MARK: - Block row (auto low-level block or manual group)

struct TimelineBlockRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @Binding var expanded: Set<UUID>
    var selectionCount: Int = 0
    var isSelected: Bool = false
    var onDeleteSelection: () -> Void = {}
    var onGroupSelection: (() -> Void)? = nil
    @State private var showRename = false
    @State private var renameText = ""

    private var isExpanded: Bool { expanded.contains(item.id) }
    private var isManualGroup: Bool { item.groupID != nil }
    private var inMultiSelection: Bool { selectionCount > 1 && isSelected }

    /// Max child rows drawn inline when a block is expanded, so expanding a
    /// movement-heavy block can't render thousands of subviews in one row and
    /// jank scrolling.
    private static let expandedChildCap = 200

    private var titleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(isManualGroup ? Theme.ink : Theme.inkSecondary)
    }
    private var secondaryStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.inkSecondary)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 10) {
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help("Enable or disable this whole block on replay")
                    .accessibilityLabel("Include this block on replay")

                Button {
                    if isExpanded { expanded.remove(item.id) } else { expanded.insert(item.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                        if isManualGroup {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 10))
                                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.accent))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(Theme.body(12))
                                .foregroundStyle(titleStyle)
                            Text(subtitle)
                                .font(Theme.body(10.5))
                                .foregroundStyle(secondaryStyle)
                        }
                        Spacer()
                        Text(String(format: "%.2fs – %.2fs",
                                    item.events.first?.offset ?? 0, item.events.last?.offset ?? 0))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(secondaryStyle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse block" : "Expand block")

                Button { model.duplicateEvents(ids: Set(item.events.map(\.id))) } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryStyle)
                .help("Duplicate this block")
                .accessibilityLabel("Duplicate this block")
            }
            .opacity(item.isEnabled ? 1 : 0.45)

            if isExpanded {
                ForEach(Array(item.events.prefix(Self.expandedChildCap))) { sample in
                    HStack(spacing: 8) {
                        Image(systemName: sample.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryStyle)
                            .frame(width: 16)
                        Text(sample.summary)
                            .font(Theme.body(11))
                            .foregroundStyle(secondaryStyle)
                        if let x = sample.x, let y = sample.y {
                            Text(String(format: "(%.0f, %.0f)", x, y))
                                .font(Theme.mono(10))
                                .foregroundStyle(secondaryStyle)
                        }
                        Spacer()
                        Button {
                            model.removeEvents(ids: [sample.id])
                        } label: {
                            Image(systemName: "trash").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(secondaryStyle)
                        .help("Delete this step")
                        .accessibilityLabel("Delete this step")
                    }
                    .padding(.leading, 30)
                    .padding(.vertical, 1)
                }
                if item.events.count > Self.expandedChildCap {
                    Text("+ \(item.events.count - Self.expandedChildCap) more steps — collapse to hide")
                        .font(Theme.body(10.5))
                        .foregroundStyle(secondaryStyle)
                        .padding(.leading, 30)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                      ? Color.clear
                      : (isManualGroup ? Theme.accent.opacity(0.06) : Theme.surface.opacity(0.5)))
        )
        .contextMenu {
            if inMultiSelection {
                if let onGroupSelection {
                    Button("Group \(selectionCount) Selected") { onGroupSelection() }
                }
                Button("Delete \(selectionCount) Selected", role: .destructive) { onDeleteSelection() }
            } else {
                if isManualGroup, let gid = item.groupID {
                    Button("Rename Group…") { renameText = item.groupName ?? ""; showRename = true }
                    Button("Ungroup") { model.ungroup(groupID: gid) }
                    Divider()
                }
                Button("Duplicate \(isManualGroup ? "Group" : "Block")") {
                    model.duplicateEvents(ids: Set(item.events.map(\.id)))
                }
                Button(item.isEnabled ? "Disable \(blockNoun)" : "Enable \(blockNoun)") {
                    model.setEventsEnabled(ids: Set(item.events.map(\.id)), enabled: !item.isEnabled)
                }
                Divider()
                Button("Delete \(blockNoun)", role: .destructive) {
                    model.removeEvents(ids: Set(item.events.map(\.id)))
                }
            }
        }
        .alert("Name this group", isPresented: $showRename) {
            TextField("Group name", text: $renameText)
            Button("Save") {
                if let gid = item.groupID { model.renameGroup(groupID: gid, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var blockNoun: String { isManualGroup ? "Group" : "Block" }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { item.isEnabled },
            set: { model.setEventsEnabled(ids: Set(item.events.map(\.id)), enabled: $0) }
        )
    }

    /// The bold line: a manual group's name (or a default), else the auto count.
    private var title: String {
        if isManualGroup { return item.groupName ?? "Group" }
        return countSummary
    }

    /// The muted line: for a manual group, the step count; auto blocks show it
    /// as the title, so leave the subtitle blank.
    private var subtitle: String {
        isManualGroup ? "\(item.events.count) step\(item.events.count == 1 ? "" : "s")" : ""
    }

    private var countSummary: String {
        let moves = item.events.filter { $0.kind == .mouseMove }.count
        let flags = item.events.filter { $0.kind == .flagsChanged }.count
        var parts: [String] = []
        if moves > 0 { parts.append("\(moves) movement\(moves == 1 ? "" : "s")") }
        if flags > 0 { parts.append("\(flags) modifier change\(flags == 1 ? "" : "s")") }
        return parts.isEmpty ? "\(item.events.count) events" : parts.joined(separator: ", ")
    }
}

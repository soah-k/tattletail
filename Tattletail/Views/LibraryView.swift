import SwiftUI

/// How the library list is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case updated, name, created, mostRun, longest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .updated: return "Recently updated"
        case .name: return "Name (A–Z)"
        case .created: return "Date created"
        case .mostRun: return "Most runs"
        case .longest: return "Longest"
        }
    }
}

#if !FREE_BUILD
/// Create-or-rename target for the folder-name alert. (Folders are paid.)
private enum FolderNamingMode {
    case create(moveIDs: Set<UUID>?)
    case rename(id: UUID)
}
#endif

/// Sidebar: the searchable, sortable library of saved recordings — with
/// multi-select bulk actions. In the paid edition recordings are grouped into
/// collapsible folders and can be exported/moved; the free edition shows a flat
/// list (Folders and Import/Export are paid).
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var selection: Set<UUID> = []
    @State private var pendingBulkDelete: Set<UUID> = []
    @State private var showBulkDelete = false
    #if !FREE_BUILD
    @State private var collapsedFolders: Set<UUID> = []
    @State private var unfiledCollapsed = false
    @State private var showFolderNameAlert = false
    @State private var folderNameText = ""
    @State private var folderNamingMode: FolderNamingMode = .create(moveIDs: nil)
    @State private var pendingDeleteFolder: Folder?
    @State private var showDeleteFolder = false
    #endif
    @AppStorage("librarySort") private var sortRaw = LibrarySort.updated.rawValue

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .updated }
    private var isSearching: Bool { !searchText.isEmpty }

    private func applySort(_ base: [RecordingSummary]) -> [RecordingSummary] {
        switch sort {
        case .updated: return base.sorted { $0.updatedAt > $1.updatedAt }
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created: return base.sorted { $0.createdAt > $1.createdAt }
        case .mostRun: return base.sorted { $0.totalRuns > $1.totalRuns }
        case .longest: return base.sorted { $0.duration > $1.duration }
        }
    }

    private var searchResults: [RecordingSummary] {
        applySort(model.summaries.filter { $0.name.localizedCaseInsensitiveContains(searchText) })
    }

    #if !FREE_BUILD
    private var sortedFolders: [Folder] {
        model.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func recordings(in folderID: UUID?) -> [RecordingSummary] {
        applySort(model.summaries.filter { $0.folderID == folderID })
    }

    private var liveFolderIDs: Set<UUID> { Set(model.folders.map(\.id)) }

    /// Unfiled = no folder OR a dangling folderID (its folder was lost), so no
    /// recording can ever render in zero sections and appear to vanish.
    private func unfiledItems() -> [RecordingSummary] {
        applySort(model.summaries.filter { $0.folderID == nil || !liveFolderIDs.contains($0.folderID!) })
    }
    #endif

    /// Whether the recording's row is currently in the rendered list (matching any
    /// active search, and — in the paid build — its folder expanded).
    private func rowVisible(_ id: UUID) -> Bool {
        guard let s = model.summaries.first(where: { $0.id == id }) else { return false }
        if isSearching { return s.name.localizedCaseInsensitiveContains(searchText) }
        #if FREE_BUILD
        return true
        #else
        if let fid = s.folderID, liveFolderIDs.contains(fid) { return !collapsedFolders.contains(fid) }
        return !unfiledCollapsed
        #endif
    }

    /// The List prunes the highlighted id from `selection` when its row leaves
    /// the rendered set (folder collapsed / filtered by search); re-derive the
    /// single-selection highlight from the model once the row is visible again.
    private func restoreHighlightIfNeeded() {
        guard selection.count <= 1, let id = model.selectedRecordingID,
              rowVisible(id), selection != [id] else { return }
        selection = [id]
    }

    private var hasContent: Bool {
        #if FREE_BUILD
        return !model.summaries.isEmpty
        #else
        return !model.summaries.isEmpty || !model.folders.isEmpty
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasContent {
                topBar
                Divider()
            }
            list
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search recordings")
        .background(Theme.background)
        .overlay { if !hasContent { emptyState } }
        .onChange(of: selection) { _, sel in
            if sel.count == 1, let id = sel.first, model.selectedRecordingID != id {
                model.selectRecording(id: id)
            }
        }
        .onChange(of: model.selectedRecordingID) { _, id in
            if let id, selection != [id] { selection = [id] }
        }
        .onAppear { if let id = model.selectedRecordingID { selection = [id] } }
        #if !FREE_BUILD
        .onChange(of: collapsedFolders) { _, _ in restoreHighlightIfNeeded() }
        .onChange(of: unfiledCollapsed) { _, _ in restoreHighlightIfNeeded() }
        #endif
        .onChange(of: searchText) { _, _ in restoreHighlightIfNeeded() }
        .onChange(of: model.summaries) { _, _ in restoreHighlightIfNeeded() }
        .onExitCommand {
            if selection.count > 1 {
                selection = model.selectedRecordingID.map { [$0] } ?? []
            }
        }
        .alert("Rename Recording", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renamingID { model.rename(id: id, to: renameText) }
                renamingID = nil
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
        #if !FREE_BUILD
        .alert(folderAlertTitle, isPresented: $showFolderNameAlert) {
            TextField("Folder name", text: $folderNameText)
            Button("Save") { commitFolderName() }
                .disabled(folderNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        #endif
        .confirmationDialog(bulkDeleteTitle, isPresented: $showBulkDelete, titleVisibility: .visible) {
            Button("Delete \(pendingBulkDelete.count) Recordings", role: .destructive) {
                model.deleteRecordings(ids: pendingBulkDelete)
                selection.subtract(pendingBulkDelete)
                pendingBulkDelete = []
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = [] }
        } message: {
            Text("These recordings and any schedules for them will be gone for good.")
        }
        #if !FREE_BUILD
        .confirmationDialog(
            "Delete folder “\(pendingDeleteFolder?.name ?? "")”?",
            isPresented: $showDeleteFolder,
            titleVisibility: .visible,
            presenting: pendingDeleteFolder
        ) { folder in
            Button("Delete Folder", role: .destructive) { model.deleteFolder(id: folder.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The folder is removed. Its recordings aren't deleted — they move to Unfiled.")
        }
        #endif
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if isSearching {
                Section {
                    ForEach(searchResults) { row($0) }
                } header: {
                    Text("Results").font(Theme.label(11)).foregroundStyle(Theme.inkSecondary)
                }
            } else {
                #if FREE_BUILD
                ForEach(applySort(model.summaries)) { row($0) }
                #else
                ForEach(sortedFolders) { folder in folderSection(folder) }
                unfiledSection
                #endif
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    #if !FREE_BUILD
    private func folderSection(_ folder: Folder) -> some View {
        // Compute the rows once and reuse the count in the header (avoids a
        // second filter + sort per folder on every render).
        let items = recordings(in: folder.id)
        // Native collapsible section (the sidebar draws the disclosure control),
        // so we don't fight the List's own section-collapse behavior.
        return Section(isExpanded: folderExpansion(folder.id)) {
            if items.isEmpty {
                Text("Empty — move recordings here")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.inkSecondary.opacity(0.7))
                    .selectionDisabled()
            } else {
                ForEach(items) { row($0) }
            }
        } header: {
            folderHeaderLabel(name: folder.name, count: items.count, systemImage: "folder")
                .contextMenu {
                    Button("Rename Folder…") { startRenameFolder(folder) }
                    Button("Delete Folder", role: .destructive) {
                        pendingDeleteFolder = folder; showDeleteFolder = true
                    }
                }
        }
    }

    @ViewBuilder
    private var unfiledSection: some View {
        let items = unfiledItems()
        if !items.isEmpty {
            Section(isExpanded: Binding(get: { !unfiledCollapsed }, set: { unfiledCollapsed = !$0 })) {
                ForEach(items) { row($0) }
            } header: {
                folderHeaderLabel(name: "Unfiled", count: items.count, systemImage: "tray")
            }
        }
    }

    private func folderExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(id) },
            set: { expanded in
                if expanded { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
            }
        )
    }

    private func folderHeaderLabel(name: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(name).font(Theme.label(11))
            Text("\(count)").font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary.opacity(0.8))
            Spacer()
        }
        .foregroundStyle(Theme.inkSecondary)
    }
    #endif

    private func row(_ summary: RecordingSummary) -> some View {
        LibraryRow(summary: summary, isSelected: selection.contains(summary.id))
            .tag(summary.id)
            .contextMenu { contextMenu(for: summary) }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for summary: RecordingSummary) -> some View {
        if selection.count > 1 && selection.contains(summary.id) {
            #if !FREE_BUILD
            moveMenu(ids: selection)
            Button("Export \(selection.count) Recordings…") { model.exportRecordings(ids: Array(selection)) }
            #endif
            Button("Duplicate \(selection.count) Recordings") { model.duplicateRecordings(ids: selection) }
            Divider()
            Button("Delete \(selection.count) Recordings", role: .destructive) {
                pendingBulkDelete = selection; showBulkDelete = true
            }
        } else {
            Button("Rename…") { renamingID = summary.id; renameText = summary.name }
            #if !FREE_BUILD
            moveMenu(ids: [summary.id])
            #endif
            Button("Duplicate") { model.duplicate(id: summary.id) }
            #if !FREE_BUILD
            Button("Export…") { model.exportRecordings(ids: [summary.id]) }
            #endif
            if summary.runCount > 0 {
                Button("Reset Run Count") { model.resetRunCount(id: summary.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.requestDelete(id: summary.id) }
        }
    }

    #if !FREE_BUILD
    private func moveMenu(ids: Set<UUID>) -> some View {
        Menu("Move to") {
            Button("Unfiled") { model.moveRecordings(ids: ids, toFolder: nil) }
            if !sortedFolders.isEmpty { Divider() }
            ForEach(sortedFolders) { folder in
                Button(folder.name) { model.moveRecordings(ids: ids, toFolder: folder.id) }
            }
            Divider()
            Button("New Folder…") { startNewFolder(moveIDs: ids) }
        }
    }
    #endif

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            sortMenu
            Spacer()
            #if !FREE_BUILD
            Button { startNewFolder(moveIDs: nil) } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .help("New Folder")
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(LibrarySort.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                Text(sort.label).font(Theme.label(11))
            }
            .foregroundStyle(Theme.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort recordings")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(Theme.inkSecondary.opacity(0.6))
            Text("No recordings yet")
                .font(Theme.body(12))
                .foregroundStyle(Theme.inkSecondary)
            Button("New Blank Recording") { model.createBlankRecording() }
                .buttonStyle(.link)
                .font(Theme.body(11))
                .help("Create an empty recording and build it step by step")
        }
    }

    // MARK: - Folder helpers

    #if !FREE_BUILD
    private func startNewFolder(moveIDs: Set<UUID>?) {
        folderNamingMode = .create(moveIDs: moveIDs)
        folderNameText = ""
        showFolderNameAlert = true
    }

    private func startRenameFolder(_ folder: Folder) {
        folderNamingMode = .rename(id: folder.id)
        folderNameText = folder.name
        showFolderNameAlert = true
    }

    private func commitFolderName() {
        switch folderNamingMode {
        case .create(let moveIDs):
            if let folder = model.createFolder(name: folderNameText), let moveIDs, !moveIDs.isEmpty {
                model.moveRecordings(ids: moveIDs, toFolder: folder.id)
            }
        case .rename(let id):
            model.renameFolder(id: id, to: folderNameText)
        }
    }

    private var folderAlertTitle: String {
        if case .rename = folderNamingMode { return "Rename Folder" }
        return "New Folder"
    }
    #endif

    private var bulkDeleteTitle: String { "Delete \(pendingBulkDelete.count) recordings?" }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )
    }
}

struct LibraryRow: View {
    @EnvironmentObject private var model: AppModel
    let summary: RecordingSummary
    /// Passed from the list's selection set. When selected, use the system's
    /// semantic styles so the text auto-contrasts against WHATEVER accent color
    /// the row highlight uses (dark text on light accents like Yellow, white on
    /// dark accents like Blue) — in both light and dark mode.
    var isSelected: Bool = false

    private var titleStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.ink)
    }
    private var metaStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.inkSecondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(summary.name)
                    .font(Theme.label(13))
                    .foregroundStyle(titleStyle)
                    .lineLimit(1)
                scheduleBadge
            }
            HStack(spacing: 6) {
                Label(durationString, systemImage: "clock")
                Label("\(summary.eventCount)", systemImage: "list.bullet")
                if summary.appActivationCount > 0 {
                    Label("\(summary.appActivationCount)", systemImage: "app.badge")
                }
                if summary.totalRuns > 0 {
                    Label("\(summary.totalRuns)", systemImage: "clock.arrow.circlepath")
                        .help("\(summary.totalRuns) run\(summary.totalRuns == 1 ? "" : "s") all-time")
                }
            }
            .font(Theme.body(10.5))
            .foregroundStyle(metaStyle)
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    // Scheduling is a free feature, so the schedule badge stays in both editions.
    @ViewBuilder
    private var scheduleBadge: some View {
        switch model.scheduleState(for: summary.id) {
        case .active:
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.amber))
                .help("Has an active schedule")
        case .paused:
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.inkSecondary.opacity(0.6)))
                .help("Has a paused schedule")
        case .none:
            EmptyView()
        }
    }

    private var durationString: String {
        let t = summary.duration
        guard t.isFinite, t >= 0 else { return "—" }
        if t < 60 { return String(format: "%.0fs", t) }
        let whole = Int(min(t, 8.64e6))   // cap so Int() can't trap on a huge value
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Tight icon+text label for metadata rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

import Foundation

/// Persists recordings as one JSON file each under Application Support, plus a
/// lightweight `library.json` index for instant list rendering and a
/// `schedules.json` for saved schedules.
///
/// Layout:
/// ```
/// ~/Library/Application Support/Tattletail/
///   Recordings/<uuid>.json
///   library.json
///   schedules.json
/// ```
final class RecordingStore: @unchecked Sendable {
    private let fileManager: FileManager
    // These are `internal` (not `private`) so the paid-only `RecordingStore+Paid`
    // extension (history/folders persistence, a separate file excluded from the
    // free build) can reuse them. Everything else stays private.
    let rootURL: URL
    let queue = DispatchQueue(label: "com.soahk.Tattletail.store")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var recordingsURL: URL { rootURL.appendingPathComponent("Recordings", isDirectory: true) }
    private var libraryIndexURL: URL { rootURL.appendingPathComponent("library.json") }
    private var schedulesURL: URL { rootURL.appendingPathComponent("schedules.json") }

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = appSupport.appendingPathComponent("Tattletail", isDirectory: true)
        }
        try? fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        // Recordings can contain typed text (keystrokes). Keep the store
        // owner-only and out of backups so it isn't casually readable or copied.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsURL.path)
        excludeFromBackup(self.rootURL)
    }

    /// Restrict a written file to owner read/write only (0600). `internal` so the
    /// paid-only `RecordingStore+Paid` extension can reuse it.
    func lockDown(_ url: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Keep the store out of Time Machine / iCloud backups.
    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Recordings

    /// - Parameter touch: when true (default), stamps `updatedAt = now` and
    ///   recomputes cached metadata. Pass false for changes that shouldn't count
    ///   as an edit (e.g. bumping the run counter) so the library doesn't reorder.
    func save(_ recording: Recording, touch: Bool = true) throws {
        var toSave = recording
        if touch { toSave.touch() }
        let data = try encoder.encode(toSave)
        let url = fileURL(for: recording.id)
        try queue.sync {
            try data.write(to: url, options: .atomic)
            lockDown(url)
            try updateIndexLocked { index in
                index.removeAll { $0.id == toSave.id }
                index.append(toSave.summary)
            }
        }
    }

    func load(id: UUID) throws -> Recording {
        let data = try Data(contentsOf: fileURL(for: id))
        return try decoder.decode(Recording.self, from: data).migrated()
    }

    func delete(id: UUID) throws {
        try queue.sync {
            let url = fileURL(for: id)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try updateIndexLocked { index in
                index.removeAll { $0.id == id }
            }
        }
    }

    func duplicate(id: UUID) throws -> Recording {
        let original = try load(id: id)
        var copy = Recording(name: original.name + " copy", events: original.events)
        copy.playbackOptions = original.playbackOptions
        copy.folderID = original.folderID
        copy.touch()
        try save(copy)
        return copy
    }

    /// Fast listing from the index; falls back to rebuilding by scanning the
    /// Recordings folder if the index is missing or unreadable.
    func listSummaries() -> [RecordingSummary] {
        queue.sync {
            if let data = try? Data(contentsOf: libraryIndexURL),
               let index = try? decoder.decode([RecordingSummary].self, from: data) {
                return index.sorted { $0.updatedAt > $1.updatedAt }
            }
            let rebuilt = rebuildIndexLocked()
            return rebuilt.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Rebuild the index if it has drifted from the Recordings folder — e.g. a
    /// crash between writing a recording file and updating library.json left a
    /// recording invisible (or a stale entry behind). Cheap: it compares ids from
    /// filenames (no decode) and only rebuilds on a mismatch.
    func reconcileIndexIfNeeded() {
        queue.sync {
            let folderIDs = recordingFileIDsLocked()
            var indexIDs: Set<UUID> = []
            if let data = try? Data(contentsOf: libraryIndexURL),
               let index = try? decoder.decode([RecordingSummary].self, from: data) {
                indexIDs = Set(index.map(\.id))
            }
            if folderIDs != indexIDs {
                _ = rebuildIndexLocked()
            }
        }
    }

    /// Ids of the recording files on disk, from their `<uuid>.json` names (no
    /// decode). Must be called on `queue`.
    private func recordingFileIDsLocked() -> Set<UUID> {
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsURL, includingPropertiesForKeys: nil
        ) else { return [] }
        var ids: Set<UUID> = []
        for url in files where url.pathExtension == "json" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Schedules

    func saveSchedules(_ schedules: [Schedule]) throws {
        let data = try encoder.encode(schedules)
        try queue.sync {
            try data.write(to: schedulesURL, options: .atomic)
            lockDown(schedulesURL)
        }
    }

    func loadSchedules() -> [Schedule] {
        queue.sync {
            guard let data = try? Data(contentsOf: schedulesURL),
                  let schedules = try? decoder.decode([Schedule].self, from: data) else {
                return []
            }
            return schedules
        }
    }

    // Run history and folders persistence live in the paid-only
    // `RecordingStore+Paid` extension (excluded from the free build). Schedules
    // persistence stays above — scheduling is a free feature.

    // MARK: - Private

    private func fileURL(for id: UUID) -> URL {
        recordingsURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// Must be called on `queue`.
    private func updateIndexLocked(_ mutate: (inout [RecordingSummary]) -> Void) throws {
        var index: [RecordingSummary] = []
        if let data = try? Data(contentsOf: libraryIndexURL),
           let existing = try? decoder.decode([RecordingSummary].self, from: data) {
            index = existing
        }
        mutate(&index)
        let data = try encoder.encode(index)
        try data.write(to: libraryIndexURL, options: .atomic)
        lockDown(libraryIndexURL)
    }

    /// Must be called on `queue`.
    private func rebuildIndexLocked() -> [RecordingSummary] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsURL, includingPropertiesForKeys: nil
        ) else { return [] }

        var summaries: [RecordingSummary] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let recording = try? decoder.decode(Recording.self, from: data) {
                summaries.append(recording.summary)
            }
        }
        if let data = try? encoder.encode(summaries) {
            try? data.write(to: libraryIndexURL, options: .atomic)
            lockDown(libraryIndexURL)
        }
        return summaries
    }
}

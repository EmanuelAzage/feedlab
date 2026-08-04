import Foundation

/// One completed session, as it is persisted.
///
/// Carries **both** the folded records and the raw events they were folded from. That redundancy is
/// the point, and it is the persistence half of a decision `SessionRecorder` already makes: records
/// are a *projection* of events, so keeping the events means a metric definition can change and be
/// re-derived against runs already performed. Dropping them here would quietly make every device
/// session unrepeatable — and device sessions are the expensive thing this project produces.
///
/// A test asserts the invariant across the boundary: re-folding the persisted events reproduces the
/// persisted records.
struct StoredSession: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let summary: SessionSummary
    /// One entry per item **view**, in view order and parallel to `summary.records` — not keyed by
    /// item id. Keying by id lost every view but the last of any item the run returned to, which
    /// broke the re-folding invariant above without changing a single published metric.
    let views: [[PlaybackEvent]]

    init(id: UUID = UUID(), summary: SessionSummary, views: [[PlaybackEvent]]) {
        self.id = id
        self.summary = summary
        self.views = views
    }
}

/// Completed sessions on disk.
///
/// **One file per session**, not one file holding an array. A session is immutable once sealed, so
/// appending a file is the natural shape — but the deciding reason is failure mode: a truncated or
/// unreadable file costs one session rather than the whole study, and re-running an arm on a device
/// is far more expensive than the directory scan this costs. `load()` skips what it cannot decode
/// and says how many it skipped, rather than failing the whole read.
///
/// JSON via `Codable`, no database: the write rate is a handful of files per measurement afternoon,
/// and a readable on-disk format is worth more here than query ability.
actor SessionStore {
    /// Surfaced so a caller can report a failed save rather than discovering later that a device
    /// session was never written.
    enum StoreError: Error, Equatable {
        case directoryUnavailable
    }

    private let directory: URL
    private let fileManager: FileManager

    private static let fileExtension = "session.json"

    /// - Parameter directory: where sessions live. Tests pass a temporary directory; production
    ///   passes nil and gets Application Support.
    init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw StoreError.directoryUnavailable
            }
            self.directory = support.appendingPathComponent("FeedLab/Sessions", isDirectory: true)
        }
    }

    // MARK: - Writing

    /// Writes one session. Atomic, so an interrupted write cannot leave a half-file that `load()`
    /// would then have to skip.
    func save(_ session: StoredSession) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        // Sorted keys so two runs of the same data produce identical bytes — which is what lets a
        // stored session be diffed when a metric definition changes.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(session)
        try data.write(to: url(for: session.id), options: .atomic)
    }

    // MARK: - Reading

    /// Every readable session, newest first.
    ///
    /// Never throws for a bad file. One unreadable session must not hide the others — the dashboard
    /// exists to compare arms, and refusing to show any of them because one is corrupt would turn a
    /// small loss into a total one.
    func load() -> [StoredSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var sessions: [StoredSession] = []
        var skipped = 0
        for file in contents where file.lastPathComponent.hasSuffix(Self.fileExtension) {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(StoredSession.self, from: data) else {
                skipped += 1
                continue
            }
            sessions.append(session)
        }

        if skipped > 0 {
            Log.metrics.error("Skipped \(skipped, privacy: .public) unreadable session file(s)")
        }
        return sessions.sorted { $0.summary.startedAt > $1.summary.startedAt }
    }

    // MARK: - Removing

    func delete(id: UUID) throws {
        try fileManager.removeItem(at: url(for: id))
    }

    /// Clears the store. Exists for the debug menu: a measurement afternoon starts from empty, and
    /// mixing yesterday's sessions into today's comparison is the kind of error that is invisible
    /// in a chart.
    func deleteAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func count() -> Int {
        load().count
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }
}

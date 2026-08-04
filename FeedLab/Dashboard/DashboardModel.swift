#if FEEDLAB_TOOLS
import Foundation
import Observation

/// Loads stored sessions and holds the comparison the dashboard renders.
///
/// Thin on purpose: the interesting logic is `ArmComparison`, which is pure and unit-tested. This
/// type only does the things a view model has to do — reach the disk, and hold what came back.
@MainActor
@Observable
final class DashboardModel {
    private(set) var sessions: [StoredSession] = []
    private(set) var results: [ArmResult] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false

    private let store: SessionStore?

    init(store: SessionStore?) {
        self.store = store
        loadFailed = store == nil
    }

    var isEmpty: Bool { sessions.isEmpty }

    /// Total runs across all arms — the n the honesty rules require alongside every number.
    var runCount: Int { sessions.count }

    func load() async {
        guard let store else {
            loadFailed = true
            return
        }
        isLoading = true
        let loaded = await store.load()
        sessions = loaded
        results = ArmComparison.results(from: loaded)
        isLoading = false
    }

    func deleteAll() async {
        try? await store?.deleteAll()
        await load()
    }

    // MARK: - Export

    func csv() -> String {
        SessionExporter.csv(from: sessions)
    }

    func json() -> Data? {
        try? SessionExporter.json(from: sessions)
    }

    /// Writes an export to a temporary file for the share sheet, which needs a URL rather than a
    /// blob to offer "Save to Files" and AirDrop.
    func exportFile(named name: String, contents: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try contents.write(to: url, options: .atomic)
            return url
        } catch {
            Log.metrics.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
#endif

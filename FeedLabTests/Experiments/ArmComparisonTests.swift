import Foundation
import Testing

@testable import FeedLab

@Suite("Arm comparison and export")
struct ArmComparisonTests {
    private func record(
        _ itemID: String,
        arm: String,
        ttff: TimeInterval?,
        watch: TimeInterval = 10,
        stall: TimeInterval = 0,
        switches: Int? = nil
    ) -> PlaybackRecord {
        var record = PlaybackRecord(itemID: itemID, arm: arm)
        record.timeToFirstFrame = ttff
        record.watchDuration = watch
        record.totalStallDuration = stall
        record.bitrateSwitchCount = switches
        return record
    }

    private func session(
        arm: String,
        ttffs: [TimeInterval],
        peak: UInt64 = 30_000_000,
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> StoredSession {
        let records = ttffs.enumerated().map { record("item-\($0.offset)", arm: arm, ttff: $0.element) }
        return StoredSession(
            summary: SessionSummary(arm: arm, records: records, peakMemoryBytes: peak, startedAt: startedAt),
            events: [:]
        )
    }

    // MARK: - Aggregation across runs

    @Test("An arm's headline figure is the median of its runs, not the pooled percentile")
    func medianOfRunsNotPooled() throws {
        // The distinction the run protocol requires. Pooling every item together would let one long
        // run dominate and would erase run-to-run variance — which is what decides whether two arms
        // are actually distinguishable.
        let runs = [
            session(arm: "preload1", ttffs: [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]),
            session(arm: "preload1", ttffs: [0.2]),
            session(arm: "preload1", ttffs: [0.9])
        ]

        let result = try #require(ArmComparison.results(from: runs).first)

        // Per-run p90s are 0.1, 0.2, 0.9 → nearest-rank median is 0.2.
        #expect(result.medianP90TimeToFirstFrame == 0.2)
        #expect(result.runCount == 3)
        #expect(result.itemCount == 12)
    }

    @Test("The spread across runs is reported, so indistinguishable arms can be called that")
    func spreadIsReported() throws {
        let runs = [
            session(arm: "baseline", ttffs: [0.4]),
            session(arm: "baseline", ttffs: [0.6]),
            session(arm: "baseline", ttffs: [0.5])
        ]

        let result = try #require(ArmComparison.results(from: runs).first)

        #expect(result.p90Range == 0.4...0.6)
    }

    @Test("Every item's TTFF is kept for the distribution, not just the summary figure")
    func distributionSamplesAreRetained() throws {
        let runs = [session(arm: "window", ttffs: [0.1, 0.2]), session(arm: "window", ttffs: [0.3])]

        let result = try #require(ArmComparison.results(from: runs).first)

        #expect(result.timeToFirstFrameSamples.sorted() == [0.1, 0.2, 0.3])
    }

    @Test("Arms appear in registry order, so charts stay comparable between screenshots")
    func registryOrdering() {
        let sessions = [
            session(arm: "window", ttffs: [0.1]),
            session(arm: "baseline", ttffs: [0.1]),
            session(arm: "preload1", ttffs: [0.1])
        ]

        let names = ArmComparison.results(from: sessions).map(\.arm)

        #expect(names == ["baseline", "preload1", "window"])
    }

    @Test("An arm that was never run is absent, not a zero bar")
    func unrunArmsAreOmitted() {
        // A zero-height bar claims the arm ran and scored nothing. Absence claims nothing.
        let results = ArmComparison.results(from: [session(arm: "baseline", ttffs: [0.1])])

        #expect(results.map(\.arm) == ["baseline"])
    }

    @Test("Runs of an arm no longer in the registry are still shown")
    func retiredArmsSurvive() {
        let results = ArmComparison.results(from: [session(arm: "retired-experiment", ttffs: [0.1])])

        #expect(
            results.map(\.arm) == ["retired-experiment"],
            "stored data must not vanish because the registry moved on"
        )
    }

    @Test("An arm whose items never rendered reports nil startup, not zero")
    func neverRenderedReportsNil() throws {
        let never = StoredSession(
            summary: SessionSummary(arm: "baseline", records: [record("a", arm: "baseline", ttff: nil)]),
            events: [:]
        )

        let result = try #require(ArmComparison.results(from: [never]).first)

        #expect(result.medianP90TimeToFirstFrame == nil)
        #expect(result.timeToFirstFrameSamples.isEmpty)
    }

    // MARK: - CSV export

    @Test("CSV writes an empty field for a metric that does not apply, never zero")
    func csvOptionalsAreEmptyNotZero() throws {
        // The rule from `qoe-metrics.md`, surviving serialisation. A progressive MP4 exported with
        // bitrate_switch_count=0 would read as a flawless ABR result and then be averaged into the
        // README table.
        let sessions = [
            StoredSession(
                summary: SessionSummary(
                    arm: "baseline",
                    records: [record("progressive", arm: "baseline", ttff: nil, switches: nil)]
                ),
                events: [:]
            )
        ]

        let csv = SessionExporter.csv(from: sessions)
        let row = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        let columns = SessionExporter.csvColumns

        #expect(row[try #require(columns.firstIndex(of: "bitrate_switch_count"))] == "")
        #expect(row[try #require(columns.firstIndex(of: "time_to_first_frame_ms"))] == "")
        #expect(row[try #require(columns.firstIndex(of: "dropped_frames"))] == "")
    }

    @Test("CSV has one row per item view plus a header")
    func csvRowCount() {
        let sessions = [
            session(arm: "baseline", ttffs: [0.1, 0.2]),
            session(arm: "preload1", ttffs: [0.3])
        ]

        let lines = SessionExporter.csv(from: sessions).split(separator: "\n")

        #expect(lines.count == 4)
        #expect(lines[0] == SessionExporter.csvColumns.joined(separator: ","))
    }

    @Test("A field containing a comma is quoted rather than shifting every column after it")
    func csvEscaping() {
        let sessions = [
            StoredSession(
                summary: SessionSummary(
                    arm: "baseline",
                    records: [record("item,with,commas", arm: "baseline", ttff: 0.1)]
                ),
                events: [:]
            )
        ]

        let csv = SessionExporter.csv(from: sessions)

        #expect(csv.contains("\"item,with,commas\""))
        // Two extra commas live inside the quoted field; the separators themselves are unchanged.
        let commas = csv.split(separator: "\n")[1].filter { $0 == "," }.count
        #expect(commas == SessionExporter.csvColumns.count - 1 + 2)
    }

    @Test("JSON export round-trips, so an export is a usable archive rather than a report")
    func jsonRoundTrips() throws {
        let sessions = [session(arm: "baseline", ttffs: [0.1, 0.2])]

        let data = try SessionExporter.json(from: sessions)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([StoredSession].self, from: data)

        #expect(decoded == sessions)
    }
}

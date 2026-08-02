import Foundation
import Testing

@testable import FeedLab

@Suite("Session aggregation")
struct AggregationTests {
    private func record(
        _ id: String,
        ttff: TimeInterval? = nil,
        watch: TimeInterval = 10,
        stall: TimeInterval = 0,
        stalls: Int = 0,
        switches: Int? = nil,
        dropped: Int? = nil
    ) -> PlaybackRecord {
        var record = PlaybackRecord(itemID: id, arm: "baseline")
        record.timeToFirstFrame = ttff
        record.watchDuration = watch
        record.totalStallDuration = stall
        record.stallCount = stalls
        record.bitrateSwitchCount = switches
        record.droppedFrames = dropped
        return record
    }

    // MARK: - The distinction that must not regress

    @Test("Aggregate rebuffer ratio is total-over-total, NOT the mean of per-item ratios")
    func aggregateRatioIsNotMeanOfRatios() {
        // Crafted so the two answers disagree loudly: one briefly-watched item stalled almost
        // throughout, one long item was almost perfect.
        let summary = SessionSummary(arm: "baseline", records: [
            record("brief", watch: 1, stall: 0.9),
            record("long", watch: 99, stall: 0.9)
        ])

        // total-over-total: 1.8 / 100
        #expect(abs(summary.aggregateRebufferRatio - 0.018) < 1e-9)
        // mean of ratios: (0.9 + 0.00909…) / 2
        #expect(abs(summary.meanOfPerItemRebufferRatios - 0.454_545_454_5) < 1e-6)

        #expect(
            summary.aggregateRebufferRatio != summary.meanOfPerItemRebufferRatios,
            "if these ever coincide the test case has lost its point"
        )
        #expect(
            summary.aggregateRebufferRatio < summary.meanOfPerItemRebufferRatios,
            "mean-of-ratios lets one briefly-watched item dominate a mostly-smooth session"
        )
    }

    // MARK: - Skipped items

    @Test("Zero-watch items are excluded from ratios but counted as skipped")
    func skippedItemsExcluded() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("watched", watch: 10, stall: 1),
            record("flew-past-1", watch: 0),
            record("flew-past-2", watch: 0)
        ])

        #expect(summary.skippedCount == 2)
        #expect(summary.watchedRecords.count == 1)
        // A strategy must not look smooth because the user never lingered.
        #expect(abs(summary.aggregateRebufferRatio - 0.1) < 1e-9)
    }

    @Test("A session with nothing watched reports zero rather than dividing by zero")
    func allSkipped() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("a", watch: 0),
            record("b", watch: 0)
        ])

        #expect(summary.aggregateRebufferRatio == 0)
        #expect(summary.skippedCount == 2)
    }

    // MARK: - Startup

    @Test("Mean and p90 TTFF differ on a long-tailed distribution, which is why p90 is the headline")
    func meanVersusP90() {
        let values: [TimeInterval] = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.25, 3.0]
        let summary = SessionSummary(
            arm: "baseline",
            records: values.enumerated().map { record("i\($0.offset)", ttff: $0.element) }
        )

        let mean = try? #require(summary.meanTimeToFirstFrame)
        #expect(abs((mean ?? 0) - 0.485) < 1e-9)
        // Nearest-rank p90 of 10 samples is the 9th value ascending.
        #expect(summary.p90TimeToFirstFrame == 0.25)
        // The single 3s outlier drags the mean above every sample but one — exactly the tail a
        // mean hides and a p90 is meant to expose.
    }

    @Test("Items that never rendered are absent from TTFF aggregates rather than counted as zero")
    func nilTTFFExcluded() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("rendered", ttff: 1.0),
            record("never", ttff: nil)
        ])

        #expect(summary.meanTimeToFirstFrame == 1.0)
        #expect(summary.p90TimeToFirstFrame == 1.0)
    }

    @Test("A session with no rendered items reports nil, not zero")
    func noTTFFAtAll() {
        let summary = SessionSummary(arm: "baseline", records: [record("a", ttff: nil)])

        #expect(summary.meanTimeToFirstFrame == nil)
        #expect(summary.p90TimeToFirstFrame == nil)
    }

    // MARK: - Percentile method

    @Test(
        "Nearest-rank percentile always returns an observed value",
        arguments: [
            ([1.0], 0.9, 1.0),
            ([1.0, 2.0], 0.5, 1.0),
            ([1.0, 2.0], 0.9, 2.0),
            ([1.0, 2.0, 3.0, 4.0, 5.0], 0.9, 5.0),
            ([1.0, 2.0, 3.0, 4.0, 5.0], 0.5, 3.0),
            ([5.0, 1.0, 3.0, 2.0, 4.0], 0.8, 4.0)
        ]
    )
    func nearestRank(values: [TimeInterval], percentile: Double, expected: TimeInterval) {
        #expect(Percentile.nearestRank(values, percentile: percentile) == expected)
    }

    @Test("Percentile of an empty set is nil")
    func percentileOfEmpty() {
        #expect(Percentile.nearestRank([], percentile: 0.9) == nil)
    }

    // MARK: - Delivery aggregates

    @Test("Switch count aggregates only over items that had a ladder")
    func switchCountIgnoresProgressive() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("hls-a", switches: 2),
            record("hls-b", switches: 4),
            record("progressive", switches: nil)
        ])

        // Mean over the two HLS items, not diluted to 2.0 by treating the progressive item as 0.
        #expect(summary.meanBitrateSwitchCount == 3.0)
    }

    @Test("A session of only progressive items reports nil switches, not zero")
    func allProgressiveReportsNil() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("p1", switches: nil),
            record("p2", switches: nil)
        ])

        #expect(summary.meanBitrateSwitchCount == nil)
        #expect(summary.totalDroppedFrames == nil)
    }

    @Test("Stall counts sum across every item, including skipped ones")
    func totalStalls() {
        let summary = SessionSummary(arm: "baseline", records: [
            record("a", watch: 10, stall: 1, stalls: 2),
            record("b", watch: 0, stall: 0.5, stalls: 1)
        ])

        // A skipped item that stalled still stalled; it is excluded from *ratios*, not from counts.
        #expect(summary.totalStallCount == 3)
    }
}

import Foundation

/// One arm's run, aggregated.
///
/// Aggregation rules are specified in `docs/qoe-metrics.md` and are deliberately not the obvious
/// ones — see `aggregateRebufferRatio` in particular.
struct SessionSummary: Equatable, Sendable {
    let arm: String
    let records: [PlaybackRecord]
    let peakMemoryBytes: UInt64
    let startedAt: Date
    let endedAt: Date

    init(
        arm: String,
        records: [PlaybackRecord],
        peakMemoryBytes: UInt64 = 0,
        startedAt: Date = .distantPast,
        endedAt: Date = .distantPast
    ) {
        self.arm = arm
        self.records = records
        self.peakMemoryBytes = peakMemoryBytes
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    // MARK: - Population

    /// Items the user actually dwelled on. The basis for every ratio below.
    var watchedRecords: [PlaybackRecord] {
        records.filter { !$0.isSkipped }
    }

    /// Items scrolled past instantly. Reported alongside the ratios, never folded into them.
    var skippedCount: Int {
        records.count - watchedRecords.count
    }

    // MARK: - Startup

    var meanTimeToFirstFrame: TimeInterval? {
        let values = records.compactMap(\.timeToFirstFrame)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The headline startup figure. p90 rather than mean because startup latency is long-tailed —
    /// a mean hides exactly the tail users notice.
    var p90TimeToFirstFrame: TimeInterval? {
        Percentile.nearestRank(records.compactMap(\.timeToFirstFrame), percentile: 0.9)
    }

    // MARK: - Smoothness

    /// **Total stall time over total watch time — not the mean of per-item ratios.**
    ///
    /// The two differ whenever items have unequal watch durations, and the mean-of-ratios lets a
    /// single briefly-watched stally item dominate a session that was otherwise smooth. Total-over-
    /// total weights each item by how long it was actually watched, which is what "fraction of
    /// viewing spent stalled" means. A unit test asserts the two disagree on a crafted case, so the
    /// distinction cannot silently regress into the easy version.
    var aggregateRebufferRatio: Double {
        let watched = watchedRecords
        let totalWatch = watched.reduce(0) { $0 + $1.watchDuration }
        guard totalWatch > 0 else { return 0 }
        let totalStall = watched.reduce(0) { $0 + $1.totalStallDuration }
        return totalStall / totalWatch
    }

    /// Provided only so the comparison above can be made explicit in tests and in the README's
    /// methodology note. Not a headline figure.
    var meanOfPerItemRebufferRatios: Double {
        let watched = watchedRecords
        guard !watched.isEmpty else { return 0 }
        return watched.reduce(0) { $0 + $1.rebufferRatio } / Double(watched.count)
    }

    var totalStallCount: Int {
        records.reduce(0) { $0 + $1.stallCount }
    }

    // MARK: - Delivery

    /// `nil` when no item in the session had a bitrate ladder — i.e. the question does not apply,
    /// as distinct from "no switches occurred".
    var meanBitrateSwitchCount: Double? {
        let values = records.compactMap(\.bitrateSwitchCount)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    var totalDroppedFrames: Int? {
        let values = records.compactMap(\.droppedFrames)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    var meanPlayerWaitDuration: TimeInterval {
        guard !records.isEmpty else { return 0 }
        return records.reduce(0) { $0 + $1.playerWaitDuration } / Double(records.count)
    }
}

/// Percentiles, stated explicitly because methods disagree.
enum Percentile {
    /// **Nearest-rank**: sort ascending, take the value at index `ceil(p * n) - 1`.
    ///
    /// Chosen over linear interpolation because it always returns an actually-observed value. With
    /// the small n of a single measurement run, an interpolated p90 can land between two real
    /// samples and describe a startup time that never happened. The method is named here because
    /// "p90" alone is ambiguous and the README quotes these numbers.
    static func nearestRank(_ values: [TimeInterval], percentile: Double) -> TimeInterval? {
        guard !values.isEmpty, percentile > 0, percentile <= 1 else { return nil }
        let sorted = values.sorted()
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

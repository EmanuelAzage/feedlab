import Foundation

/// One arm's results across every stored run of it.
///
/// The unit the dashboard charts and the README table are built from.
struct ArmResult: Identifiable, Equatable, Sendable {
    let arm: String
    /// Runs, not items. `experiment-harness.md` requires reporting n alongside every number, and a
    /// chart that shows a bar without its n invites exactly the overclaim the honesty rules forbid.
    let runCount: Int
    let itemCount: Int

    /// **Median across runs of each run's p90** — not the p90 of all items pooled together.
    ///
    /// The two differ, and the distinction is the protocol's. Pooling would let one long run
    /// dominate the figure and would hide run-to-run variance, which is the thing that decides
    /// whether two arms are actually distinguishable. Median of runs is what
    /// `experiment-harness.md` step 6 specifies.
    let medianP90TimeToFirstFrame: TimeInterval?
    let medianRebufferRatio: Double?
    let medianPeakMemoryBytes: UInt64?

    /// Every item's TTFF across every run, for the distribution chart — where the long tail a
    /// median hides is the whole point of looking.
    let timeToFirstFrameSamples: [TimeInterval]

    /// Spread across runs, so "these two arms are indistinguishable" can be said with a number
    /// behind it rather than as an impression.
    let p90Range: ClosedRange<TimeInterval>?

    var id: String { arm }
}

/// Turns stored sessions into per-arm results.
///
/// Pure, so the comparison methodology is unit-testable without a device, a chart, or a run — the
/// same reason `MetricsEngine` is pure. This is the layer where an honest comparison is either made
/// or quietly botched.
enum ArmComparison {
    /// Results per arm, in `ArmRegistry` order so charts stay comparable between screenshots.
    ///
    /// Arms with no stored runs are omitted rather than shown empty: an arm that was never run and
    /// an arm that failed are different claims, and a zero-height bar states the second.
    static func results(from sessions: [StoredSession]) -> [ArmResult] {
        let byArm = Dictionary(grouping: sessions) { $0.summary.arm }

        let ordered = ArmRegistry.all.map(\.name)
        let known = ordered.filter { byArm[$0] != nil }
        // Arms no longer in the registry still have stored runs worth showing; append them after
        // the declared set rather than dropping data because the registry moved on.
        let unknown = byArm.keys.filter { !ordered.contains($0) }.sorted()

        return (known + unknown).compactMap { arm in
            guard let runs = byArm[arm], !runs.isEmpty else { return nil }
            return result(arm: arm, runs: runs)
        }
    }

    private static func result(arm: String, runs: [StoredSession]) -> ArmResult {
        let summaries = runs.map(\.summary)

        let perRunP90 = summaries.compactMap(\.p90TimeToFirstFrame)
        let perRunRatio = summaries.map(\.aggregateRebufferRatio)
        let perRunPeak = summaries.map(\.peakMemoryBytes).filter { $0 > 0 }

        return ArmResult(
            arm: arm,
            runCount: runs.count,
            itemCount: summaries.reduce(0) { $0 + $1.records.count },
            medianP90TimeToFirstFrame: median(perRunP90),
            medianRebufferRatio: median(perRunRatio),
            // `map(Double.init)` here resolved to `Double.init(bitPattern:)`, not the numeric
            // conversion — 16 MB became 7.9e-317. The dashboard's memory chart then drew bars of
            // zero height beside a correctly-labelled axis, which reads as "this arm used no
            // memory" rather than as a broken conversion. Spelled out so the compiler cannot pick
            // the reinterpreting initializer again.
            medianPeakMemoryBytes: median(perRunPeak.map { Double($0) }).map { UInt64($0) },
            timeToFirstFrameSamples: summaries.flatMap { $0.records.compactMap(\.timeToFirstFrame) },
            p90Range: perRunP90.isEmpty ? nil : (perRunP90.min() ?? 0)...(perRunP90.max() ?? 0)
        )
    }

    /// Nearest-rank at p50, so the median is an **observed run** rather than an average of two.
    ///
    /// Deliberately the same method `SessionSummary` uses for p90 (`decisions.md`): a dashboard that
    /// took the mean of the two middle runs would report a figure no run produced, which is the
    /// thing nearest-rank was chosen to avoid in the first place.
    static func median(_ values: [Double]) -> Double? {
        Percentile.nearestRank(values, percentile: 0.5)
    }
}

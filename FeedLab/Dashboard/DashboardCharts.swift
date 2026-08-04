#if FEEDLAB_TOOLS
import Charts
import SwiftUI

/// The chart set from `docs/observability.md`.
///
/// Every chart carries its **n** in the subtitle. That is not decoration: `experiment-harness.md`
/// requires reporting run count alongside every number, and these views are screenshot targets for
/// the README — a bar chart photographed without its n is exactly the overclaim the honesty rules
/// exist to prevent.
struct ArmChartSubtitle: View {
    let runCount: Int
    let detail: String

    var body: some View {
        Text("\(runCount) run\(runCount == 1 ? "" : "s") · \(detail)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// **The hero chart.** Startup against smoothness, one point per arm.
///
/// The two things users feel, on axes that trade against each other — a strategy that preloads
/// harder should move left (faster startup) and may move up (more stalling) as it spends bandwidth
/// on items nobody watched. An arm in the bottom-left beats one in the top-right on both counts;
/// anywhere else is a genuine tradeoff rather than a winner.
struct StartupVsSmoothnessChart: View {
    let results: [ArmResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Startup vs. smoothness").font(.headline)
            ArmChartSubtitle(runCount: results.reduce(0) { $0 + $1.runCount }, detail: "median of runs per arm")

            Chart(plottable) { point in
                PointMark(
                    x: .value("p90 startup (ms)", point.startupMilliseconds),
                    y: .value("Rebuffer ratio", point.rebufferRatio)
                )
                .symbolSize(160)
                .foregroundStyle(by: .value("Arm", point.arm))
                .annotation(position: .top, spacing: 4) {
                    Text(point.arm).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxisLabel("p90 time to first frame (ms) — lower is better")
            .chartYAxisLabel("Rebuffer ratio — lower is better")
            .frame(height: 240)

            Text("Bottom-left wins on both. Anywhere else is a tradeoff, not a winner.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private struct Point: Identifiable {
        let arm: String
        let startupMilliseconds: Double
        let rebufferRatio: Double
        var id: String { arm }
    }

    /// Arms missing either axis are dropped rather than plotted at zero — a point at the origin
    /// would read as the best possible result.
    private var plottable: [Point] {
        results.compactMap { result in
            guard let startup = result.medianP90TimeToFirstFrame,
                  let ratio = result.medianRebufferRatio else { return nil }
            return Point(arm: result.arm, startupMilliseconds: startup * 1000, rebufferRatio: ratio)
        }
    }
}

/// Median p90 startup per arm, with the observed run-to-run range drawn on top.
///
/// The range bar is the honest part: two arms whose ranges overlap are not distinguishable at this
/// n, and the chart should make that visible rather than leaving it to a caption nobody reads.
struct StartupByArmChart: View {
    let results: [ArmResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("p90 startup by arm").font(.headline)
            ArmChartSubtitle(
                runCount: results.reduce(0) { $0 + $1.runCount },
                detail: "bar = median, line = observed range"
            )

            Chart {
                ForEach(results) { result in
                    if let median = result.medianP90TimeToFirstFrame {
                        BarMark(
                            x: .value("Arm", result.arm),
                            y: .value("p90 startup (ms)", median * 1000)
                        )
                        .foregroundStyle(by: .value("Arm", result.arm))
                        .opacity(0.75)
                    }
                    if let range = result.p90Range, range.lowerBound != range.upperBound {
                        RuleMark(
                            x: .value("Arm", result.arm),
                            yStart: .value("Min", range.lowerBound * 1000),
                            yEnd: .value("Max", range.upperBound * 1000)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(.primary)
                    }
                }
            }
            .chartYAxisLabel("ms")
            .chartLegend(.hidden)
            .frame(height: 220)
        }
    }
}

/// Every item's startup, per arm. Shows the tail a median hides.
struct StartupDistributionChart: View {
    let results: [ArmResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Startup distribution").font(.headline)
            ArmChartSubtitle(
                runCount: results.reduce(0) { $0 + $1.runCount },
                detail: "\(results.reduce(0) { $0 + $1.timeToFirstFrameSamples.count }) item views"
            )

            Chart {
                ForEach(results) { result in
                    ForEach(Array(result.timeToFirstFrameSamples.enumerated()), id: \.offset) { _, sample in
                        PointMark(
                            x: .value("Arm", result.arm),
                            y: .value("Startup (ms)", sample * 1000)
                        )
                        .symbolSize(24)
                        .opacity(0.45)
                        .foregroundStyle(by: .value("Arm", result.arm))
                    }
                }
            }
            .chartYAxisLabel("ms")
            .chartLegend(.hidden)
            .frame(height: 220)
        }
    }
}

/// Aggregate rebuffer ratio per arm — total stall over total watch, not the mean of per-item ratios.
struct RebufferByArmChart: View {
    let results: [ArmResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rebuffer ratio by arm").font(.headline)
            ArmChartSubtitle(
                runCount: results.reduce(0) { $0 + $1.runCount },
                detail: "total stall ÷ total watch, median of runs"
            )

            Chart {
                ForEach(results) { result in
                    if let ratio = result.medianRebufferRatio {
                        BarMark(x: .value("Arm", result.arm), y: .value("Rebuffer ratio", ratio))
                            .foregroundStyle(by: .value("Arm", result.arm))
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 200)
        }
    }
}

/// Peak observed memory per arm — where `pool-unbounded` is expected to earn its keep.
struct PeakMemoryByArmChart: View {
    let results: [ArmResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Peak memory by arm").font(.headline)
            // The qualifier travels with the chart, because a screenshot travels without its caption.
            ArmChartSubtitle(
                runCount: results.reduce(0) { $0 + $1.runCount },
                detail: "peak observed at 5 Hz — a lower bound, not a true peak"
            )

            Chart {
                ForEach(results) { result in
                    if let peak = result.medianPeakMemoryBytes {
                        BarMark(
                            x: .value("Arm", result.arm),
                            y: .value("Peak memory (MB)", Double(peak) / 1_048_576)
                        )
                        .foregroundStyle(by: .value("Arm", result.arm))
                    }
                }
            }
            .chartYAxisLabel("MB")
            .chartLegend(.hidden)
            .frame(height: 200)
        }
    }
}

/// Observed against indicated bitrate over one session — ABR behaviour and switch density.
///
/// The pair only means something when observed falls *below* indicated: observed is download
/// throughput, so on a fast link it legitimately sits far above the media rate
/// (`ios-learning-notes.md`).
struct BitrateOverTimeChart: View {
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bitrate over time").font(.headline)
            Text("\(session.summary.arm) · observed is throughput, so above indicated is normal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Time (s)", sample.time),
                        y: .value("kbps", sample.kilobitsPerSecond),
                        series: .value("Series", sample.series)
                    )
                    .foregroundStyle(by: .value("Series", sample.series))
                }
            }
            .chartYScale(type: .symmetricLog)
            .chartYAxisLabel("kbps (log)")
            .frame(height: 220)
        }
    }

    private struct Sample: Identifiable {
        let id = UUID()
        let time: TimeInterval
        let kilobitsPerSecond: Double
        let series: String
    }

    /// Flattened from the raw access-log events — the reason sessions persist their events and not
    /// only their records.
    private var samples: [Sample] {
        let events = session.views.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        guard let origin = events.first?.timestamp else { return [] }

        return events.flatMap { event -> [Sample] in
            guard case .accessLogEntry(let entry) = event.kind else { return [] }
            let time = event.timestamp - origin
            var out: [Sample] = []
            if let indicated = entry.indicatedBitrate {
                out.append(Sample(time: time, kilobitsPerSecond: indicated / 1000, series: "indicated"))
            }
            if let observed = entry.observedBitrate {
                out.append(Sample(time: time, kilobitsPerSecond: observed / 1000, series: "observed"))
            }
            return out
        }
    }
}
#endif

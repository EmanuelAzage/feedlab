#if FEEDLAB_TOOLS
import SwiftUI

/// The live measurement overlay.
///
/// Design rules from `docs/observability.md`: monospaced digits so figures do not jitter as they
/// tick, semi-transparent, never over the centre of the video, and the **arm name always visible**
/// so any screenshot is self-documenting — a HUD photo that does not say which arm produced it is
/// evidence of nothing.
struct HUDView: View {
    let snapshot: HUDSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().overlay(Color.white.opacity(0.25))
            currentItemBlock
            Divider().overlay(Color.white.opacity(0.25))
            sessionBlock
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 260, alignment: .leading)
        // Non-interactive: the HUD must never intercept the gestures it is measuring the effects of.
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("ARM")
                .foregroundStyle(.white.opacity(0.5))
            Text(snapshot.arm.uppercased())
                .fontWeight(.bold)
        }
        .font(.system(size: 11, weight: .bold, design: .monospaced))
    }

    private var currentItemBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.itemTitle)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.65))

            row("ttff", Format.milliseconds(snapshot.current?.timeToFirstFrame))
            row("stalls", stallsText)
            row("ratio", Format.ratio(snapshot.current?.rebufferRatio))
            row("bitrate", bitrateText)
            row("switches", Format.optionalInt(snapshot.current?.bitrateSwitchCount))
            row("dropped", Format.optionalInt(snapshot.current?.droppedFrames))
            row("pool wait", Format.milliseconds(snapshot.current?.playerWaitDuration))
        }
    }

    private var sessionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("items", "\(snapshot.itemsViewed)  (skipped \(snapshot.skippedCount))")
            row("ttff mean", Format.milliseconds(snapshot.meanTimeToFirstFrame))
            row("ttff p90", Format.milliseconds(snapshot.p90TimeToFirstFrame))
            row("rebuffer", Format.ratio(snapshot.aggregateRebufferRatio))
            row("pool", "\(snapshot.poolOccupancy)/\(snapshot.poolCapacity)\(pendingSuffix)")
            row("peak mem", Format.megabytes(snapshot.peakMemoryBytes))
        }
    }

    private var pendingSuffix: String {
        snapshot.poolPending > 0 ? "  wait \(snapshot.poolPending)" : ""
    }

    private var stallsText: String {
        guard let record = snapshot.current else { return "—" }
        return "\(record.stallCount)  (\(Format.seconds(record.totalStallDuration)))"
    }

    /// Observed over indicated. Observed falling below indicated is the precondition for a
    /// downswitch, so seeing them side by side makes an imminent switch legible.
    private var bitrateText: String {
        let observed = Format.kilobits(snapshot.current?.observedBitrate)
        let indicated = Format.kilobits(snapshot.current?.indicatedBitrate)
        return "\(observed) / \(indicated)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 62, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
        }
    }
}

/// Formatting that keeps "not applicable" visually distinct from zero, matching the metrics layer's
/// convention. A HUD that renders nil as `0` would hide exactly the distinction the records
/// preserve.
private enum Format {
    static func milliseconds(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value * 1000)
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    static func ratio(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    static func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "n/a"
    }

    static func kilobits(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.0fk", value / 1000)
    }

    static func megabytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
#endif

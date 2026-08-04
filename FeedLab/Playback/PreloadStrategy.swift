import Foundation

/// Which items should be prepared, and how they should buffer.
///
/// Pure by design — index arithmetic and configuration only, no AVFoundation, no knowledge of the
/// pool. That purity is what makes the interesting decision in this project verifiable without a
/// device, and it is why capacity arbitration lives in `PreparationPlanner` instead of here: a
/// strategy states what would be *ideal*, not what is affordable.
protocol PreloadStrategy: Sendable {
    /// Stable identifier. Appears in every record and on every screenshot.
    var name: String { get }

    /// Indices to prepare, **in priority order**, current item first.
    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int]

    /// Buffer configuration for an item at `offset` from current (0 = current, +1 = next,
    /// −1 = previous).
    func bufferConfiguration(for offset: Int) -> BufferConfiguration
}

/// Shared tuning constants, gathered so the corpus-specific ones are visible rather than scattered
/// as magic numbers.
enum PreloadTuning {
    /// ~1 segment for the current corpus (BipBop and Tears of Steel are ~10 s per segment).
    ///
    /// **Not an arbitrary number.** `preferredForwardBufferDuration` cannot go below one segment —
    /// measured in M2, where a 5 s request produced ~10 s per item. Any value under the stream's
    /// segment duration is indistinguishable from that duration, so a "2–4 s cap" would be a no-op
    /// and the capped arm would silently be testing preload depth alone. See `playback-engine.md`.
    static let cappedForwardBuffer: TimeInterval = 10

    /// Ceiling applied to items that are prepared but not playing, ~gear3 of the BipBop ladder.
    ///
    /// The point is contention, not memory: a preloading item pulling 1080p competes for bandwidth
    /// with the item the user is actually watching, so deep preload can *worsen* the metric it is
    /// meant to improve. Capping non-current items is what makes depth affordable.
    static let nonCurrentPeakBitRate: Double = 900_000
}

// MARK: - Strategies

/// Control. Prepares nothing ahead.
///
/// Establishes worst-case startup and lowest memory — the baseline every other arm is measured
/// against. It is also exactly what the engine did before M5, which makes the comparison honest:
/// the baseline is not a degraded special case, it is the absence of a strategy.
struct NoPreload: PreloadStrategy {
    let name = "none"

    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int] {
        Index.clamped([currentIndex], totalCount: totalCount)
    }

    func bufferConfiguration(for offset: Int) -> BufferConfiguration {
        .systemDefault
    }
}

/// Current plus the next item. The common forward-scroll case.
struct PreloadNext1: PreloadStrategy {
    let name = "next-1"

    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int] {
        Index.clamped([currentIndex, currentIndex + 1], totalCount: totalCount)
    }

    func bufferConfiguration(for offset: Int) -> BufferConfiguration {
        .systemDefault
    }
}

/// Current plus the next three, with the non-current items capped.
///
/// The hypothesis: depth helps fast scrollers, and capping is what stops it costing memory and
/// bandwidth. M2 measured the memory half — four items at the system default grew footprint ~60×
/// more than the same four capped.
struct PreloadNext3Capped: PreloadStrategy {
    let name = "next-3-capped"

    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int] {
        Index.clamped(
            [currentIndex, currentIndex + 1, currentIndex + 2, currentIndex + 3],
            totalCount: totalCount
        )
    }

    func bufferConfiguration(for offset: Int) -> BufferConfiguration {
        guard offset != 0 else { return .systemDefault }
        return BufferConfiguration(
            preferredForwardBufferDuration: PreloadTuning.cappedForwardBuffer,
            automaticallyWaitsToMinimizeStalling: true,
            preferredPeakBitRate: PreloadTuning.nonCurrentPeakBitRate
        )
    }
}

/// Identical to `PreloadNext3Capped` except that nothing is capped.
///
/// **The negative control for the buffer cap**, and the only way to measure what capping is worth.
/// `PreloadNext3Capped` bundles two changes against `PreloadNext1` — more depth *and* capped buffers
/// — so any difference between them is unattributable. This arm holds depth and pool capacity fixed
/// and varies only the configuration, which is what isolates the lever.
///
/// It exists for the same reason `pool-unbounded` does: the M2 probe measured ~60× more footprint
/// growth uncapped, but on macOS and in a single run. A claim that capping is what makes deep
/// preload viable needs the uncapped case measured on device, not inferred.
///
/// Expected to lose on memory. If it does not, the strategy table is wrong and
/// `playback-engine.md` says so rather than the arm being quietly dropped.
struct PreloadNext3Uncapped: PreloadStrategy {
    let name = "next-3-uncapped"

    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int] {
        // Deliberately the same expression as `PreloadNext3Capped`. A test asserts the two prepare
        // identical sets, because the moment they diverge the comparison stops isolating anything.
        Index.clamped(
            [currentIndex, currentIndex + 1, currentIndex + 2, currentIndex + 3],
            totalCount: totalCount
        )
    }

    func bufferConfiguration(for offset: Int) -> BufferConfiguration {
        .systemDefault
    }
}

/// Previous one, current, next two.
///
/// Spends a slot backwards on the theory that scrolling back should be instant too. Whether that is
/// worth a slot is the question — back-scroll is rarer than forward, so this arm can only win if the
/// cost of the spent slot is small.
struct PreloadWindow: PreloadStrategy {
    let name = "window"

    func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int] {
        // Priority order, not positional order: current first, then nearest neighbours with forward
        // preferred over backward, because forward scroll dominates a feed.
        Index.clamped(
            [currentIndex, currentIndex + 1, currentIndex - 1, currentIndex + 2],
            totalCount: totalCount
        )
    }

    func bufferConfiguration(for offset: Int) -> BufferConfiguration {
        .systemDefault
    }
}

// MARK: - Index helpers

enum Index {
    /// Drops out-of-range indices and duplicates while preserving order.
    ///
    /// Feeds do not wrap: preparing item 0 when the user is at the end would fetch something they
    /// are not about to see. Clamping rather than wrapping also keeps the prepared set smaller near
    /// the boundaries, which is a real behavioural difference worth measuring rather than papering
    /// over.
    static func clamped(_ indices: [Int], totalCount: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        var seen = Set<Int>()
        return indices.filter { index in
            guard index >= 0, index < totalCount else { return false }
            return seen.insert(index).inserted
        }
    }
}

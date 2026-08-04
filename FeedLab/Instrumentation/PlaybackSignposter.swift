import Foundation
import OSLog

/// `os_signpost` intervals on the Points of Interest track.
///
/// A **second, independent view of the same moments** the metrics layer folds — and that redundancy
/// is the value. If a signposted first-frame interval and a computed `timeToFirstFrame` disagree,
/// one of them is wrong, and Instruments is the one this project did not write. It also puts pool
/// contention on the same timeline as memory and CPU, which no number in the HUD can do.
///
/// Intervals are begun and ended at the **same sites that stamp events** (`docs/qoe-metrics.md`),
/// not where events are consumed. Emitting from the pipe's consumer would have been tidier, but it
/// would fold delivery jitter into every interval and put the signpost track slightly out of step
/// with the records it exists to corroborate.
///
/// `@unchecked Sendable` with a lock: intervals begin on the main actor and end inside KVO callbacks
/// on arbitrary queues, which is exactly the pairing `OSSignposter` handles fine and Swift's
/// isolation checking cannot see.
final class PlaybackSignposter: @unchecked Sendable {
    /// The intervals worth a track in Instruments, per `docs/observability.md`.
    enum Interval: String {
        /// Playback intent → first rendered frame. The signposted twin of `timeToFirstFrame`.
        case firstFrame
        /// `AVURLAsset` load and `AVPlayerItem` construction — tier 1.
        case assetLoad
        /// Blocked on an exhausted pool. Non-empty spans here *are* contention, visible as a shape
        /// rather than as a number.
        case playerAcquire
        /// Item adopted by a player and bound to a layer — tier 2 plus attach.
        case attach

        var signpostName: StaticString {
            switch self {
            case .firstFrame: "First frame"
            case .assetLoad: "Asset load"
            case .playerAcquire: "Player acquire"
            case .attach: "Attach"
            }
        }
    }

    private let signposter: OSSignposter

    private let lock = NSLock()
    private var isEnabled: Bool
    /// Open intervals, keyed by interval kind and item. Keyed rather than returned as a token
    /// because an interval routinely begins in one type and ends in another — first frame begins in
    /// the coordinator and ends in the observer.
    private var open: [String: OSSignpostIntervalState] = [:]

    init(enabled: Bool) {
        isEnabled = enabled
        signposter = OSSignposter(
            subsystem: "dev.emanuelazage.FeedLab",
            // The category Instruments' Points of Interest instrument reads.
            category: .pointsOfInterest
        )
    }

    /// A signposter that emits nothing, for runs where signpost overhead must be absent rather than
    /// merely small — and for `Release`, which has no measurement purpose.
    static let disabled = PlaybackSignposter(enabled: false)

    /// Toggled live from the debug menu. Any interval already open is closed on the way out, so
    /// disabling mid-run cannot leave a span running to the end of the trace.
    func setEnabled(_ enabled: Bool) {
        let abandoned: [(Interval, OSSignpostIntervalState)] = lock.withLock {
            isEnabled = enabled
            guard !enabled else { return [] }
            let all = open.compactMap { key, state -> (Interval, OSSignpostIntervalState)? in
                guard let raw = key.split(separator: "|").first,
                      let interval = Interval(rawValue: String(raw)) else { return nil }
                return (interval, state)
            }
            open.removeAll()
            return all
        }
        for (interval, state) in abandoned {
            signposter.endInterval(interval.signpostName, state)
        }
    }

    // MARK: - Intervals

    func begin(_ interval: Interval, itemID: String) {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(interval.signpostName, id: id, "\(itemID, privacy: .public)")
        let stored = lock.withLock { () -> Bool in
            guard isEnabled else { return false }
            open[key(interval, itemID)] = state
            return true
        }
        if !stored {
            // Begun to satisfy `OSSignposter`'s API, then immediately closed: cheaper than branching
            // before the call, and it cannot leak a span.
            signposter.endInterval(interval.signpostName, state)
        }
    }

    func end(_ interval: Interval, itemID: String) {
        // Removing under the lock makes this idempotent: `readyForDisplay` can fire more than once,
        // and ending an interval twice is a runtime complaint rather than a no-op.
        guard let state = lock.withLock({ open.removeValue(forKey: key(interval, itemID)) }) else { return }
        signposter.endInterval(interval.signpostName, state)
    }

    /// Drops any interval left open, so a torn-down item cannot leave a span running to the end of
    /// the trace and read as a multi-minute stall.
    func abandon(itemID: String) {
        let states = lock.withLock {
            Interval.allCases.compactMap { interval -> (Interval, OSSignpostIntervalState)? in
                guard let state = open.removeValue(forKey: key(interval, itemID)) else { return nil }
                return (interval, state)
            }
        }
        for (interval, state) in states {
            signposter.endInterval(interval.signpostName, state)
        }
    }

    private func key(_ interval: Interval, _ itemID: String) -> String {
        "\(interval.rawValue)|\(itemID)"
    }
}

extension PlaybackSignposter.Interval: CaseIterable {}

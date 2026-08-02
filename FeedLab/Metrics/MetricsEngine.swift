import Foundation

/// Folds a recorded event stream into a measured record.
///
/// Pure by construction: no clocks, no I/O, no AVFoundation. Every timestamp arrives on the events
/// themselves, so a stored session re-folds to identical numbers no matter when it is recomputed —
/// which is what makes a change to a metric *definition* re-derivable from existing runs instead of
/// requiring the runs to be repeated.
///
/// It is also, structurally, a reducer: `(State, Event) -> State`. That is where this project gets
/// the determinism and synthetic-edge-case testing a state-management framework would sell it
/// (`docs/decisions.md`).
enum MetricsEngine {
    /// Events for a **single item view**, in any order — they are sorted here, because delivery
    /// order across KVO and NotificationCenter is not guaranteed even when stamping is.
    static func record(from events: [PlaybackEvent], itemID: String, arm: String) -> PlaybackRecord {
        var record = PlaybackRecord(itemID: itemID, arm: arm)
        let events = events
            .filter { $0.itemID == itemID }
            .enumerated()
            .sorted { lhs, rhs in
                // Stable: equal timestamps keep their original order, so a stallEnded stamped
                // identically to the itemReleased that follows it is not reordered ahead of it.
                lhs.element.timestamp == rhs.element.timestamp
                    ? lhs.offset < rhs.offset
                    : lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element)

        guard let intent = events.first(where: { $0.kind == .itemBecameCurrent }) else {
            // No playback intent was ever expressed; there is nothing to measure.
            return record
        }
        let t0 = intent.timestamp

        record.timeToFirstFrame = timeToFirstFrame(in: events, t0: t0)
        applyStalls(from: events, t0: t0, to: &record)
        applyWatchDuration(from: events, t0: t0, to: &record)
        applyPlayerWait(from: events, to: &record)
        applyAccessLog(from: events, to: &record)
        record.errors = events.compactMap {
            if case .errorLogEntry(let error) = $0.kind { return error }
            return nil
        }
        return record
    }

    // MARK: - Startup

    private static func timeToFirstFrame(in events: [PlaybackEvent], t0: TimeInterval) -> TimeInterval? {
        let readies = events.filter { $0.kind == .readyForDisplay }
        guard !readies.isEmpty else {
            // Never rendered. nil, not zero — "never showed a frame" and "showed one instantly"
            // are opposite outcomes and must not aggregate together.
            return nil
        }
        if let after = readies.first(where: { $0.timestamp >= t0 }) {
            return after.timestamp - t0
        }
        // Already displayable before intent — a recycled layer that still held a rendered frame.
        // Zero, not negative: the user waited no time. Negative TTFF would poison every aggregate
        // it touched.
        return 0
    }

    // MARK: - Stalls

    /// A stall is an interruption **after playback has begun**.
    ///
    /// This is the difference between startup and rebuffering, and getting it wrong is expensive.
    /// `AVPlayer` enters `.waitingToPlayAtSpecifiedRate` with reason `.toMinimizeStalls` while it
    /// fills the buffer *before* the first frame plays, which satisfies the stall condition
    /// literally — so a naive reading counts every item's startup as a rebuffer. Startup is already
    /// measured, as time-to-first-frame; counting it again here would report it twice and inflate
    /// every rebuffer ratio by a roughly constant amount, which is worse than a random error
    /// because it survives averaging and looks like a real finding.
    ///
    /// Confirmed empirically before this guard existed: every item reported exactly one stall.
    private static func applyStalls(from events: [PlaybackEvent], t0: TimeInterval, to record: inout PlaybackRecord) {
        var openedAt: TimeInterval?
        var count = 0
        var total: TimeInterval = 0
        var hasStartedPlaying = false

        for event in events {
            switch event.kind {
            case .playbackStarted:
                hasStartedPlaying = true
            case .stallBegan:
                // Before first playback this is startup buffering, not a rebuffer.
                guard hasStartedPlaying else { break }
                // Ignore a second stallBegan while one is open; AVFoundation can report the
                // waiting state more than once for a single interruption.
                if openedAt == nil {
                    openedAt = max(event.timestamp, t0)
                    count += 1
                }
            case .stallEnded:
                if let start = openedAt {
                    total += max(0, event.timestamp - start)
                    openedAt = nil
                }
            case .itemReleased:
                // A stall still open at teardown really happened — the user scrolled away from a
                // spinning item. Dropping it would make the worst experiences invisible.
                if let start = openedAt {
                    total += max(0, event.timestamp - start)
                    openedAt = nil
                }
            default:
                break
            }
        }

        record.stallCount = count
        record.totalStallDuration = total
    }

    // MARK: - Watch duration

    /// Intent → teardown, minus user-initiated pauses, including stall time.
    private static func applyWatchDuration(
        from events: [PlaybackEvent],
        t0: TimeInterval,
        to record: inout PlaybackRecord
    ) {
        guard let end = events.last(where: { $0.kind == .itemReleased })?.timestamp else {
            // Still current. A record is only complete once released; leaving this at zero means an
            // in-flight item reads as skipped rather than as a fabricated duration.
            record.watchDuration = 0
            return
        }

        var paused: TimeInterval = 0
        var pausedAt: TimeInterval?
        for event in events where event.timestamp <= end {
            switch event.kind {
            case .userPaused:
                if pausedAt == nil { pausedAt = max(event.timestamp, t0) }
            case .userResumed:
                if let start = pausedAt {
                    paused += max(0, event.timestamp - start)
                    pausedAt = nil
                }
            default:
                break
            }
        }
        // Released while still paused: the paused span runs to teardown.
        if let start = pausedAt {
            paused += max(0, end - start)
        }

        record.watchDuration = max(0, (end - t0) - paused)
    }

    // MARK: - Pool contention

    private static func applyPlayerWait(from events: [PlaybackEvent], to record: inout PlaybackRecord) {
        guard
            let began = events.first(where: { $0.kind == .playerWaitBegan })?.timestamp,
            let ended = events.first(where: { $0.kind == .playerWaitEnded })?.timestamp
        else {
            // No wait bracket means a player was available. Not contention.
            record.playerWaitDuration = 0
            return
        }
        record.playerWaitDuration = max(0, ended - began)
    }

    // MARK: - Delivery

    private static func applyAccessLog(from events: [PlaybackEvent], to record: inout PlaybackRecord) {
        let snapshots: [AccessLogSnapshot] = events.compactMap {
            if case .accessLogEntry(let snapshot) = $0.kind { return snapshot }
            return nil
        }
        guard !snapshots.isEmpty else { return }

        record.observedBitrate = snapshots.compactMap(\.observedBitrate).last
        record.indicatedBitrate = snapshots.compactMap(\.indicatedBitrate).last
        record.mediaStackStartupTime = snapshots.compactMap(\.startupTime).first
        // Cumulative in the access log, so the last value is the total rather than a sum.
        record.droppedFrames = snapshots.compactMap(\.numberOfDroppedVideoFrames).last

        // Diff against the previous *indicated* bitrate rather than counting entries: entries are
        // appended for reasons unrelated to switching (server address change, playlist reload), so
        // counting them would report switches that never happened.
        let indicated = snapshots.compactMap(\.indicatedBitrate)
        guard !indicated.isEmpty else { return }
        var switches = 0
        for (previous, current) in zip(indicated, indicated.dropFirst()) where previous != current {
            switches += 1
        }
        record.bitrateSwitchCount = switches
    }
}

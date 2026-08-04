import Foundation
import Testing

@testable import FeedLab

@Suite("Metrics engine — folding events into a record")
struct MetricsEngineTests {
    private let item = "clip-1"
    private let arm = "baseline"

    private func fold(_ kinds: [(TimeInterval, PlaybackEvent.Kind)]) -> PlaybackRecord {
        let events = kinds.map { PlaybackEvent(itemID: item, timestamp: $0.0, kind: $0.1) }
        return MetricsEngine.record(from: events, itemID: item, arm: arm)
    }

    /// Intervals are differences of large absolute monotonic timestamps, so they carry float
    /// rounding: `100.4 - 100.0` is `0.4000000000000057`. The error is ~1e-14 s against metrics
    /// reported in milliseconds, so it is irrelevant to the measurement and only matters to the
    /// assertion. Compared with a tolerance rather than rounded inside the engine, which would
    /// discard precision the caller might legitimately want.
    private func isClose(_ actual: TimeInterval?, _ expected: TimeInterval, tolerance: TimeInterval = 1e-9) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < tolerance
    }

    // MARK: - Time to first frame

    @Test("Clean playback: TTFF is first frame minus intent")
    func cleanPlayback() {
        let record = fold([
            (100.0, .itemBecameCurrent),
            (100.4, .readyForDisplay),
            (100.4, .playbackStarted),
            (105.0, .itemReleased)
        ])

        #expect(isClose(record.timeToFirstFrame, 0.4))
        #expect(record.stallCount == 0)
        #expect(record.totalStallDuration == 0)
        #expect(isClose(record.watchDuration, 5.0))
        #expect(record.rebufferRatio == 0)
    }

    @Test("An item that never renders yields nil TTFF, not zero")
    func neverRenderedYieldsNil() {
        let record = fold([
            (10.0, .itemBecameCurrent),
            (12.0, .itemReleased)
        ])

        // The distinction that matters: nil drops out of aggregates; zero would report the
        // fastest possible startup for an item that showed nothing at all.
        #expect(record.timeToFirstFrame == nil)
        #expect(record.watchDuration == 2.0)
    }

    @Test("readyForDisplay before intent yields zero TTFF, never negative")
    func readyBeforeIntent() {
        // A recycled layer still holding a rendered frame when intent arrives.
        let record = fold([
            (9.0, .readyForDisplay),
            (10.0, .itemBecameCurrent),
            (12.0, .itemReleased)
        ])

        #expect(record.timeToFirstFrame == 0)
    }

    @Test("The first frame at or after intent is the one that counts")
    func firstReadyAfterIntentCounts() {
        let record = fold([
            (9.0, .readyForDisplay),
            (10.0, .itemBecameCurrent),
            (10.5, .readyForDisplay),
            (11.0, .readyForDisplay),
            (12.0, .itemReleased)
        ])

        #expect(record.timeToFirstFrame == 0.5)
    }

    // MARK: - Stalls

    @Test("Startup buffering is not a rebuffer")
    func startupBufferingIsNotAStall() {
        // What AVFoundation actually reports for a fresh item: it waits to minimize stalls while
        // filling the buffer, *then* plays. Counting that as a stall would report startup twice —
        // once as TTFF and again in rebuffer ratio — inflating every ratio by a near-constant.
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.1, .stallBegan),
            (1.3, .stallEnded),
            (1.3, .playbackStarted),
            (1.3, .readyForDisplay),
            (10.0, .itemReleased)
        ])

        #expect(record.stallCount == 0)
        #expect(record.totalStallDuration == 0)
        #expect(record.rebufferRatio == 0)
        // Startup is not lost — it is measured where it belongs.
        #expect(isClose(record.timeToFirstFrame, 1.3))
    }

    @Test("A stall after playback begins is counted")
    func stallAfterStartIsCounted() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.1, .stallBegan),
            (1.0, .stallEnded),
            (1.0, .playbackStarted),
            (4.0, .stallBegan),
            (6.0, .stallEnded),
            (10.0, .itemReleased)
        ])

        #expect(record.stallCount == 1, "only the post-start interruption counts")
        #expect(record.totalStallDuration == 2.0)
    }

    @Test("A single long stall")
    func singleLongStall() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.2, .readyForDisplay),
            (0.2, .playbackStarted),
            (2.0, .stallBegan),
            (6.0, .stallEnded),
            (10.0, .itemReleased)
        ])

        #expect(record.stallCount == 1)
        #expect(record.totalStallDuration == 4.0)
        #expect(record.watchDuration == 10.0)
        #expect(record.rebufferRatio == 0.4)
    }

    @Test("Many short stalls score the same ratio as one long one, which is why count is separate")
    func manyShortStalls() {
        var events: [(TimeInterval, PlaybackEvent.Kind)] = [
            (0.0, .itemBecameCurrent),
            (0.2, .readyForDisplay),
            (0.2, .playbackStarted)
        ]
        for index in 0..<8 {
            let start = 1.0 + Double(index)
            events.append((start, .stallBegan))
            events.append((start + 0.5, .stallEnded))
        }
        events.append((10.0, .itemReleased))

        let record = fold(events)

        #expect(record.stallCount == 8)
        #expect(record.totalStallDuration == 4.0)
        #expect(record.rebufferRatio == 0.4, "same ratio as one 4s stall — the counts must differ")
    }

    @Test("A stall still open at teardown is counted to the release point")
    func stallOpenAtTeardown() {
        // The user scrolled away from an item that was still spinning. Dropping this would make
        // the worst experiences invisible.
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.5, .playbackStarted),
            (1.0, .stallBegan),
            (4.0, .itemReleased)
        ])

        #expect(record.stallCount == 1)
        #expect(record.totalStallDuration == 3.0)
    }

    @Test("A repeated stallBegan while one is open does not double-count")
    func repeatedStallBegan() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.5, .playbackStarted),
            (1.0, .stallBegan),
            (1.5, .stallBegan),
            (3.0, .stallEnded),
            (5.0, .itemReleased)
        ])

        #expect(record.stallCount == 1)
        #expect(record.totalStallDuration == 2.0)
    }

    // MARK: - User pause

    @Test("A user pause is excluded from watch duration")
    func userPauseExcludedFromWatch() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.2, .readyForDisplay),
            (2.0, .userPaused),
            (7.0, .userResumed),
            (10.0, .itemReleased)
        ])

        // 10s elapsed, 5s of it deliberately paused.
        #expect(record.watchDuration == 5.0)
    }

    @Test("A user pause does not inflate rebuffer ratio")
    func userPauseDoesNotCountAsStall() {
        let paused = fold([
            (0.0, .itemBecameCurrent),
            (0.5, .playbackStarted),
            (1.0, .stallBegan),
            (2.0, .stallEnded),
            (3.0, .userPaused),
            (9.0, .userResumed),
            (10.0, .itemReleased)
        ])

        #expect(paused.stallCount == 1)
        #expect(paused.totalStallDuration == 1.0)
        #expect(paused.watchDuration == 4.0)
        // Had the pause been left in the denominator the ratio would read 0.1 — a stalled session
        // flattered into looking smooth by a user who simply walked away.
        #expect(paused.rebufferRatio == 0.25)
    }

    @Test("Released while still paused: the paused span runs to teardown")
    func releasedWhilePaused() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (3.0, .userPaused),
            (10.0, .itemReleased)
        ])

        #expect(record.watchDuration == 3.0)
    }

    // MARK: - Zero-watch items

    @Test("An item with no release is not yet complete and reads as skipped")
    func inFlightItemIsSkipped() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.3, .readyForDisplay)
        ])

        #expect(record.watchDuration == 0)
        #expect(record.isSkipped)
        // TTFF is still real even though the view never completed.
        #expect(record.timeToFirstFrame == 0.3)
    }

    @Test("No intent at all yields an empty record rather than a fabricated one")
    func noIntent() {
        let record = fold([
            (0.0, .readyForDisplay),
            (1.0, .itemReleased)
        ])

        #expect(record.timeToFirstFrame == nil)
        #expect(record.watchDuration == 0)
        #expect(record.isSkipped)
    }

    // MARK: - Pool contention

    @Test("Player wait is the bracketed blocked interval")
    func playerWaitMeasured() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.0, .playerWaitBegan),
            (0.75, .playerWaitEnded),
            (1.0, .readyForDisplay),
            (5.0, .itemReleased)
        ])

        #expect(record.playerWaitDuration == 0.75)
        #expect(record.timeToFirstFrame == 1.0, "TTFF includes the wait; the two are recorded separately")
    }

    @Test("No wait bracket means no contention, not missing data")
    func noWaitBracket() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.3, .readyForDisplay),
            (5.0, .itemReleased)
        ])

        #expect(record.playerWaitDuration == 0)
    }

    // MARK: - Access log

    @Test("Bitrate switches are diffed, not counted per entry")
    func bitrateSwitchesAreDiffed() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (1.0, .accessLogEntry(AccessLogSnapshot(indicatedBitrate: 1_000, observedBitrate: 900))),
            // Same indicated bitrate: an entry appended for an unrelated reason (playlist reload,
            // server address change) must not read as a switch.
            (2.0, .accessLogEntry(AccessLogSnapshot(indicatedBitrate: 1_000, observedBitrate: 850))),
            (3.0, .accessLogEntry(AccessLogSnapshot(indicatedBitrate: 500, observedBitrate: 400))),
            (4.0, .accessLogEntry(AccessLogSnapshot(indicatedBitrate: 1_000, observedBitrate: 1_100))),
            (5.0, .itemReleased)
        ])

        #expect(record.bitrateSwitchCount == 2)
        #expect(record.indicatedBitrate == 1_000)
        #expect(record.observedBitrate == 1_100)
    }

    @Test("A stream with no ladder reports nil switches, not zero")
    func progressiveStreamHasNoSwitchCount() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (1.0, .accessLogEntry(AccessLogSnapshot(numberOfDroppedVideoFrames: 3))),
            (5.0, .itemReleased)
        ])

        // nil is "not applicable"; zero would look like a perfect ABR result on a file that has
        // no ladder to switch within.
        #expect(record.bitrateSwitchCount == nil)
        #expect(record.droppedFrames == 3)
    }

    @Test("Dropped frames are cumulative, so the last value wins rather than a sum")
    func droppedFramesAreCumulative() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (1.0, .accessLogEntry(AccessLogSnapshot(numberOfDroppedVideoFrames: 2))),
            (2.0, .accessLogEntry(AccessLogSnapshot(numberOfDroppedVideoFrames: 5))),
            (5.0, .itemReleased)
        ])

        #expect(record.droppedFrames == 5)
    }

    @Test("The media stack's own startup time is recorded alongside ours")
    func mediaStackStartupRecorded() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (0.6, .readyForDisplay),
            (1.0, .accessLogEntry(AccessLogSnapshot(startupTime: 0.35))),
            (5.0, .itemReleased)
        ])

        #expect(record.timeToFirstFrame == 0.6)
        #expect(record.mediaStackStartupTime == 0.35)
        // The delta is the point: ours includes pool wait and attach, theirs does not.
    }

    // MARK: - Hygiene

    @Test("Events are sorted before folding, since delivery order is not guaranteed")
    func eventsAreSortedBeforeFolding() {
        let record = fold([
            (10.0, .itemReleased),
            (0.0, .itemBecameCurrent),
            (6.0, .stallEnded),
            (2.0, .stallBegan),
            (0.2, .playbackStarted),
            (0.2, .readyForDisplay)
        ])

        #expect(record.timeToFirstFrame == 0.2)
        #expect(record.totalStallDuration == 4.0)
        #expect(record.watchDuration == 10.0)
    }

    @Test("Events belonging to other items are ignored")
    func otherItemsIgnored() {
        let events = [
            PlaybackEvent(itemID: item, timestamp: 0.0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: "other", timestamp: 1.0, kind: .stallBegan),
            PlaybackEvent(itemID: "other", timestamp: 9.0, kind: .stallEnded),
            PlaybackEvent(itemID: item, timestamp: 5.0, kind: .itemReleased)
        ]

        let record = MetricsEngine.record(from: events, itemID: item, arm: arm)

        #expect(record.stallCount == 0)
        #expect(record.watchDuration == 5.0)
    }

    @Test("Errors are collected in order")
    func errorsCollected() {
        let record = fold([
            (0.0, .itemBecameCurrent),
            (1.0, .errorLogEntry(PlaybackErrorEvent(statusCode: -12_888, domain: "CoreMediaErrorDomain"))),
            (2.0, .errorLogEntry(PlaybackErrorEvent(statusCode: -1_009, domain: "NSURLErrorDomain"))),
            (5.0, .itemReleased)
        ])

        #expect(record.errors.count == 2)
        #expect(record.errors.first?.statusCode == -12_888)
    }

    @Test("The same events fold to the same record every time")
    func foldIsDeterministic() {
        let events: [(TimeInterval, PlaybackEvent.Kind)] = [
            (0.0, .itemBecameCurrent),
            (0.3, .readyForDisplay),
            (2.0, .stallBegan),
            (3.0, .stallEnded),
            (8.0, .itemReleased)
        ]

        // No clock is read inside the engine, so a stored session re-derives identically.
        #expect(fold(events) == fold(events))
    }

    // MARK: - The frozen-frame case (measured on device, M6)

    @Test("An item that renders but never plays is flagged, not scored as flawless")
    func renderedButNeverPlayed() {
        // Measured on device: 27% of progressive item views did exactly this — a first frame, then
        // a frozen picture until the user scrolled away. Before `isFrozen` existed each one scored
        // a good TTFF, zero stalls and a 0.000 rebuffer ratio, because a stall only counts after
        // playback begins and playback never began. The worst experience the rig can produce was
        // indistinguishable from the best.
        let events: [PlaybackEvent] = [
            PlaybackEvent(itemID: "frozen", timestamp: 0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: "frozen", timestamp: 6.05, kind: .readyForDisplay),
            PlaybackEvent(itemID: "frozen", timestamp: 6.06, kind: .stallBegan),
            PlaybackEvent(itemID: "frozen", timestamp: 8.74, kind: .itemReleased)
        ]

        let record = MetricsEngine.record(from: events, itemID: "frozen", arm: "test")

        #expect(record.didStartPlayback == false)
        #expect(record.isFrozen, "rendered, watched, and never played is the frozen case")
        #expect(record.timeToFirstFrame == 6.05, "it did render — TTFF is real and stays reported")
        #expect(record.stallCount == 0, "the pre-playback stall rule still holds; this is why it needed a flag")
        #expect(record.rebufferRatio == 0, "and this is the number that made it invisible")
    }

    @Test("Normal playback is not flagged as frozen")
    func healthyPlaybackIsNotFrozen() {
        let events: [PlaybackEvent] = [
            PlaybackEvent(itemID: "ok", timestamp: 0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: "ok", timestamp: 0.12, kind: .readyForDisplay),
            PlaybackEvent(itemID: "ok", timestamp: 0.13, kind: .playbackStarted),
            PlaybackEvent(itemID: "ok", timestamp: 5.0, kind: .itemReleased)
        ]

        let record = MetricsEngine.record(from: events, itemID: "ok", arm: "test")

        #expect(record.didStartPlayback)
        #expect(!record.isFrozen)
    }

    @Test("An item that never rendered at all is not frozen — it is a different failure")
    func neverRenderedIsNotFrozen() {
        // Frozen means "showed a frame and stopped". Never rendering is its own outcome and already
        // has one: a nil TTFF. Collapsing the two would hide which of them happened.
        let events: [PlaybackEvent] = [
            PlaybackEvent(itemID: "blank", timestamp: 0, kind: .itemBecameCurrent),
            PlaybackEvent(itemID: "blank", timestamp: 4.0, kind: .itemReleased)
        ]

        let record = MetricsEngine.record(from: events, itemID: "blank", arm: "test")

        #expect(record.timeToFirstFrame == nil)
        #expect(!record.isFrozen)
    }

}

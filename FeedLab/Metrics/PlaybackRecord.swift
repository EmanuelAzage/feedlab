import Foundation

/// One item view, measured.
///
/// Optionals mean "not applicable / never observed", never "zero". The distinction matters: a
/// progressive MP4 has no bitrate ladder, so reporting `bitrateSwitchCount == 0` for it would look
/// like an excellent result rather than an inapplicable question. Those cases fall out of the event
/// stream naturally — if no access-log entry ever carried an indicated bitrate, the count stays nil.
struct PlaybackRecord: Equatable, Sendable, Identifiable, Codable {
    let itemID: String
    let arm: String

    var id: String { "\(arm)/\(itemID)" }

    /// Our measurement: intent (`itemBecameCurrent`) → first rendered frame (`readyForDisplay`).
    /// `nil` when the item never rendered — which is a distinct outcome from rendering instantly,
    /// and must not collapse to zero.
    var timeToFirstFrame: TimeInterval?

    /// The media stack's own view of startup, from the access log. Recorded alongside ours because
    /// **the delta is the interesting part**: ours includes pool wait and attach, Apple's is
    /// network/decode oriented, so the difference isolates app-induced latency.
    var mediaStackStartupTime: TimeInterval?

    var stallCount: Int = 0
    var totalStallDuration: TimeInterval = 0

    /// Intended watch time: from playback intent to teardown, **minus** user-initiated pauses,
    /// **including** stall time. Stalls are part of what the user sat through; a deliberate pause
    /// is not.
    var watchDuration: TimeInterval = 0

    var observedBitrate: Double?
    var indicatedBitrate: Double?
    /// `nil` for streams with no ladder — see the note above.
    var bitrateSwitchCount: Int?
    var droppedFrames: Int?

    /// Time blocked on an exhausted pool. Zero when a player was obtained without blocking, even
    /// if one had to be instantiated — instantiation is not contention (`docs/qoe-metrics.md`).
    var playerWaitDuration: TimeInterval = 0

    var errors: [PlaybackErrorEvent] = []

    /// Fraction of intended watch time spent stalled.
    var rebufferRatio: Double {
        watchDuration > 0 ? totalStallDuration / watchDuration : 0
    }

    /// Whether `timeControlStatus` ever reached `.playing` for this item view.
    ///
    /// **Measured on device 2026-08-03, and it is not a corner case:** 27% of progressive item views
    /// rendered a first frame and then never played — a frozen picture until the user scrolled away
    /// — while 0 of 42 HLS views did. Those item views scored a perfectly good time-to-first-frame,
    /// zero stalls, and a rebuffer ratio of 0.000, because a stall only counts after playback begins
    /// and playback never began. The worst experience the rig can produce was indistinguishable from
    /// the best.
    var didStartPlayback: Bool = false

    /// Rendered a frame but never played. The frozen-frame case.
    ///
    /// Reported as its own population rather than folded into rebuffer ratio: the time was not
    /// *rebuffering* — the player never got far enough to rebuffer — so putting it in that numerator
    /// would misname it. It is a distinct failure and it needs a distinct number, or it stays
    /// invisible exactly as it was.
    var isFrozen: Bool {
        timeToFirstFrame != nil && !didStartPlayback && !isSkipped
    }

    /// Scrolled past without dwelling. Excluded from ratio aggregates but counted separately — a
    /// strategy that looks good because the user never lingered is not actually good.
    var isSkipped: Bool {
        watchDuration <= 0
    }
}

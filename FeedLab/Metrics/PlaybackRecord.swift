import Foundation

/// One item view, measured.
///
/// Optionals mean "not applicable / never observed", never "zero". The distinction matters: a
/// progressive MP4 has no bitrate ladder, so reporting `bitrateSwitchCount == 0` for it would look
/// like an excellent result rather than an inapplicable question. Those cases fall out of the event
/// stream naturally — if no access-log entry ever carried an indicated bitrate, the count stays nil.
struct PlaybackRecord: Equatable, Sendable, Identifiable {
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

    /// Scrolled past without dwelling. Excluded from ratio aggregates but counted separately — a
    /// strategy that looks good because the user never lingered is not actually good.
    var isSkipped: Bool {
        watchDuration <= 0
    }
}

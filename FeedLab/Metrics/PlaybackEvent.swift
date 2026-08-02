import Foundation

/// The instrumentation vocabulary: everything the metrics layer is allowed to know.
///
/// Lives in `Metrics/` rather than `Instrumentation/` deliberately. This type *is* the boundary —
/// if an `AVPlayerItem` ever appears on it the whole guarantee collapses — so it sits inside the
/// region the purity test guards. `Instrumentation/` produces these; `Metrics/` consumes them and
/// nothing else.
///
/// **Timestamps are stamped at the observation callback**, before any queue or actor hop, from a
/// monotonic source. See the measurement-discipline section of `docs/qoe-metrics.md`: taking the
/// clock reading where an event is *consumed* would fold delivery jitter into every interval.
struct PlaybackEvent: Equatable, Sendable {
    let itemID: String
    /// Monotonic seconds from an arbitrary origin. Never wall-clock.
    let timestamp: TimeInterval
    let kind: Kind

    enum Kind: Equatable, Sendable {
        /// Playback intent begins — `t0` for time-to-first-frame. Fires on scroll settle, not
        /// while scrolling (`docs/decisions.md`).
        case itemBecameCurrent

        /// Bracket around a blocked wait for a player from the bounded pool. Absent entirely when
        /// a player was available, since obtaining one without blocking is not waiting.
        case playerWaitBegan
        case playerWaitEnded

        /// `AVPlayerLayer.isReadyForDisplay` became true — `t1` for time-to-first-frame.
        case readyForDisplay

        /// `timeControlStatus` became `.playing`.
        case playbackStarted

        /// `timeControlStatus == .waitingToPlayAtSpecifiedRate` **and**
        /// `reasonForWaitingToPlay == .toMinimizeStalls`. Waiting for any other reason is not a
        /// stall and must not be counted as one.
        case stallBegan
        case stallEnded

        /// User-initiated pause via the tap gesture. Excluded from **both** the numerator and the
        /// denominator of rebuffer ratio — a user who pauses for a minute has not experienced a
        /// minute of rebuffering, and counting it either way corrupts the metric.
        case userPaused
        case userResumed

        /// A new `AVPlayerItemAccessLogEvent`, flattened. Entries are appended for reasons other
        /// than stalls (server address change, playlist reload), so consumers diff against the
        /// previous entry rather than assuming one entry per event.
        case accessLogEntry(AccessLogSnapshot)

        /// A non-fatal streaming error. Recorded because a stream that recovers silently still
        /// degraded the experience.
        case errorLogEntry(PlaybackErrorEvent)

        /// Played to the end. In a looping feed this is a lap marker, not a teardown.
        case itemEnded

        /// The item was torn down and its player returned to the pool. Closes watch accounting,
        /// and closes any stall still open at that moment.
        case itemReleased
    }
}

/// A flattened `AVPlayerItemAccessLogEvent`, carrying only the fields the metrics need.
///
/// Every field is optional because AVFoundation reports `-1` for "not available" and those gaps are
/// real — progressive assets leave most of the ABR fields unpopulated. Optional forces the
/// distinction between "zero switches" and "switching is not a meaningful concept here" to be made
/// explicitly rather than by accident.
struct AccessLogSnapshot: Equatable, Sendable {
    /// Bitrate of the variant currently selected from the ladder — a *declared* number.
    let indicatedBitrate: Double?
    /// Throughput actually achieved — a *measured* number. Falling below indicated is the
    /// precondition for a downswitch.
    let observedBitrate: Double?
    let switchBitrate: Double?
    /// Cumulative, not per-entry.
    let numberOfStalls: Int?
    /// Cumulative, not per-entry.
    let numberOfDroppedVideoFrames: Int?
    /// The media stack's own view of startup. Deliberately compared against our TTFF: ours
    /// includes pool wait and attach, Apple's is network/decode oriented, and the delta isolates
    /// app-induced latency from media-stack latency.
    let startupTime: TimeInterval?

    init(
        indicatedBitrate: Double? = nil,
        observedBitrate: Double? = nil,
        switchBitrate: Double? = nil,
        numberOfStalls: Int? = nil,
        numberOfDroppedVideoFrames: Int? = nil,
        startupTime: TimeInterval? = nil
    ) {
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.switchBitrate = switchBitrate
        self.numberOfStalls = numberOfStalls
        self.numberOfDroppedVideoFrames = numberOfDroppedVideoFrames
        self.startupTime = startupTime
    }
}

/// A non-fatal streaming error from the item's error log.
struct PlaybackErrorEvent: Equatable, Sendable {
    let statusCode: Int
    let domain: String
    let comment: String?

    init(statusCode: Int, domain: String, comment: String? = nil) {
        self.statusCode = statusCode
        self.domain = domain
        self.comment = comment
    }
}

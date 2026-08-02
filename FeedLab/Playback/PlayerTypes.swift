import Foundation

/// Mirrors `AVPlayer.TimeControlStatus`.
///
/// Restated rather than re-exported so that the engine protocols, the event vocabulary, and
/// the metric computation share one type that carries no AVFoundation dependency. `rate` is
/// intent; this is reality — see `docs/ios-learning-notes.md`.
enum PlayerTimeControlStatus: Equatable, Sendable {
    case paused
    case waitingToPlayAtSpecifiedRate
    case playing
}

/// Mirrors `AVPlayer.WaitingReason`.
///
/// `toMinimizeStalls` is the authoritative rebuffer signal: a player waiting for any other
/// reason is not stalling, and counting it as such would inflate rebuffer ratio.
enum PlayerWaitingReason: Equatable, Sendable {
    case toMinimizeStalls
    case evaluatingBufferingRate
    case noItemToPlay
    case other(String)
}

/// Mirrors `AVPlayerItem.Status`.
enum PlayerItemStatus: Equatable, Sendable {
    case unknown
    case readyToPlay
    case failed
}

/// The buffering levers a preload strategy pulls.
///
/// Measured motivation for capping the forward buffer (macOS, Apple BipBop, 2026-08-02):
/// four attached-but-unplayed items at the system default grew `phys_footprint` by ~91 MB;
/// the same four capped at 5 s grew it by ~1.5 MB. Buffering is resident memory, not
/// disk-backed cache. Directional only — macOS, single run — but it is why
/// `PreloadNext3Capped` exists. See `docs/playback-engine.md`.
struct BufferConfiguration: Equatable, Sendable {
    /// Seconds to buffer ahead. `0` means "system default", which is *not* a small number.
    ///
    /// **Cannot go below one segment.** A 5 s request against ~10 s segments yields ~10 s, so
    /// any value under the stream's segment duration is indistinguishable from that duration.
    /// Choose caps in segment multiples, not arbitrary seconds.
    var preferredForwardBufferDuration: TimeInterval
    /// `false` starts fast and risks stalling; `true` starts safe.
    var automaticallyWaitsToMinimizeStalling: Bool
    /// Bits per second ceiling on the ABR ladder. `0` means unlimited.
    var preferredPeakBitRate: Double

    static let systemDefault = BufferConfiguration(
        preferredForwardBufferDuration: 0,
        automaticallyWaitsToMinimizeStalling: true,
        preferredPeakBitRate: 0
    )
}

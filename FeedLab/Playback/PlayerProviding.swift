import Foundation

/// The slice of `AVPlayerItem` the engine actually uses.
///
/// Verified 2026-08-02: an item does **not** buffer and its status stays `.unknown` until it
/// is associated with a player. Everything on this protocol is therefore meaningless until
/// attachment — which is the whole reason preload costs a pool slot.
protocol PlayerItemProviding: AnyObject, Sendable {
    var status: PlayerItemStatus { get }
    var isPlaybackLikelyToKeepUp: Bool { get }
    /// Total seconds currently buffered, summed across loaded ranges.
    var bufferedDuration: TimeInterval { get }
    func apply(_ configuration: BufferConfiguration)
}

/// The slice of `AVPlayer` the engine actually uses.
///
/// **Ownership discipline** (the invariant that makes `Sendable` honest here): the pool owns
/// a player only while it sits in the free list. Between `acquire` and `release` the caller
/// owns it exclusively, and no other context touches it. Layer attachment therefore happens
/// on the main actor without racing the pool.
protocol PlayerProviding: AnyObject, Sendable {
    var timeControlStatus: PlayerTimeControlStatus { get }
    var reasonForWaitingToPlay: PlayerWaitingReason? { get }
    var currentItem: (any PlayerItemProviding)? { get }

    func replaceCurrentItem(with item: (any PlayerItemProviding)?)
    func play()
    func pause()
    /// Seeks to the beginning. Backs looping (`docs/decisions.md`: seek-to-zero rather than
    /// `AVPlayerLooper`, which would need `AVQueuePlayer` and complicate pooling) and the
    /// double-tap gesture in the product spec.
    func seekToStart()
    func apply(_ configuration: BufferConfiguration)

    /// Full teardown, called by the pool before a player re-enters the free list: pause, drop
    /// the current item, and restore the default buffer configuration.
    ///
    /// Observer removal is *not* done here — observers are registered by the instrumentation
    /// layer, which detaches them before releasing. A leaked KVO registration on a recycled
    /// player is the classic bug in this design and would silently misattribute later items'
    /// events.
    func reset()
}

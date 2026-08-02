import Foundation

/// Serialises events arriving from every queue AVFoundation uses into one ordered stream.
///
/// Without this, the obvious `Task { await recorder.record(event) }` per event spawns an unordered
/// task per callback: arrival order is not guaranteed, so an event stamped before `.itemReleased`
/// could reach the recorder after it, land in a fresh bucket, and never be folded into any record.
/// The timestamps would still be correct and the record would still be wrong.
///
/// `AsyncStream.Continuation.yield` is safe to call from any thread and preserves order, which is
/// exactly the guarantee needed — and note it is needed for *delivery*, not for timing. Timing was
/// already fixed when the callback stamped the event (`docs/qoe-metrics.md`).
///
/// Buffering is unbounded on purpose. Dropping events under load would silently corrupt records at
/// precisely the moments worth measuring, and the volume is a handful of events per item view.
struct PlaybackEventPipe: Sendable {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackEvent.self,
            bufferingPolicy: .unbounded
        )
        events = stream
        self.continuation = continuation
    }

    /// Safe from any thread, including the arbitrary queues KVO and `NotificationCenter` use.
    func send(_ event: PlaybackEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

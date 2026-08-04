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
    /// One thing travelling through the pipe.
    enum Element: Sendable {
        case event(PlaybackEvent)
        /// A flush marker — see `drain()`. Not part of the event vocabulary: it carries no
        /// timestamp and never reaches `MetricsEngine`, because it is about delivery rather than
        /// about playback.
        case barrier(@Sendable () -> Void)
    }

    let elements: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .unbounded
        )
        elements = stream
        self.continuation = continuation
    }

    /// Safe from any thread, including the arbitrary queues KVO and `NotificationCenter` use.
    func send(_ event: PlaybackEvent) {
        continuation.yield(.event(event))
    }

    /// Suspends until every event sent *before this call* has reached the consumer.
    ///
    /// Sealing a session needs this, and the need is not theoretical. Tearing down the feed emits
    /// `.itemReleased` for the item still on screen, which is what closes its record — but that
    /// event travels through the stream asynchronously, so reading the recorder's summary
    /// immediately afterwards would race the drain and persist a session missing its final item
    /// view. Every run would lose its last item, consistently, which is the kind of loss that looks
    /// like a scrolling habit rather than a bug.
    ///
    /// The mechanism is just the ordering guarantee already relied on above: a barrier resuming
    /// means everything queued ahead of it has been consumed.
    func drain() async {
        await withCheckedContinuation { continuation in
            let result = self.continuation.yield(.barrier { continuation.resume() })
            // A finished stream will never deliver the barrier; resume rather than hang.
            if case .terminated = result {
                continuation.resume()
            }
        }
    }

    func finish() {
        continuation.finish()
    }
}

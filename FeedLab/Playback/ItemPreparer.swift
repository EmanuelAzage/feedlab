import AVFoundation
import Foundation

/// Builds a ready-to-attach player item, off the main thread.
///
/// This type exists for one reason, and it is a subtle one. `FeedCoordinator` is `@MainActor`,
/// and an unstructured `Task { }` created inside a main-actor context **inherits that
/// isolation** — so asset and item construction placed directly in that task run on the main
/// thread. Playback still works, because `await` releases the actor while AVFoundation does
/// its I/O elsewhere, which is precisely what makes the mistake invisible in testing.
///
/// `prepare` is `nonisolated async`, so per SE-0338 it executes on the global concurrent
/// executor rather than the caller's actor. That is what actually moves the work off main.
///
/// `docs/architecture.md`: "no asset or item work on the main thread, ever. Scroll smoothness
/// is a measured output; blocking the main thread invalidates the whole rig."
struct ItemPreparer: Sendable {
    /// Loads the asset far enough to build an item, then builds it.
    ///
    /// Cancellable at two points: the load itself, and immediately after. A fast scroll must
    /// stop spending bandwidth on items the user has already passed.
    nonisolated func prepare(url: URL) async throws -> AVPlayerItemAdapter {
        assert(
            !Thread.isMainThread,
            "Asset work reached the main thread — see ItemPreparer's note on Task isolation inheritance."
        )

        let asset = AVURLAsset(url: url)
        try await withTaskCancellationHandler {
            _ = try await asset.load(.isPlayable, .duration)
        } onCancel: {
            // Task cancellation alone does not stop an in-flight asset load.
            asset.cancelLoading()
        }
        try Task.checkCancellation()

        // Also off-main: constructing an AVPlayerItem is not free, and it is the second half
        // of "asset and item work".
        return AVPlayerItemAdapter(asset: asset)
    }
}

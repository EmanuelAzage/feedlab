import AVFoundation
import Foundation

/// Turns visibility into playback intent.
///
/// The seam between the feed surface and the playback engine. It owns the pool, decides which
/// index should be playing, and is the only thing that attaches or detaches players.
///
/// M2 scope: the current item only. Preparing items *ahead* is a `PreloadStrategy` decision
/// (M5); this type deliberately does not guess at one, so the baseline it establishes is
/// genuinely "no preload" rather than an accidental policy.
@MainActor
final class FeedCoordinator {
    /// Everything owed back when an index stops being current. Grouped so teardown cannot
    /// forget a piece — a leaked notification token on a recycled player is the classic bug.
    private struct Attachment {
        let pooled: PooledPlayer
        let item: AVPlayerItemAdapter
        let endOfItemToken: NSObjectProtocol
    }

    private let manifest: Manifest
    private let pool: PlayerPool
    /// Resolves an index to its on-screen cell, or nil if it is not currently displayed.
    private let renderTarget: @MainActor (Int) -> (any PlayerRenderTarget)?

    private var currentIndex: Int?
    private var attachments: [Int: Attachment] = [:]
    private var preparationTasks: [Int: Task<Void, Never>] = [:]

    init(
        manifest: Manifest,
        pool: PlayerPool,
        renderTarget: @escaping @MainActor (Int) -> (any PlayerRenderTarget)?
    ) {
        self.manifest = manifest
        self.pool = pool
        self.renderTarget = renderTarget
    }

    // MARK: - Intent

    /// Called when a page **settles**, not while scrolling.
    ///
    /// Intent on settle rather than on every rounding boundary is what makes a fast scroll
    /// cheap: nothing is prepared for items the user is merely passing over. It also gives
    /// time-to-first-frame an unambiguous `t0` — see `docs/qoe-metrics.md`.
    func settled(on index: Int) {
        guard index != currentIndex else { return }
        guard manifest.items.indices.contains(index) else { return }

        if let previous = currentIndex {
            teardown(index: previous)
        }
        currentIndex = index
        beginPlayback(at: index)
    }

    /// A cell became visible. Re-binds the layer if this index already holds a player, which
    /// happens when a cell is recycled back onto the current item.
    func cellWillDisplay(at index: Int) {
        guard index == currentIndex, let attachment = attachments[index] else { return }
        renderTarget(index)?.attachPlayer(attachment.pooled.player)
    }

    /// A cell scrolled out of the visible set. If it still holds a player, reclaim it — this
    /// is what keeps occupancy bounded during fast scrolling.
    func cellDidEndDisplaying(at index: Int) {
        guard index != currentIndex else { return }
        teardown(index: index)
    }

    /// Releases everything. Called when the feed leaves the screen so a backgrounded rig does
    /// not sit on decode resources.
    func teardownAll() {
        for index in attachments.keys {
            teardown(index: index)
        }
        for (_, task) in preparationTasks {
            task.cancel()
        }
        preparationTasks.removeAll()
        currentIndex = nil
    }

    // MARK: - Preparation

    private func beginPlayback(at index: Int) {
        preparationTasks[index]?.cancel()
        let feedItem = manifest.items[index]

        preparationTasks[index] = Task { [weak self] in
            guard let self else { return }
            defer { self.preparationTasks[index] = nil }

            let asset = AVURLAsset(url: feedItem.url)
            do {
                // Off the main actor: this is network I/O and it is the single most important
                // thing to keep off the main thread, because scroll smoothness is a measured
                // output of this rig.
                try await withTaskCancellationHandler {
                    _ = try await asset.load(.isPlayable, .duration)
                } onCancel: {
                    // Task cancellation alone does not stop an in-flight asset load.
                    asset.cancelLoading()
                }
                try Task.checkCancellation()
            } catch {
                Log.playback.debug("Asset load cancelled or failed for \(feedItem.id, privacy: .public)")
                return
            }

            do {
                let pooled = try await self.pool.acquire()
                // The scroll may have moved on while we waited for a player. If so the player
                // must go straight back, or occupancy climbs by one for every skipped item.
                guard !Task.isCancelled, self.currentIndex == index else {
                    await self.pool.release(pooled)
                    return
                }
                self.attach(pooled: pooled, asset: asset, at: index)
            } catch {
                Log.playback.debug("Player acquire cancelled for \(feedItem.id, privacy: .public)")
            }
        }
    }

    private func attach(pooled: PooledPlayer, asset: AVURLAsset, at index: Int) {
        let item = AVPlayerItemAdapter(asset: asset)

        // Looping by seek-to-zero rather than AVPlayerLooper, which would require an
        // AVQueuePlayer and fragment the item's access log — see `docs/decisions.md`.
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item.item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loop(index: index)
            }
        }

        pooled.player.replaceCurrentItem(with: item)
        attachments[index] = Attachment(pooled: pooled, item: item, endOfItemToken: token)

        renderTarget(index)?.attachPlayer(pooled.player)
        pooled.player.play()

        Log.playback.info(
            """
            Playing index \(index, privacy: .public) \
            (pool wait \(pooled.waitDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms)
            """
        )
    }

    private func loop(index: Int) {
        guard let attachment = attachments[index] else { return }
        attachment.pooled.player.seekToStart()
        attachment.pooled.player.play()
    }

    // MARK: - Teardown

    private func teardown(index: Int) {
        preparationTasks[index]?.cancel()
        preparationTasks[index] = nil

        guard let attachment = attachments.removeValue(forKey: index) else { return }

        // Order matters and is the subject of `PlayerRenderTarget`'s ordering rule: unbind the
        // layer first, then drop the observer, then hand the player back. Releasing first
        // would let the next cell adopt a player the old layer still references.
        renderTarget(index)?.attachPlayer(nil)
        NotificationCenter.default.removeObserver(attachment.endOfItemToken)

        Task { [pool] in
            await pool.release(attachment.pooled)
            // Logged so the M2 acceptance criterion — occupancy returns to zero when idle —
            // is observable rather than inferred from playback appearing to work.
            let occupancy = await pool.occupancy
            let free = await pool.freeCount
            Log.playback.info(
                """
                Released index \(index, privacy: .public) — \
                occupancy \(occupancy, privacy: .public), free \(free, privacy: .public)
                """
            )
        }
    }
}

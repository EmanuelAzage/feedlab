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
        let observer: PlaybackObserver
        /// Periodic time observer driving the scrubber. Another registration that must come off
        /// before the player is recycled, or it keeps firing against the next item's playback.
        var timeObserverToken: Any?
    }

    private let manifest: Manifest
    let pool: PlayerPool
    /// Session-level, so it belongs beside the recorder rather than inside the HUD: peak memory is
    /// attributed to the arm and must be tracked whether or not anyone is looking at it.
    let memoryTracker = MemoryPeakTracker()
    private var memorySamplingTask: Task<Void, Never>?
    private let preparer = ItemPreparer()
    private let clock: any TimestampSource
    private let pipe = PlaybackEventPipe()
    private var forwardingTask: Task<Void, Never>?
    let recorder: SessionRecorder
    /// Resolves an index to its on-screen cell, or nil if it is not currently displayed.
    private let renderTarget: @MainActor (Int) -> (any PlayerRenderTarget)?

    private var currentIndex: Int?
    private var attachments: [Int: Attachment] = [:]
    private var preparationTasks: [Int: Task<Void, Never>] = [:]

    /// Whether the user has deliberately paused the current item.
    ///
    /// Tracked here rather than read from `timeControlStatus`, because the player is also `.paused`
    /// while buffering and during teardown. Only the coordinator knows a pause was *intended*, and
    /// that distinction is the whole basis for excluding it from rebuffer ratio.
    private(set) var isCurrentItemPaused = false

    /// Reports playback progress for the scrubber: index, elapsed, and duration when known.
    ///
    /// A closure rather than a method on `PlayerRenderTarget`, which is about binding a player to a
    /// surface; presenting progress is a separate concern and does not belong on that protocol.
    var onProgress: (@MainActor (Int, TimeInterval, TimeInterval?) -> Void)?

    init(
        manifest: Manifest,
        pool: PlayerPool,
        recorder: SessionRecorder,
        clock: any TimestampSource = MonotonicTimestampSource(),
        renderTarget: @escaping @MainActor (Int) -> (any PlayerRenderTarget)?
    ) {
        self.manifest = manifest
        self.pool = pool
        self.recorder = recorder
        self.clock = clock
        self.renderTarget = renderTarget

        // Detached so draining does not hop through the main actor for every event. Ordering comes
        // from the stream; this task is the single serial consumer `architecture.md` specifies.
        let pipe = self.pipe
        forwardingTask = Task.detached(priority: .utility) {
            for await event in pipe.events {
                await recorder.record(event)
            }
        }

        // Runs regardless of HUD visibility — a session metric must not depend on whether it was
        // being watched. 5 Hz; the figure remains a peak *observed*, never a true peak.
        let tracker = memoryTracker
        memorySamplingTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await tracker.sample()
                try? await Task.sleep(for: MemoryPeakTracker.sampleInterval)
            }
        }
    }

    deinit {
        pipe.finish()
        forwardingTask?.cancel()
        memorySamplingTask?.cancel()
    }

    /// Hands an event to the ordered pipe. Synchronous and thread-safe; the forwarding task drains
    /// it into the recorder in order.
    private nonisolated func emit(_ event: PlaybackEvent, to recorder: SessionRecorder) {
        pipe.send(event)
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
        // A new item always starts playing; pause does not carry across items.
        isCurrentItemPaused = false

        // `t0` for time-to-first-frame: stamped the moment intent exists, *before* any asset work
        // begins. Stamping after the load would measure only the tail of startup and would make
        // preload strategies look better than they are, since preparation is exactly what they
        // move out of this interval.
        emit(
            PlaybackEvent(itemID: manifest.items[index].id, timestamp: clock.now(), kind: .itemBecameCurrent),
            to: recorder
        )
        beginPlayback(at: index)
    }

    // MARK: - User intent

    /// Tap-to-toggle. Emits the events that make the pause exclusion in `qoe-metrics.md` possible:
    /// a deliberate pause is removed from **both** the numerator and denominator of rebuffer ratio,
    /// because a user who walked away did not experience that time as rebuffering.
    ///
    /// Returns the resulting paused state so the caller can update its affordance.
    @discardableResult
    func toggleUserPause() -> Bool {
        guard let index = currentIndex, let attachment = attachments[index] else {
            return isCurrentItemPaused
        }
        let itemID = manifest.items[index].id
        let now = clock.now()

        if isCurrentItemPaused {
            attachment.pooled.player.play()
            emit(PlaybackEvent(itemID: itemID, timestamp: now, kind: .userResumed), to: recorder)
            isCurrentItemPaused = false
        } else {
            attachment.pooled.player.pause()
            emit(PlaybackEvent(itemID: itemID, timestamp: now, kind: .userPaused), to: recorder)
            isCurrentItemPaused = true
        }
        return isCurrentItemPaused
    }

    /// Double-tap. Restarts the current item from the beginning.
    ///
    /// Emits nothing: watch duration is wall-clock from intent to teardown, so replaying does not
    /// change how long the user watched. Seeking is a navigation action, not a measurement event.
    func seekCurrentItemToStart() {
        guard let index = currentIndex, let attachment = attachments[index] else { return }
        attachment.pooled.player.seekToStart()
        if !isCurrentItemPaused {
            attachment.pooled.player.play()
        }
    }

    /// The item currently under playback intent, for the long-press source sheet.
    var currentItem: FeedItem? {
        currentIndex.flatMap { manifest.items.indices.contains($0) ? manifest.items[$0] : nil }
    }

    /// A cell became visible. Re-binds the layer if this index already holds a player, which
    /// happens when a cell is recycled back onto the current item.
    func cellWillDisplay(at index: Int) {
        guard index == currentIndex, let attachment = attachments[index] else { return }
        renderTarget(index)?.attachPlayer(attachment.pooled.player)
    }

    /// A cell scrolled out of the visible set. Reclaim its player.
    ///
    /// Torn down **unconditionally**, including when it is the current index. `product-spec.md`:
    /// "Items leaving the screen pause and release their player back to the pool." An earlier
    /// version skipped teardown for the current index, so during a long drag the departed item
    /// kept playing — audible over cells the user had already scrolled to, and worse, still
    /// accumulating watch duration. Watch duration is the denominator of rebuffer ratio, so
    /// that would have quietly flattered the smoothness of any item the user scrolled away from.
    func cellDidEndDisplaying(at index: Int) {
        teardown(index: index)
        if currentIndex == index {
            // Clear it, or settling back on this index would be treated as "already current"
            // and never restart playback.
            currentIndex = nil
        }
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

        preparationTasks[index] = Task { [weak self, preparer] in
            guard let self else { return }
            defer { self.preparationTasks[index] = nil }

            let item: AVPlayerItemAdapter
            do {
                // `prepare` is nonisolated async, so this hops off the main actor. Doing the
                // work inline here would inherit main-actor isolation — see `ItemPreparer`.
                item = try await preparer.prepare(url: feedItem.url)
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
                self.recordPoolWait(pooled, itemID: feedItem.id)
                self.attach(pooled: pooled, item: item, at: index)
            } catch {
                Log.playback.debug("Player acquire cancelled for \(feedItem.id, privacy: .public)")
            }
        }
    }

    /// Emits the wait bracket only when the acquire actually blocked.
    ///
    /// The bracket is reconstructed from the pool's own measurement rather than timed around the
    /// call, because timing the call would include `AVPlayer` instantiation — which is a cost of
    /// the player, not of contention, and counting it would penalise the `pool-unbounded` arm that
    /// instantiates on nearly every acquire. See `docs/qoe-metrics.md`.
    private func recordPoolWait(_ pooled: PooledPlayer, itemID: String) {
        guard pooled.waitDuration > 0 else { return }
        let ended = clock.now()
        let began = ended - pooled.waitDuration
        emit(PlaybackEvent(itemID: itemID, timestamp: began, kind: .playerWaitBegan), to: recorder)
        emit(PlaybackEvent(itemID: itemID, timestamp: ended, kind: .playerWaitEnded), to: recorder)
    }

    private func attach(pooled: PooledPlayer, item: AVPlayerItemAdapter, at index: Int) {
        let feedItem = manifest.items[index]

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

        let target = renderTarget(index)
        // Attach the layer *before* observing it, so `isReadyForDisplay` is observed on the layer
        // that will actually render this item.
        target?.attachPlayer(pooled.player)

        let observer = PlaybackObserver(
            itemID: feedItem.id,
            player: (pooled.player as? AVPlayerAdapter)?.player ?? AVPlayer(),
            item: item.item,
            layer: target?.readinessLayer,
            clock: clock,
            emit: { [pipe] event in pipe.send(event) }
        )

        attachments[index] = Attachment(
            pooled: pooled,
            item: item,
            endOfItemToken: token,
            observer: observer
        )
        installProgressObserver(for: pooled, at: index)

        pooled.player.play()

        Log.playback.info(
            """
            Playing index \(index, privacy: .public) \
            (pool wait \(pooled.waitDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms)
            """
        )
    }

    /// Drives the scrubber at 4 Hz.
    ///
    /// The interval is the same budget the HUD gets (`docs/observability.md`): fast enough to look
    /// continuous, slow enough not to become a load source. Note this cost is present in *every*
    /// arm, so it shifts absolute numbers without biasing the comparison between them — but it is
    /// still real, and it is the reason the interval is a stated choice rather than a default.
    private func installProgressObserver(for pooled: PooledPlayer, at index: Int) {
        guard let avPlayer = (pooled.player as? AVPlayerAdapter)?.player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        let token = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.reportProgress(at: index, elapsed: time.seconds)
            }
        }
        attachments[index]?.timeObserverToken = token
    }

    private func reportProgress(at index: Int, elapsed: TimeInterval) {
        guard let attachment = attachments[index] else { return }
        let duration = attachment.item.item.duration
        onProgress?(index, elapsed, duration.isNumeric ? duration.seconds : nil)
    }

    /// Reports the folded record once the item view closes.
    ///
    /// Temporary until the HUD (M4) and dashboard (M6) surface these properly, but useful now: it
    /// is the first point at which the whole chain — observation, stamping, ordered delivery, and
    /// the pure fold — can be seen producing a number end to end.
    private nonisolated static func logRecord(for itemID: String, from recorder: SessionRecorder) async {
        guard let record = await recorder.records.last(where: { $0.itemID == itemID }) else { return }
        let ttff = record.timeToFirstFrame.map { String(format: "%.0f ms", $0 * 1000) } ?? "never rendered"
        let switches = record.bitrateSwitchCount.map(String.init) ?? "n/a"
        Log.metrics.info(
            """
            \(itemID, privacy: .public): ttff \(ttff, privacy: .public), \
            watch \(record.watchDuration, format: .fixed(precision: 2), privacy: .public)s, \
            stalls \(record.stallCount, privacy: .public) \
            (\(record.totalStallDuration, format: .fixed(precision: 2), privacy: .public)s, \
            ratio \(record.rebufferRatio, format: .fixed(precision: 3), privacy: .public)), \
            switches \(switches, privacy: .public), \
            wait \(record.playerWaitDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms
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

        // Closes watch accounting, and closes any stall still open at this moment — an item the
        // user scrolled away from while it was still spinning really did stall for that long.
        emit(
            PlaybackEvent(itemID: manifest.items[index].id, timestamp: clock.now(), kind: .itemReleased),
            to: recorder
        )

        // Order matters and is the subject of `PlayerRenderTarget`'s ordering rule: unbind the
        // layer first, then drop every observation, then hand the player back. Releasing first
        // would let the next cell adopt a player the old layer still references, and a surviving
        // KVO registration would attribute the next item's events to this one.
        renderTarget(index)?.attachPlayer(nil)
        attachment.observer.invalidate()
        NotificationCenter.default.removeObserver(attachment.endOfItemToken)
        if let token = attachment.timeObserverToken,
           let avPlayer = (attachment.pooled.player as? AVPlayerAdapter)?.player {
            avPlayer.removeTimeObserver(token)
        }

        let itemID = manifest.items[index].id
        Task { [pool, recorder] in
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
            await Self.logRecord(for: itemID, from: recorder)
        }
    }
}

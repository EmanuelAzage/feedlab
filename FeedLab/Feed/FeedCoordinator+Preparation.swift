import AVFoundation
import Foundation

/// The tier state machine: how an index gets from nothing to playing, and back.
///
/// Split out of `FeedCoordinator` for length rather than for boundary — the two files are one type.
/// The transitions here are the concrete form of the two-tier preparation model in
/// `docs/playback-engine.md`: tier 1 costs a network round trip, tier 2 costs a pool slot, and only
/// tier 2 actually buffers.
extension FeedCoordinator {
    // MARK: - Advancing an index toward its tier

    /// Moves one index toward the tier the plan wants, doing nothing if it is already there.
    func advance(index: Int, tier: Tier) {
        let preparation = preparations[index]

        switch tier {
        case .warm:
            // Overflow beyond capacity: hand the player back but keep the loaded item, so an
            // under-provisioned arm degrades to tier 1 rather than losing the index.
            if preparation?.pooled != nil {
                unback(index: index)
            }
            guard preparation == nil else { return }
        case .backed:
            guard preparation?.pooled == nil else { return }
        case .current:
            guard preparation?.live == nil else { return }
            if preparation?.pooled != nil {
                // The preload payoff, and the only synchronous promotion in the engine: the item
                // is already buffering, so becoming current costs no asset load and no acquire.
                promote(index: index)
                return
            }
        }

        startPreparation(index: index, tier: tier)
    }

    /// Whether the plan still wants this index at all. Checked after every suspension point, since
    /// the scroll can move on while an asset loads or a player is awaited.
    func isPlanned(_ index: Int) -> Bool {
        plan?.allPrepared.contains(index) ?? false
    }

    /// The arm's buffer configuration for an index, by its offset from the current item.
    func configuration(forIndex index: Int) -> BufferConfiguration {
        guard let currentIndex else { return .systemDefault }
        return arm.strategy.bufferConfiguration(for: index - currentIndex)
    }

    func cancelPreparation(at index: Int) {
        preparationTasks[index]?.cancel()
        preparationTasks[index] = nil
    }

    // MARK: - Tier 1 → tier 2

    private func startPreparation(index: Int, tier: Tier) {
        guard preparationTasks[index] == nil else { return }
        let feedItem = manifest.items[index]

        preparationTasks[index] = Task { [weak self, preparer] in
            guard let self else { return }
            // Clear only our own entry: a cancellation may already have replaced it.
            defer { if !Task.isCancelled { self.preparationTasks[index] = nil } }

            // Tier 1 — playerless warm. Skipped when the item is already built, which is what lets
            // an index promote from warm to backed without re-fetching its playlist.
            if self.preparations[index] == nil {
                let item: AVPlayerItemAdapter
                self.signposter.begin(.assetLoad, itemID: feedItem.id)
                do {
                    // `prepare` is nonisolated async, so this hops off the main actor. Doing the
                    // work inline here would inherit main-actor isolation — see `ItemPreparer`.
                    item = try await preparer.prepare(url: feedItem.url)
                } catch {
                    self.signposter.end(.assetLoad, itemID: feedItem.id)
                    Log.playback.debug("Asset load cancelled or failed for \(feedItem.id, privacy: .public)")
                    return
                }
                self.signposter.end(.assetLoad, itemID: feedItem.id)
                guard !Task.isCancelled, self.isPlanned(index) else { return }
                // Item-level levers applied before any player can adopt it, so a capped arm is
                // never briefly uncapped — at the system default the forward buffer fills to
                // hundreds of seconds within a few (measured, M2).
                item.apply(self.configuration(forIndex: index))
                self.preparations[index] = Preparation(item: item)
            }

            guard tier != .warm else { return }

            // Tier 2 — player-backed, and therefore buffering. Only the current item may block:
            // a queued preload acquire would be served ahead of the next item the user actually
            // reaches, since waiters are FIFO. See `PlayerPool.acquireIfAvailable`.
            let pooled: PooledPlayer?
            if tier == .current {
                // Bracketed even when it does not block: a span of near-zero width against one that
                // is visibly wide is exactly how contention reads on the track.
                self.signposter.begin(.playerAcquire, itemID: feedItem.id)
                pooled = try? await self.pool.acquire()
                self.signposter.end(.playerAcquire, itemID: feedItem.id)
            } else {
                pooled = await self.pool.acquireIfAvailable()
            }
            // Nothing going spare: the item stays warm. A visible degradation, not a hidden wait.
            guard let pooled else { return }

            // The scroll may have moved on while we waited. If so the player goes straight back,
            // or occupancy climbs by one for every item the user passed.
            guard !Task.isCancelled, self.isPlanned(index), self.preparations[index] != nil else {
                await self.pool.release(pooled)
                return
            }
            self.adopt(pooled: pooled, at: index)
        }
    }

    /// Binds a pooled player to a prepared item — the moment tier 1 becomes tier 2 and buffering
    /// actually starts.
    private func adopt(pooled: PooledPlayer, at index: Int) {
        guard var preparation = preparations[index] else {
            // Unreachable as called, but a dropped player is a pool slot lost for the rest of the
            // session, which is worth a branch rather than an assumption.
            Task { [pool] in await pool.release(pooled) }
            return
        }

        signposter.begin(.attach, itemID: manifest.items[index].id)
        pooled.player.replaceCurrentItem(with: preparation.item)
        // *After* `replaceCurrentItem`, not before: `AVPlayerAdapter.apply` forwards the item-level
        // levers to whatever item is currently attached, so applying first would configure nothing.
        pooled.player.apply(configuration(forIndex: index))
        preparation.pooled = pooled
        preparations[index] = preparation
        signposter.end(.attach, itemID: manifest.items[index].id)

        if index == currentIndex {
            recordPoolWait(pooled, itemID: manifest.items[index].id)
            promote(index: index)
        } else {
            Log.playback.debug("Preloaded index \(index, privacy: .public) (tier 2)")
        }

        // The current item landing may have freed the way for preload that was declined earlier;
        // re-derive rather than guess which.
        reconcile()
    }

    // MARK: - Becoming, and ceasing to be, the current item

    /// Tier 2 → current: attach the layer, start observing, play.
    func promote(index: Int) {
        guard var preparation = preparations[index],
              let pooled = preparation.pooled,
              preparation.live == nil else { return }
        let feedItem = manifest.items[index]

        // The current item plays at the strategy's offset-0 configuration. A preloaded item was
        // configured as a *non-current* one — under `PreloadNext3Capped` that means a capped
        // forward buffer and a capped bitrate ladder — and without this it would keep playing under
        // the preload cap, so the arm would measure a throttled current item rather than a
        // preloaded one.
        pooled.player.apply(arm.strategy.bufferConfiguration(for: 0))

        // Looping by seek-to-zero rather than AVPlayerLooper, which would require an
        // AVQueuePlayer and fragment the item's access log — see `docs/decisions.md`.
        let token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: preparation.item.item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loop(index: index)
            }
        }

        let target = renderTarget(index)
        // A layer still reporting `isReadyForDisplay` from its previous occupant would stamp `t1`
        // immediately and report a near-zero time-to-first-frame. That was survivable before
        // preload, where an instant first frame was obviously wrong; now it is exactly what a
        // preload win looks like, so the two would be indistinguishable — and it would flatter
        // precisely the arms under test. The unbind in `demote` and `FeedCell.prepareForReuse` are
        // what keep this true; this asserts it rather than trusting it.
        assert(
            target?.readinessLayer?.isReadyForDisplay != true,
            "Layer still ready for display from a previous item — time-to-first-frame would be fiction."
        )
        // Attach the layer *before* observing it, so `isReadyForDisplay` is observed on the layer
        // that will actually render this item.
        target?.attachPlayer(pooled.player)

        preparation.live = LiveRegistrations(
            endOfItemToken: token,
            observer: makeObserver(
                for: feedItem.id,
                player: pooled.player,
                item: preparation.item,
                layer: target?.readinessLayer
            )
        )
        preparations[index] = preparation
        installProgressObserver(for: pooled, at: index)

        pooled.player.play()

        Log.playback.info(
            """
            Playing index \(index, privacy: .public) [\(self.arm.name, privacy: .public)] \
            (pool wait \(pooled.waitDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms)
            """
        )
    }

    /// Current → tier 2: stop playing and close the record, but keep the player.
    ///
    /// Every registration made in `promote` comes off here. The player itself stays, because with
    /// preload an item can legitimately hold one while off-screen — see `cellDidEndDisplaying`.
    func demote(index: Int) {
        guard var preparation = preparations[index], let live = preparation.live else { return }

        // Closes watch accounting, and closes any stall still open at this moment — an item the
        // user scrolled away from while it was still spinning really did stall for that long.
        emit(.itemReleased, at: index)

        // Order matters and is the subject of `PlayerRenderTarget`'s ordering rule: unbind the
        // layer first, then drop every observation. Unbinding is also what clears
        // `isReadyForDisplay`, which the assertion in `promote` depends on.
        renderTarget(index)?.attachPlayer(nil)
        live.observer.invalidate()
        NotificationCenter.default.removeObserver(live.endOfItemToken)
        if let token = live.timeObserverToken,
           let avPlayer = (preparation.pooled?.player as? AVPlayerAdapter)?.player {
            avPlayer.removeTimeObserver(token)
        }

        // Paused rather than released: the plan decides whether this index keeps its player.
        preparation.pooled?.player.pause()
        preparation.live = nil
        preparations[index] = preparation

        let itemID = manifest.items[index].id
        // An interval left open would run to the end of the trace and read as a multi-minute stall.
        signposter.abandon(itemID: itemID)
        Task { [recorder] in
            await Self.logRecord(for: itemID, from: recorder)
        }
    }

    // MARK: - Giving resources back

    /// Tier 2 → tier 1: hand the player back, keep the loaded item.
    ///
    /// Reached only when a strategy asks for more player-backed items than the pool can supply,
    /// which none of the declared arms do (`ArmRegistry.capacityCoversPreparedSet` asserts it). It
    /// exists so that an under-provisioned arm degrades measurably instead of silently.
    private func unback(index: Int) {
        guard var preparation = preparations[index],
              preparation.live == nil,
              let pooled = preparation.pooled else { return }
        preparation.pooled = nil
        preparations[index] = preparation
        Task { [pool] in await pool.release(pooled) }
    }

    /// Drops an index entirely: no item, no player, no in-flight preparation.
    func release(index: Int) {
        demote(index: index)
        cancelPreparation(at: index)

        guard let preparation = preparations.removeValue(forKey: index) else { return }
        // A warm-only index holds no player, so there is nothing to give back.
        guard let pooled = preparation.pooled else { return }

        Task { [pool] in
            await pool.release(pooled)
            // Logged so the M2 acceptance criterion — occupancy returns to zero when idle — stays
            // observable rather than inferred from playback appearing to work.
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

    // MARK: - Incidentals

    /// Emits the wait bracket only when the acquire actually blocked.
    ///
    /// The bracket is reconstructed from the pool's own measurement rather than timed around the
    /// call, because timing the call would include `AVPlayer` instantiation — a cost of the player,
    /// not of contention, and counting it would penalise the `pool-unbounded` arm that instantiates
    /// on nearly every acquire. See `docs/qoe-metrics.md`.
    private func recordPoolWait(_ pooled: PooledPlayer, itemID: String) {
        guard pooled.waitDuration > 0 else { return }
        let ended = clock.now()
        let began = ended - pooled.waitDuration
        emit(PlaybackEvent(itemID: itemID, timestamp: began, kind: .playerWaitBegan))
        emit(PlaybackEvent(itemID: itemID, timestamp: ended, kind: .playerWaitEnded))
    }

    /// Drives the scrubber at 4 Hz, for the current item only.
    ///
    /// The interval is the same budget the HUD gets (`docs/observability.md`): fast enough to look
    /// continuous, slow enough not to become a load source. This cost is present in *every* arm, so
    /// it shifts absolute numbers without biasing the comparison between them — but it is still
    /// real, and it is the reason the interval is a stated choice rather than a default.
    private func installProgressObserver(for pooled: PooledPlayer, at index: Int) {
        guard let avPlayer = (pooled.player as? AVPlayerAdapter)?.player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        let token = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.reportProgress(at: index, elapsed: time.seconds)
            }
        }
        preparations[index]?.live?.timeObserverToken = token
    }

    private func reportProgress(at index: Int, elapsed: TimeInterval) {
        guard let preparation = preparations[index] else { return }
        let duration = preparation.item.item.duration
        onProgress?(index, elapsed, duration.isNumeric ? duration.seconds : nil)
    }

    private func loop(index: Int) {
        guard let player = preparations[index]?.pooled?.player else { return }
        player.seekToStart()
        player.play()
    }

    /// Reports the folded record once the item view closes.
    ///
    /// Temporary until the dashboard (M6) surfaces these properly, but useful now: it is the point
    /// at which the whole chain — observation, stamping, ordered delivery, and the pure fold — can
    /// be seen producing a number end to end.
    nonisolated static func logRecord(for itemID: String, from recorder: SessionRecorder) async {
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
}

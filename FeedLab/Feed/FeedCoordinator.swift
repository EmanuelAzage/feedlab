import AVFoundation
import Foundation

/// Turns visibility into playback intent, and the arm's strategy into prepared items.
///
/// The seam between the feed surface and the playback engine. It owns the pool, decides which
/// index should be playing, and is the only thing that attaches or detaches players.
///
/// The state machine that does the preparing lives in `FeedCoordinator+Preparation.swift`; this
/// file is what the feed surface asks for. Members shared across the two are internal rather than
/// private because `private` is file-scoped in Swift — FeedLab is a single module, so this is a
/// readability split, not a boundary.
@MainActor
final class FeedCoordinator {
    /// How far one index has been prepared.
    ///
    /// Three states, expressed as two optionals rather than an enum so a transition can add or drop
    /// one facet without rebuilding the others:
    ///
    /// | State | `pooled` | `live` | Meaning |
    /// |---|---|---|---|
    /// | **warm** (tier 1) | nil | nil | asset loaded, item built — **not buffering** |
    /// | **backed** (tier 2) | set | nil | a player has adopted the item: buffering, paused, unobserved |
    /// | **current** | set | set | rendering into a cell, observed, playing |
    ///
    /// The tiers are not a taxonomy invented here — they are the two-tier preparation model in
    /// `docs/playback-engine.md`, which exists because an `AVPlayerItem` does not buffer until a
    /// player adopts it. `live` implies `pooled`: only a backed item can be promoted.
    struct Preparation {
        let item: AVPlayerItemAdapter
        var pooled: PooledPlayer?
        var live: LiveRegistrations?
    }

    /// The registrations that exist only while an index is *the current item*.
    ///
    /// Grouped so demotion cannot forget a piece — a leaked notification token on a recycled player
    /// is the classic bug. Deliberately absent while an item is merely preloaded: a preloaded item
    /// is not observed, because a stall it suffers off-screen is not one the user experienced.
    struct LiveRegistrations {
        let endOfItemToken: NSObjectProtocol
        let observer: PlaybackObserver
        /// Periodic time observer driving the scrubber. Another registration that must come off
        /// before the player is recycled, or it keeps firing against the next item's playback.
        var timeObserverToken: Any?
    }

    /// How far the plan wants a given index prepared.
    enum Tier {
        case warm
        case backed
        case current
    }

    let manifest: Manifest
    /// The experimental condition in force: strategy plus pool size. Swapping it is what makes the
    /// arms differ in behaviour rather than only in label.
    private(set) var arm: Arm
    /// A `var` because capacity is per-arm and `PlayerPool.capacity` is immutable by design — a pool
    /// whose capacity could change under its own waiters would not be the thing being measured.
    /// Switching arms therefore swaps the pool rather than resizing it.
    private(set) var pool: PlayerPool
    /// Session-level, so it belongs beside the recorder rather than inside the HUD: peak memory is
    /// attributed to the arm and must be tracked whether or not anyone is looking at it.
    let memoryTracker = MemoryPeakTracker()
    private var memorySamplingTask: Task<Void, Never>?
    let preparer = ItemPreparer()
    let clock: any TimestampSource
    private let pipe = PlaybackEventPipe()
    private var forwardingTask: Task<Void, Never>?
    let recorder: SessionRecorder
    /// Where completed sessions go. Optional so a coordinator still runs when the store cannot
    /// reach its directory — the feed is degraded, not broken.
    let store: SessionStore?
    /// Resolves an index to its on-screen cell, or nil if it is not currently displayed.
    let renderTarget: @MainActor (Int) -> (any PlayerRenderTarget)?

    var currentIndex: Int?
    var preparations: [Int: Preparation] = [:]
    var preparationTasks: [Int: Task<Void, Never>] = [:]

    /// Whether the user has deliberately paused the current item.
    ///
    /// Tracked here rather than read from `timeControlStatus`, because the player is also `.paused`
    /// while buffering, while preloaded, and during teardown. Only the coordinator knows a pause was
    /// *intended*, and that distinction is the whole basis for excluding it from rebuffer ratio.
    private(set) var isCurrentItemPaused = false

    /// Reports playback progress for the scrubber: index, elapsed, and duration when known.
    ///
    /// A closure rather than a method on `PlayerRenderTarget`, which is about binding a player to a
    /// surface; presenting progress is a separate concern and does not belong on that protocol.
    var onProgress: (@MainActor (Int, TimeInterval, TimeInterval?) -> Void)?

    init(
        manifest: Manifest,
        arm: Arm,
        pool: PlayerPool,
        recorder: SessionRecorder,
        store: SessionStore?,
        clock: any TimestampSource = MonotonicTimestampSource(),
        renderTarget: @escaping @MainActor (Int) -> (any PlayerRenderTarget)?
    ) {
        self.manifest = manifest
        self.arm = arm
        self.pool = pool
        self.recorder = recorder
        self.store = store
        self.clock = clock
        self.renderTarget = renderTarget

        // Detached so draining does not hop through the main actor for every event. Ordering comes
        // from the stream; this task is the single serial consumer `architecture.md` specifies.
        let pipe = self.pipe
        forwardingTask = Task.detached(priority: .utility) {
            for await element in pipe.elements {
                switch element {
                case .event(let event):
                    await recorder.record(event)
                case .barrier(let resume):
                    // Reached only after every event queued ahead of it has been recorded.
                    resume()
                }
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
    nonisolated func emit(_ event: PlaybackEvent) {
        pipe.send(event)
    }

    /// Emits for an index, which is the common case — every event the coordinator itself raises is
    /// about the item at some index.
    func emit(_ kind: PlaybackEvent.Kind, at index: Int) {
        guard manifest.items.indices.contains(index) else { return }
        emit(PlaybackEvent(itemID: manifest.items[index].id, timestamp: clock.now(), kind: kind))
    }

    /// Builds the `PlaybackObserver` for a promoted item. Here rather than in the extension so the
    /// pipe stays private to this file.
    func makeObserver(for itemID: String, player: any PlayerProviding, item: AVPlayerItemAdapter,
                      layer: AVPlayerLayer?) -> PlaybackObserver {
        PlaybackObserver(
            itemID: itemID,
            player: (player as? AVPlayerAdapter)?.player ?? AVPlayer(),
            item: item.item,
            layer: layer,
            clock: clock,
            emit: { [pipe] event in pipe.send(event) }
        )
    }

    // MARK: - Intent

    /// Called when a page **settles**, not while scrolling.
    ///
    /// Intent on settle rather than on every rounding boundary is what makes a fast scroll cheap:
    /// nothing is prepared for items the user is merely passing over. It also gives
    /// time-to-first-frame an unambiguous `t0` — see `docs/qoe-metrics.md`.
    func settled(on index: Int) {
        guard index != currentIndex else { return }
        guard manifest.items.indices.contains(index) else { return }

        if let previous = currentIndex {
            // Demote, not release: the outgoing item may still be in the incoming plan, and
            // reconciliation below decides that. What must stop now is the playing.
            demote(index: previous)
        }
        currentIndex = index
        // A new item always starts playing; pause does not carry across items.
        isCurrentItemPaused = false

        // `t0` for time-to-first-frame: stamped the moment intent exists, *before* any preparation
        // is consulted. Stamping later would measure only the tail of startup and would make
        // preload strategies look better than they are, since preparation is exactly what they move
        // out of this interval. A preloaded item is fast here because it really is ready, not
        // because the clock started late.
        emit(.itemBecameCurrent, at: index)
        reconcile()
    }

    // MARK: - User intent

    /// Tap-to-toggle. Emits the events that make the pause exclusion in `qoe-metrics.md` possible:
    /// a deliberate pause is removed from **both** the numerator and denominator of rebuffer ratio,
    /// because a user who walked away did not experience that time as rebuffering.
    ///
    /// Returns the resulting paused state so the caller can update its affordance.
    @discardableResult
    func toggleUserPause() -> Bool {
        guard let index = currentIndex, let player = preparations[index]?.pooled?.player else {
            return isCurrentItemPaused
        }

        if isCurrentItemPaused {
            player.play()
            emit(.userResumed, at: index)
            isCurrentItemPaused = false
        } else {
            player.pause()
            emit(.userPaused, at: index)
            isCurrentItemPaused = true
        }
        return isCurrentItemPaused
    }

    /// Double-tap. Restarts the current item from the beginning.
    ///
    /// Emits nothing: watch duration is wall-clock from intent to teardown, so replaying does not
    /// change how long the user watched. Seeking is a navigation action, not a measurement event.
    func seekCurrentItemToStart() {
        guard let index = currentIndex, let player = preparations[index]?.pooled?.player else { return }
        player.seekToStart()
        if !isCurrentItemPaused {
            player.play()
        }
    }

    /// The item currently under playback intent, for the long-press source sheet.
    var currentItem: FeedItem? {
        currentIndex.flatMap { manifest.items.indices.contains($0) ? manifest.items[$0] : nil }
    }

    // MARK: - Cell lifecycle

    /// A cell became visible. Re-binds the layer if this index is the current item, which happens
    /// when a cell is recycled back onto it.
    func cellWillDisplay(at index: Int) {
        guard index == currentIndex,
              let preparation = preparations[index],
              preparation.live != nil,
              let pooled = preparation.pooled else { return }
        renderTarget(index)?.attachPlayer(pooled.player)
    }

    /// A cell scrolled out of the visible set.
    ///
    /// **Demotes rather than releases**, and that is a correction to the shape of the M2 fix rather
    /// than a reversal of it. The bug then was that a departed item kept *playing* — audible over
    /// cells the user had already scrolled to, and still accruing watch duration, which is the
    /// denominator of rebuffer ratio. The remedy chosen was full teardown, which happened to be
    /// equivalent because nothing else could hold a player.
    ///
    /// With preload that equivalence breaks: an item legitimately holds a player while off-screen.
    /// So the two concerns come apart — demotion stops the playing and closes the record, and the
    /// *plan*, not cell visibility, decides whether the player goes back.
    func cellDidEndDisplaying(at index: Int) {
        demote(index: index)
        if currentIndex == index {
            // Clear it, or settling back on this index would be treated as "already current"
            // and never restart playback.
            currentIndex = nil
        }
    }

    /// Releases everything. Called when the feed leaves the screen so a backgrounded rig does not
    /// sit on decode resources.
    func teardownAll() {
        for index in Array(preparations.keys) {
            release(index: index)
        }
        for index in Array(preparationTasks.keys) {
            cancelPreparation(at: index)
        }
        currentIndex = nil
    }

    // MARK: - Arms

    /// Switches the experimental condition and **resets the session**.
    ///
    /// Resetting is not tidiness. `docs/experiment-harness.md` treats a session as one arm's run, and
    /// records carry the arm name — so folding two arms' items into one session would attribute
    /// half of them to the wrong condition, and the peak-memory figure, which is a *session* metric,
    /// would belong to neither. Nothing survives the switch: records, buffered events, and the
    /// memory peak all go.
    ///
    /// The pool is replaced rather than resized, because capacity is fixed for the life of a pool
    /// and an arm is a capacity as much as it is a strategy.
    func apply(arm: Arm, pool newPool: PlayerPool) async {
        teardownAll()
        await sealSession()

        let retired = pool
        self.arm = arm
        pool = newPool

        // Idle players in the retired pool are torn down now rather than at deallocation, so the
        // buffers they hold do not overlap with the incoming arm's — which would land in the new
        // arm's peak memory and be attributed to it.
        await retired.drain()

        await recorder.reset(arm: arm.name)
        await memoryTracker.reset()

        Log.playback.info("Arm → \(arm.name, privacy: .public), session reset")
    }

    /// Persists the session as it stands, if it measured anything.
    ///
    /// Called before an arm switch and when the app backgrounds — the two moments a session
    /// genuinely ends. Draining the pipe first is load-bearing: teardown emits `.itemReleased` for
    /// the item still on screen, and that is what closes its record, so reading the summary without
    /// waiting would persist a session missing its final item view on **every** run.
    ///
    /// A session with no records is not written. An arm selected and immediately changed again
    /// measured nothing, and an empty session in the dashboard is indistinguishable from an arm
    /// that failed.
    func sealSession() async {
        await pipe.drain()

        let peak = await memoryTracker.peakBytes
        let summary = await recorder.summary(peakMemoryBytes: peak)
        guard !summary.records.isEmpty else { return }

        let events = await recorder.allArchivedEvents
        let session = StoredSession(summary: summary, events: events)
        do {
            try await store?.save(session)
            Log.metrics.info(
                """
                Sealed session [\(summary.arm, privacy: .public)] — \
                \(summary.records.count, privacy: .public) items, \
                peak \(Double(peak) / 1_048_576, format: .fixed(precision: 1), privacy: .public) MB
                """
            )
        } catch {
            // Loud, because the alternative is discovering after a device afternoon that nothing
            // was written.
            Log.metrics.error("Failed to persist session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Planning

    /// The arm's intent for the current index, resolved against pool capacity.
    var plan: PreparationPlan? {
        guard let currentIndex else { return nil }
        return PreparationPlanner.plan(
            currentIndex: currentIndex,
            totalCount: manifest.items.count,
            strategy: arm.strategy,
            capacity: pool.capacity
        )
    }

    /// Brings the prepared set in line with the plan.
    ///
    /// Re-derives from the plan rather than patching incrementally, and is called again whenever an
    /// asynchronous step lands, so the engine converges on the plan from any intermediate state
    /// instead of depending on the order things completed in. Affordable because a plan is at most
    /// four indices.
    func reconcile() {
        guard let currentIndex, let plan else { return }

        // Release strays *first*, so slots the plan no longer wants are back before anything asks
        // for one. This is what makes the current item's blocking acquire safe: `PreparationPlanner`
        // guarantees `playerBacked.count ≤ capacity`, so once the strays are gone there is room.
        let planned = Set(plan.allPrepared)
        for index in Array(preparations.keys) where !planned.contains(index) {
            release(index: index)
        }
        for index in Array(preparationTasks.keys) where !planned.contains(index) {
            cancelPreparation(at: index)
        }

        // Current item first: it is the only one allowed to block for a player.
        for index in plan.playerBacked {
            advance(index: index, tier: index == currentIndex ? .current : .backed)
        }
        for index in plan.warmOnly {
            advance(index: index, tier: .warm)
        }
    }
}

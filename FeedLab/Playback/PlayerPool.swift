import Foundation

/// How many players may exist at once.
enum PoolCapacity: Equatable, Sendable {
    case bounded(Int)
    /// The deliberate negative-control arm. Exists to demonstrate the cost of *not* bounding,
    /// never as a shortcut — see `docs/decisions.md`.
    case unbounded
}

/// A player checked out of the pool, with the cost of obtaining it.
struct PooledPlayer: Sendable {
    let player: any PlayerProviding
    /// Time spent waiting for a free player. Zero when one was available immediately.
    ///
    /// Recorded separately from time-to-first-frame rather than folded into it, so the two
    /// causes of slow startup — pool contention and network/decode — stay distinguishable.
    let waitDuration: TimeInterval
}

protocol PlayerPooling: Sendable {
    var capacity: PoolCapacity { get }
    func acquire() async throws -> PooledPlayer
    /// A player only if one is free right now. Never blocks, never queues. See the implementation
    /// note — this exists so speculative preload cannot get in front of the user.
    func acquireIfAvailable() async -> PooledPlayer?
    func release(_ pooled: PooledPlayer) async
}

/// A bounded pool of recycled players.
///
/// The architectural centerpiece: cells recycle on scroll geometry, players recycle on
/// playback intent, and keeping those independent is what makes capacity an experiment
/// variable instead of an emergent property of scrolling.
///
/// An actor because it *is* the serial context that owns the free list. Exhaustion blocks the
/// caller rather than allocating — allocating past capacity would quietly answer the question
/// the rig is asking.
actor PlayerPool: PlayerPooling {
    nonisolated let capacity: PoolCapacity

    private let makePlayer: @Sendable () -> any PlayerProviding
    private let clock: any TimestampSource

    private var freeList: [any PlayerProviding] = []
    private var checkedOutCount = 0
    /// Players that exist right now (free + checked out). Governs capacity.
    private var liveCount = 0
    /// Total ever created. Diagnostic only — a test asserts this never exceeds capacity.
    private(set) var instantiationCount = 0

    private var waiters: [UUID: CheckedContinuation<any PlayerProviding, any Error>] = [:]
    private var waiterOrder: [UUID] = []

    init(
        capacity: PoolCapacity,
        clock: any TimestampSource = MonotonicTimestampSource(),
        makePlayer: @escaping @Sendable () -> any PlayerProviding = { AVPlayerAdapter() }
    ) {
        self.capacity = capacity
        self.clock = clock
        self.makePlayer = makePlayer
    }

    // MARK: - Observable state

    /// Checked-out players. Surfaced in the HUD as pool occupancy.
    var occupancy: Int { checkedOutCount }

    /// Callers currently blocked waiting for a player. Non-zero means real contention.
    var pendingAcquireCount: Int { waiterOrder.count }

    /// Idle players held for reuse.
    var freeCount: Int { freeList.count }

    // MARK: - Acquire / release

    func acquire() async throws -> PooledPlayer {
        try Task.checkCancellation()

        if let player = takeImmediately() {
            // Zero, not elapsed. Obtaining a player without blocking is not *waiting*, even
            // though instantiating one costs real time (~5 ms on simulator). Counting that as
            // wait would penalise `pool-unbounded`, which instantiates on nearly every
            // acquire — and that arm exists precisely to look good on startup and bad on
            // memory. `playerWaitDuration` measures contention; see `docs/qoe-metrics.md`.
            return PooledPlayer(player: player, waitDuration: 0)
        }

        // The clock starts only once we are certain we must block.
        let start = clock.now()
        let id = UUID()
        let player = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        return PooledPlayer(player: player, waitDuration: clock.now() - start)
    }

    /// Takes a free player, or nothing.
    ///
    /// **Only the current item may block.** Waiters are served FIFO, so a preload acquire that
    /// queued would sit *ahead* of the acquire for whichever item the user scrolls to next — the
    /// item they are actually waiting on would wait behind speculative work for one they may never
    /// reach. Preload would then inflate the very metric it exists to reduce, and
    /// `playerWaitDuration` would stop meaning "genuine contention" (`docs/qoe-metrics.md`).
    ///
    /// Returning nil leaves the item at tier 1 — asset loaded, not buffering — which is a
    /// degradation the rig can see rather than a latency it cannot.
    ///
    /// Cannot overtake a queued waiter, and does not need a guard to prevent it: a waiter only
    /// exists because the free list was empty at capacity, and a subsequent release hands the
    /// player straight to that waiter without passing through the free list or changing
    /// `liveCount`. A test asserts this rather than leaving it to the argument.
    func acquireIfAvailable() -> PooledPlayer? {
        guard let player = takeImmediately() else { return nil }
        // Zero by construction, not by measurement: this path cannot have waited.
        return PooledPlayer(player: player, waitDuration: 0)
    }

    func release(_ pooled: PooledPlayer) {
        // Teardown happens before the player is visible to anyone else. Handing a player to
        // the next caller still holding its old item is how a frame of the wrong video ends
        // up in the wrong cell.
        pooled.player.reset()
        checkedOutCount -= 1

        guard let id = waiterOrder.first else {
            freeList.append(pooled.player)
            return
        }
        // Hand straight to the longest-waiting caller rather than round-tripping through the
        // free list, so a queued acquire cannot be overtaken by a fresh one.
        waiterOrder.removeFirst()
        let continuation = waiters.removeValue(forKey: id)
        checkedOutCount += 1
        continuation?.resume(returning: pooled.player)
    }

    /// Tears down every idle player, releasing decode resources without disturbing playback in
    /// progress. Capacity is unaffected: drained slots may be re-created on demand.
    func drain() {
        for player in freeList {
            player.reset()
        }
        liveCount -= freeList.count
        freeList.removeAll()
    }

    // MARK: - Internals

    private func takeImmediately() -> (any PlayerProviding)? {
        if let player = freeList.popLast() {
            checkedOutCount += 1
            return player
        }
        guard canInstantiate else { return nil }
        let player = makePlayer()
        liveCount += 1
        instantiationCount += 1
        checkedOutCount += 1
        return player
    }

    private var canInstantiate: Bool {
        switch capacity {
        case .unbounded: true
        case .bounded(let limit): liveCount < limit
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }
}

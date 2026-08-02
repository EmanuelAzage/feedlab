import Foundation
import Testing

@testable import FeedLab

@Suite("Bounded player pool")
struct PlayerPoolTests {
    /// Spins until `condition` holds, yielding in between. Used to observe an actor reaching a
    /// state a suspended task is responsible for producing, without sleeping for a guessed
    /// duration — which would be both slower and flaky.
    private func waitUntil(
        _ condition: @Sendable () async -> Bool,
        description: String,
        iterations: Int = 10_000
    ) async throws {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for: \(description)")
        throw CancellationError()
    }

    // MARK: - Capacity

    @Test("Acquiring under capacity never waits")
    func acquireUnderCapacity() async throws {
        let factory = CountingPlayerFactory()
        let pool = PlayerPool(capacity: .bounded(3), clock: FakeClock(), makePlayer: factory.make)

        let first = try await pool.acquire()
        let second = try await pool.acquire()

        #expect(first.waitDuration == 0)
        #expect(second.waitDuration == 0)
        #expect(await pool.occupancy == 2)
        #expect(factory.count == 2)
    }

    @Test("The pool never instantiates beyond its capacity", arguments: [1, 2, 3, 4])
    func neverAllocatesBeyondCapacity(capacity: Int) async throws {
        let factory = CountingPlayerFactory()
        let pool = PlayerPool(capacity: .bounded(capacity), clock: FakeClock(), makePlayer: factory.make)

        var held: [PooledPlayer] = []
        for _ in 0..<capacity {
            held.append(try await pool.acquire())
        }

        #expect(factory.count == capacity)
        #expect(await pool.instantiationCount == capacity)
        #expect(await pool.occupancy == capacity)

        // Nothing left to hand out: the next acquire must block rather than allocate.
        let blocked = Task { try await pool.acquire() }
        try await waitUntil({ await pool.pendingAcquireCount == 1 }, description: "acquire to block")
        #expect(factory.count == capacity, "pool allocated past capacity instead of waiting")

        blocked.cancel()
        _ = try? await blocked.value
        for player in held { await pool.release(player) }
    }

    @Test("Released players are recycled rather than replaced")
    func releaseRecycles() async throws {
        let factory = CountingPlayerFactory()
        let pool = PlayerPool(capacity: .bounded(2), clock: FakeClock(), makePlayer: factory.make)

        let first = try await pool.acquire()
        let firstSerial = (first.player as? FakePlayer)?.serial
        await pool.release(first)

        let reacquired = try await pool.acquire()

        #expect((reacquired.player as? FakePlayer)?.serial == firstSerial)
        #expect(factory.count == 1, "a recycled acquire should not instantiate")
    }

    // MARK: - Exhaustion and waiting

    @Test("An acquire on an exhausted pool waits, and the wait is recorded")
    func exhaustionWaitIsMeasured() async throws {
        let clock = FakeClock()
        let pool = PlayerPool(capacity: .bounded(1), clock: clock, makePlayer: CountingPlayerFactory().make)

        let held = try await pool.acquire()
        #expect(held.waitDuration == 0)

        let waiting = Task { try await pool.acquire() }
        try await waitUntil({ await pool.pendingAcquireCount == 1 }, description: "acquire to block")

        clock.advance(by: 0.25)
        await pool.release(held)

        let result = try await waiting.value
        #expect(result.waitDuration == 0.25)
        #expect(await pool.pendingAcquireCount == 0)
    }

    @Test("Instantiating a player is not reported as waiting for one")
    func immediateAcquireReportsZeroWaitEvenWhenTimePasses() async throws {
        // Against a clock that ticks on every read, any elapsed-time computation on the
        // non-blocking path shows up as non-zero. Creating a player costs real time (~5 ms
        // measured on simulator), but that is not contention — counting it as such would
        // penalise `pool-unbounded`, the arm that instantiates on nearly every acquire and is
        // supposed to demonstrate good startup at bad memory cost.
        let pool = PlayerPool(
            capacity: .unbounded,
            clock: AdvancingClock(step: 0.05),
            makePlayer: CountingPlayerFactory().make
        )

        for _ in 0..<5 {
            let pooled = try await pool.acquire()
            #expect(pooled.waitDuration == 0, "instantiation cost must not be recorded as contention")
        }
    }

    @Test("A recycled acquire reports zero wait too")
    func recycledAcquireReportsZeroWait() async throws {
        let pool = PlayerPool(
            capacity: .bounded(1),
            clock: AdvancingClock(step: 0.05),
            makePlayer: CountingPlayerFactory().make
        )

        let first = try await pool.acquire()
        await pool.release(first)
        let second = try await pool.acquire()

        #expect(second.waitDuration == 0)
    }

    @Test("Queued acquires are served in order, and cannot be overtaken")
    func waitersAreServedFIFO() async throws {
        let pool = PlayerPool(capacity: .bounded(1), clock: FakeClock(), makePlayer: CountingPlayerFactory().make)
        let held = try await pool.acquire()

        let firstWaiter = Task { try await pool.acquire() }
        try await waitUntil({ await pool.pendingAcquireCount == 1 }, description: "first waiter to queue")
        let secondWaiter = Task { try await pool.acquire() }
        try await waitUntil({ await pool.pendingAcquireCount == 2 }, description: "second waiter to queue")

        await pool.release(held)
        let firstResult = try await firstWaiter.value
        // The second waiter is still queued; only one player exists.
        #expect(await pool.pendingAcquireCount == 1)

        await pool.release(firstResult)
        let secondResult = try await secondWaiter.value
        #expect(await pool.occupancy == 1)

        await pool.release(secondResult)
        #expect(await pool.occupancy == 0)
    }

    @Test("Cancelling a blocked acquire throws and leaves no stranded waiter")
    func cancellingBlockedAcquire() async throws {
        let pool = PlayerPool(capacity: .bounded(1), clock: FakeClock(), makePlayer: CountingPlayerFactory().make)
        let held = try await pool.acquire()

        let blocked = Task { try await pool.acquire() }
        try await waitUntil({ await pool.pendingAcquireCount == 1 }, description: "acquire to block")

        blocked.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await blocked.value
        }
        try await waitUntil({ await pool.pendingAcquireCount == 0 }, description: "waiter to be removed")

        // The pool is still usable: releasing must not resume a cancelled continuation.
        await pool.release(held)
        #expect(await pool.occupancy == 0)
        let reacquired = try await pool.acquire()
        #expect(reacquired.waitDuration == 0)
    }

    // MARK: - Teardown

    @Test("Release tears the player down before it can be handed out again")
    func releaseResetsPlayer() async throws {
        let pool = PlayerPool(capacity: .bounded(1), clock: FakeClock(), makePlayer: CountingPlayerFactory().make)

        let pooled = try await pool.acquire()
        let player = try #require(pooled.player as? FakePlayer)
        player.replaceCurrentItem(with: nil)
        player.play()
        #expect(player.resetCount == 0)

        await pool.release(pooled)

        #expect(player.resetCount == 1, "release must tear down")
        #expect(player.timeControlStatus == .paused)
        #expect(player.currentItem == nil)
        #expect(player.appliedConfigurations.last == .systemDefault, "buffer config must be restored")
    }

    @Test("Occupancy returns to zero once every player is released")
    func occupancyReturnsToZero() async throws {
        let pool = PlayerPool(capacity: .bounded(3), clock: FakeClock(), makePlayer: CountingPlayerFactory().make)

        var held: [PooledPlayer] = []
        for _ in 0..<3 { held.append(try await pool.acquire()) }
        #expect(await pool.occupancy == 3)

        for player in held { await pool.release(player) }

        #expect(await pool.occupancy == 0)
        #expect(await pool.freeCount == 3)
    }

    @Test("Draining tears down idle players without lowering capacity")
    func drainReleasesIdlePlayers() async throws {
        let factory = CountingPlayerFactory()
        let pool = PlayerPool(capacity: .bounded(2), clock: FakeClock(), makePlayer: factory.make)

        let first = try await pool.acquire()
        let second = try await pool.acquire()
        let firstPlayer = try #require(first.player as? FakePlayer)
        await pool.release(first)
        await pool.release(second)

        await pool.drain()

        #expect(await pool.freeCount == 0)
        #expect(firstPlayer.resetCount == 2, "drain tears down again on top of release")

        // Capacity is intact — drained slots can be re-created.
        _ = try await pool.acquire()
        _ = try await pool.acquire()
        #expect(factory.count == 4)
    }

    // MARK: - The negative control

    @Test("The unbounded arm allocates without bound, which is the point of it")
    func unboundedNeverWaits() async throws {
        let factory = CountingPlayerFactory()
        let pool = PlayerPool(capacity: .unbounded, clock: FakeClock(), makePlayer: factory.make)

        for _ in 0..<25 {
            let pooled = try await pool.acquire()
            #expect(pooled.waitDuration == 0)
        }

        #expect(factory.count == 25)
        #expect(await pool.occupancy == 25)
        #expect(await pool.pendingAcquireCount == 0)
    }
}

import Foundation

@testable import FeedLab

/// A player that records what was done to it.
///
/// Exists so pool behaviour — capacity, reuse, teardown — can be asserted without a real
/// player, a real stream, or a device. `@unchecked Sendable` with a lock because the pool is
/// an actor and may touch these from any executor.
final class FakePlayer: PlayerProviding, @unchecked Sendable {
    /// Distinguishes instances when asserting that a *recycled* player came back.
    let serial: Int

    private let lock = NSLock()
    private var _resetCount = 0
    private var _appliedConfigurations: [BufferConfiguration] = []
    private var _currentItem: (any PlayerItemProviding)?
    private var _timeControlStatus: PlayerTimeControlStatus = .paused
    private var _seekToStartCount = 0

    init(serial: Int) {
        self.serial = serial
    }

    var resetCount: Int { lock.withLock { _resetCount } }
    var seekToStartCount: Int { lock.withLock { _seekToStartCount } }
    var appliedConfigurations: [BufferConfiguration] { lock.withLock { _appliedConfigurations } }

    var timeControlStatus: PlayerTimeControlStatus { lock.withLock { _timeControlStatus } }
    var reasonForWaitingToPlay: PlayerWaitingReason? { nil }
    var currentItem: (any PlayerItemProviding)? { lock.withLock { _currentItem } }

    func replaceCurrentItem(with item: (any PlayerItemProviding)?) {
        lock.withLock { _currentItem = item }
    }

    func play() {
        lock.withLock { _timeControlStatus = .playing }
    }

    func pause() {
        lock.withLock { _timeControlStatus = .paused }
    }

    func seekToStart() {
        lock.withLock { _seekToStartCount += 1 }
    }

    func apply(_ configuration: BufferConfiguration) {
        lock.withLock { _appliedConfigurations.append(configuration) }
    }

    func reset() {
        lock.withLock {
            _resetCount += 1
            _currentItem = nil
            _timeControlStatus = .paused
            _appliedConfigurations.append(.systemDefault)
        }
    }
}

/// Counts how many players a pool actually instantiated.
final class CountingPlayerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func make() -> any PlayerProviding {
        lock.withLock {
            _count += 1
            return FakePlayer(serial: _count)
        }
    }
}

/// Time that advances on every read.
///
/// Exists to catch the specific bug where a non-blocking acquire reports elapsed time as
/// contention: against this clock any stray `now()` difference becomes visibly non-zero.
final class AdvancingClock: TimestampSource, @unchecked Sendable {
    private let lock = NSLock()
    private let step: TimeInterval
    private var current: TimeInterval = 0

    init(step: TimeInterval) {
        self.step = step
    }

    func now() -> TimeInterval {
        lock.withLock {
            current += step
            return current
        }
    }
}

/// Time that only moves when a test moves it, so "a 250 ms wait is recorded as 250 ms" can be
/// asserted without waiting 250 ms or depending on CI load.
final class FakeClock: TimestampSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(start: TimeInterval = 0) {
        current = start
    }

    func now() -> TimeInterval { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}

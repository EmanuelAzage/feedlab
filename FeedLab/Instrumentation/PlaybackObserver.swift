import AVFoundation
import Foundation

/// Watches one attached item and emits typed events.
///
/// AVFoundation reports through three different mechanisms on unspecified queues — KVO on the
/// player, KVO on the layer, and `NotificationCenter` on the item. This type collapses all of them
/// into one vocabulary.
///
/// **Every callback stamps its own timestamp before doing anything else.** Delivery to the recorder
/// is asynchronous, but the number is fixed by then, so scheduling latency cannot leak into a
/// metric (`docs/qoe-metrics.md`).
///
/// **Leak discipline:** `invalidate()` must be called before the player returns to the pool. A KVO
/// registration surviving onto a recycled player would attribute a later item's events to this one,
/// silently corrupting every record after it. That is the classic bug in this design, and the
/// reason teardown is spelled out in `playback-engine.md`.
final class PlaybackObserver: @unchecked Sendable {
    private let itemID: String
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let clock: any TimestampSource
    private let signposter: PlaybackSignposter
    private let emit: @Sendable (PlaybackEvent) -> Void

    /// Guards the small state machine below. A lock rather than an actor because the state has to
    /// be updated in the same synchronous callback that took the timestamp.
    private let lock = NSLock()
    private var isStalled = false
    private var hasReportedPlaybackStart = false
    private var isInvalidated = false

    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        itemID: String,
        player: AVPlayer,
        item: AVPlayerItem,
        layer: AVPlayerLayer?,
        clock: any TimestampSource,
        signposter: PlaybackSignposter = .disabled,
        emit: @escaping @Sendable (PlaybackEvent) -> Void
    ) {
        self.itemID = itemID
        self.player = player
        self.item = item
        self.clock = clock
        self.signposter = signposter
        self.emit = emit

        registerPlayerObservations()
        registerLayerObservation(layer)
        registerNotifications()
    }

    deinit {
        // Belt and braces. `invalidate()` is the contract; this catches a path that forgot.
        for observation in observations { observation.invalidate() }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Tears down every registration. Idempotent, and required before release to the pool.
    func invalidate() {
        lock.lock()
        guard !isInvalidated else { return lock.unlock() }
        isInvalidated = true
        let observations = self.observations
        let tokens = self.notificationTokens
        self.observations = []
        self.notificationTokens = []
        lock.unlock()

        for observation in observations { observation.invalidate() }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Registration

    private func registerPlayerObservations() {
        // Both properties feed one decision, and either can change without the other, so both
        // re-evaluate the same state machine rather than emitting independently.
        observations.append(
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                self?.evaluateTimeControl(at: self?.clock.now() ?? 0)
            }
        )
        observations.append(
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
                self?.evaluateTimeControl(at: self?.clock.now() ?? 0)
            }
        )
    }

    private func registerLayerObservation(_ layer: AVPlayerLayer?) {
        guard let layer else { return }
        observations.append(
            layer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self] layer, _ in
                guard let self, layer.isReadyForDisplay else { return }
                // t1 for time-to-first-frame. The signpost closes here rather than at consumption,
                // so the Points of Interest span matches the recorded interval.
                self.signposter.end(.firstFrame, itemID: self.itemID)
                self.send(.readyForDisplay, at: self.clock.now())
            }
        )
    }

    private func registerNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.newAccessLogEntryNotification,
                object: item,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let now = self.clock.now()
                guard let event = self.item.accessLog()?.events.last else { return }
                self.send(.accessLogEntry(Self.snapshot(from: event)), at: now)
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.newErrorLogEntryNotification,
                object: item,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let now = self.clock.now()
                guard let event = self.item.errorLog()?.events.last else { return }
                self.send(
                    .errorLogEntry(
                        PlaybackErrorEvent(
                            statusCode: event.errorStatusCode,
                            domain: event.errorDomain,
                            comment: event.errorComment
                        )
                    ),
                    at: now
                )
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.send(.itemEnded, at: self.clock.now())
            }
        )
    }

    // MARK: - State machine

    /// Stall detection per `docs/qoe-metrics.md`: waiting **and** waiting *to minimize stalls*.
    /// Waiting for any other reason — evaluating buffering rate, no item to play — is not a stall,
    /// and counting it would inflate rebuffer ratio with time the user did not experience as one.
    private func evaluateTimeControl(at timestamp: TimeInterval) {
        let status = player.timeControlStatus
        let reason = player.reasonForWaitingToPlay

        lock.lock()
        var toEmit: [PlaybackEvent.Kind] = []

        switch status {
        case .playing:
            if isStalled {
                isStalled = false
                toEmit.append(.stallEnded)
            }
            if !hasReportedPlaybackStart {
                hasReportedPlaybackStart = true
                toEmit.append(.playbackStarted)
            }
        case .waitingToPlayAtSpecifiedRate:
            if reason == .toMinimizeStalls, !isStalled {
                isStalled = true
                toEmit.append(.stallBegan)
            }
        case .paused:
            // A pause ends any stall in progress. Whether the pause itself was user-initiated is
            // the coordinator's knowledge, not ours — it emits `.userPaused` separately.
            if isStalled {
                isStalled = false
                toEmit.append(.stallEnded)
            }
        @unknown default:
            break
        }
        lock.unlock()

        for kind in toEmit { send(kind, at: timestamp) }
    }

    private func send(_ kind: PlaybackEvent.Kind, at timestamp: TimeInterval) {
        lock.lock()
        let invalidated = isInvalidated
        lock.unlock()
        guard !invalidated else { return }
        emit(PlaybackEvent(itemID: itemID, timestamp: timestamp, kind: kind))
    }

    // MARK: - Access log mapping

    /// AVFoundation reports `-1` for "not available". Mapped to nil so the metrics layer's
    /// "optional means not applicable, never zero" convention holds from the source — a progressive
    /// asset leaves most of these unpopulated, and zero would read as a real measurement.
    static func snapshot(from event: AVPlayerItemAccessLogEvent) -> AccessLogSnapshot {
        func present(_ value: Double) -> Double? { value >= 0 ? value : nil }
        func present(_ value: Int) -> Int? { value >= 0 ? value : nil }

        return AccessLogSnapshot(
            indicatedBitrate: present(event.indicatedBitrate),
            observedBitrate: present(event.observedBitrate),
            switchBitrate: present(event.switchBitrate),
            numberOfStalls: present(event.numberOfStalls),
            numberOfDroppedVideoFrames: present(event.numberOfDroppedVideoFrames),
            startupTime: present(event.startupTime)
        )
    }
}

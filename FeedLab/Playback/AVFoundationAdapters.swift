import AVFoundation
import Foundation

/// `AVPlayerItem` behind `PlayerItemProviding`.
///
/// `@unchecked Sendable`: `AVPlayerItem` is not `Sendable`, but the ownership discipline on
/// `PlayerProviding` means exactly one context touches an item at a time — the pool never
/// touches a checked-out player, and the item travels with it.
final class AVPlayerItemAdapter: PlayerItemProviding, @unchecked Sendable {
    let item: AVPlayerItem

    init(item: AVPlayerItem) {
        self.item = item
    }

    convenience init(asset: AVURLAsset) {
        self.init(item: AVPlayerItem(asset: asset))
    }

    var status: PlayerItemStatus {
        switch item.status {
        case .readyToPlay: .readyToPlay
        case .failed: .failed
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    var isPlaybackLikelyToKeepUp: Bool {
        item.isPlaybackLikelyToKeepUp
    }

    var bufferedDuration: TimeInterval {
        item.loadedTimeRanges.reduce(0) { total, value in
            total + CMTimeGetSeconds(value.timeRangeValue.duration)
        }
    }

    func apply(_ configuration: BufferConfiguration) {
        // AVFoundation splits these levers across two objects: forward buffer and peak bitrate
        // live on the item, stall-avoidance lives on the player. `BufferConfiguration` keeps
        // them together because they are one strategy decision.
        item.preferredForwardBufferDuration = configuration.preferredForwardBufferDuration
        item.preferredPeakBitRate = configuration.preferredPeakBitRate
    }
}

/// `AVPlayer` behind `PlayerProviding`.
///
/// `@unchecked Sendable` for the same reason as above; see the ownership discipline on
/// `PlayerProviding`.
final class AVPlayerAdapter: PlayerProviding, @unchecked Sendable {
    let player: AVPlayer

    private var attachedItem: (any PlayerItemProviding)?

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
        // The feed drives its own preload policy; leaving this on would let AVFoundation make
        // buffering decisions the experiment is trying to attribute to the arm.
        player.automaticallyWaitsToMinimizeStalling = BufferConfiguration.systemDefault
            .automaticallyWaitsToMinimizeStalling
    }

    var timeControlStatus: PlayerTimeControlStatus {
        switch player.timeControlStatus {
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waitingToPlayAtSpecifiedRate
        case .playing: .playing
        @unknown default: .paused
        }
    }

    var reasonForWaitingToPlay: PlayerWaitingReason? {
        guard let reason = player.reasonForWaitingToPlay else { return nil }
        switch reason {
        case .toMinimizeStalls: return .toMinimizeStalls
        case .evaluatingBufferingRate: return .evaluatingBufferingRate
        case .noItemToPlay: return .noItemToPlay
        default: return .other(reason.rawValue)
        }
    }

    var currentItem: (any PlayerItemProviding)? {
        attachedItem
    }

    func replaceCurrentItem(with item: (any PlayerItemProviding)?) {
        attachedItem = item
        player.replaceCurrentItem(with: (item as? AVPlayerItemAdapter)?.item)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func apply(_ configuration: BufferConfiguration) {
        player.automaticallyWaitsToMinimizeStalling = configuration.automaticallyWaitsToMinimizeStalling
        attachedItem?.apply(configuration)
    }

    func reset() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        attachedItem = nil
        apply(.systemDefault)
    }
}

#if FEEDLAB_TOOLS
import SwiftUI
import UIKit

/// Drives the HUD by **sampling** state at a fixed rate.
///
/// The decision that matters (`docs/observability.md`): the HUD pulls a snapshot on a 4 Hz timer
/// rather than subscribing to the event stream and throttling it. Pull decouples HUD cost from
/// event *rate* entirely — under a stall storm, precisely when the HUD is most interesting, a
/// throttled push would still pay per-event delivery cost before discarding most of it. Sampling
/// costs the same whether one event arrived or a thousand.
///
/// M4's acceptance criterion is that enabling the HUD does not measurably change TTFF. This design
/// is the reason that has a chance of holding.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private weak var coordinator: FeedCoordinator?
    private weak var host: UIView?

    private var hostingController: UIHostingController<HUDContainer>?
    private var timer: Timer?

    /// 4 Hz. Fast enough to read as live, slow enough that rendering is not a load source.
    private static let interval: TimeInterval = 0.25

    init(coordinator: FeedCoordinator, host: UIView) {
        self.coordinator = coordinator
        self.host = host
    }

    var isVisible: Bool { hostingController != nil }

    func show() {
        guard hostingController == nil, let host else { return }

        let controller = UIHostingController(rootView: HUDContainer(model: model))
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)

        NSLayoutConstraint.activate([
            // Top-left, clear of the centre of the frame and of the debug button top-right.
            controller.view.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            controller.view.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 12)
        ])
        hostingController = controller

        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // The feed is scrolling most of the time; without this the HUD freezes during a drag, which
        // would hide the numbers exactly when they are changing fastest.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        hostingController?.view.removeFromSuperview()
        hostingController = nil
    }

    // MARK: - Sampling

    private func sample() {
        guard let coordinator else { return }
        let item = coordinator.currentItem

        Task { [weak self] in
            let recorder = coordinator.recorder
            let pool = coordinator.pool
            let tracker = coordinator.memoryTracker

            let arm = await recorder.arm
            var inFlight: PlaybackRecord?
            if let item {
                inFlight = await recorder.inFlightRecord(for: item.id)
            }
            let summary = await recorder.summary()
            let occupancy = await pool.occupancy
            let pending = await pool.pendingAcquireCount
            let peak = await tracker.peakBytes
            let samples = await tracker.sampleCount

            var snapshot = HUDSnapshot()
            snapshot.arm = arm
            snapshot.itemTitle = item?.title ?? "—"
            snapshot.current = inFlight
            snapshot.itemsViewed = summary.records.count
            snapshot.skippedCount = summary.skippedCount
            snapshot.meanTimeToFirstFrame = summary.meanTimeToFirstFrame
            snapshot.p90TimeToFirstFrame = summary.p90TimeToFirstFrame
            snapshot.aggregateRebufferRatio = summary.aggregateRebufferRatio
            snapshot.poolOccupancy = occupancy
            snapshot.poolPending = pending
            snapshot.poolCapacity = Self.describe(pool.capacity)
            snapshot.peakMemoryBytes = peak
            snapshot.memorySampleCount = samples

            self?.model.snapshot = snapshot
        }
    }

    private static func describe(_ capacity: PoolCapacity) -> String {
        switch capacity {
        case .bounded(let limit): "\(limit)"
        case .unbounded: "∞"
        }
    }
}

/// Bridges the observable model into the view, so SwiftUI re-renders on each sampled snapshot.
struct HUDContainer: View {
    @Bindable var model: HUDModel

    var body: some View {
        HUDView(snapshot: model.snapshot)
    }
}
#endif

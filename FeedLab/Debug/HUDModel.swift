#if FEEDLAB_TOOLS
import Foundation
import Observation

/// Everything the HUD renders, gathered in one sample.
///
/// A value type so a tick is atomic: the HUD never shows a session aggregate from one moment beside
/// a current-item figure from another, which would be a confusing thing to photograph and put in a
/// README.
struct HUDSnapshot: Equatable, Sendable {
    var arm: String = "—"
    var itemTitle: String = "—"

    var current: PlaybackRecord?

    var itemsViewed: Int = 0
    var skippedCount: Int = 0
    var meanTimeToFirstFrame: TimeInterval?
    var p90TimeToFirstFrame: TimeInterval?
    var aggregateRebufferRatio: Double = 0

    var poolOccupancy: Int = 0
    var poolCapacity: String = "—"
    var poolPending: Int = 0

    var peakMemoryBytes: UInt64 = 0
    var memorySampleCount: Int = 0
}

@MainActor
@Observable
final class HUDModel {
    var snapshot = HUDSnapshot()
}
#endif

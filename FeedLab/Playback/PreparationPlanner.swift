import Foundation

/// A strategy's intent, resolved against what the pool can actually supply.
struct PreparationPlan: Equatable, Sendable {
    /// Items that get a pooled player and therefore genuinely buffer. Priority order; never more
    /// than the pool's capacity.
    let playerBacked: [Int]
    /// Items whose asset is loaded but which hold no player — so no buffering. The overflow.
    let warmOnly: [Int]

    var allPrepared: [Int] { playerBacked + warmOnly }
}

/// Arbitrates between what a strategy wants and what the pool has.
///
/// Exists so neither side has to know about the other: `PreloadStrategy` stays pure and
/// capacity-unaware (which is what keeps its index math testable), and `PlayerPool` stays ignorant
/// of preload policy. Both properties are load-bearing.
///
/// The rule it enforces comes from a measured fact: an `AVPlayerItem` does not buffer until a player
/// adopts it (verified M2), so *real* preload costs a pool slot. Items beyond capacity fall back to
/// a playerless warm rather than being dropped, so an under-provisioned arm degrades measurably
/// instead of silently.
enum PreparationPlanner {
    static func plan(
        currentIndex: Int,
        totalCount: Int,
        strategy: any PreloadStrategy,
        capacity: PoolCapacity
    ) -> PreparationPlan {
        let desired = strategy.itemsToPrepare(currentIndex: currentIndex, totalCount: totalCount)
        guard !desired.isEmpty else {
            return PreparationPlan(playerBacked: [], warmOnly: [])
        }

        let prioritised = prioritise(desired, around: currentIndex)

        switch capacity {
        case .unbounded:
            // The negative control allocates freely; that is the entire point of it.
            return PreparationPlan(playerBacked: prioritised, warmOnly: [])
        case .bounded(let limit):
            guard limit > 0 else {
                return PreparationPlan(playerBacked: [], warmOnly: prioritised)
            }
            let backed = Array(prioritised.prefix(limit))
            let warm = Array(prioritised.dropFirst(limit))
            return PreparationPlan(playerBacked: backed, warmOnly: warm)
        }
    }

    /// Current item first, then by ascending distance, forward before backward on a tie.
    ///
    /// The tie-break is not cosmetic. When capacity forces a cut, it decides whether the next item
    /// or the previous one keeps its player — and in a feed the user is far more likely to go
    /// forward, so a backward item winning a slot would spend the pool on the less probable case.
    static func prioritise(_ indices: [Int], around currentIndex: Int) -> [Int] {
        indices.enumerated().sorted { lhs, rhs in
            let lhsOffset = lhs.element - currentIndex
            let rhsOffset = rhs.element - currentIndex
            if abs(lhsOffset) != abs(rhsOffset) {
                return abs(lhsOffset) < abs(rhsOffset)
            }
            if lhsOffset != rhsOffset {
                return lhsOffset > rhsOffset   // +1 before −1
            }
            return lhs.offset < rhs.offset     // stable
        }
        .map(\.element)
    }
}

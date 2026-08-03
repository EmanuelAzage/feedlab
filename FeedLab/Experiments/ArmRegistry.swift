import Foundation

/// One experimental condition: a strategy, a pool size, and the hypothesis being tested.
struct Arm: Identifiable, Sendable {
    /// Stable identifier. Appears in every `PlaybackRecord` and on every HUD screenshot, which is
    /// what makes a screenshot self-documenting.
    let name: String
    let strategy: any PreloadStrategy
    let poolCapacity: PoolCapacity
    /// The hypothesis, in one sentence. Recorded so an arm that loses is still legible — a rig that
    /// only remembers why the winner was tried proves nothing.
    let hypothesis: String

    var id: String { name }
}

/// The set under test, declared in one file so it is legible at a glance
/// (`docs/experiment-harness.md`).
enum ArmRegistry {
    static let all: [Arm] = [
        Arm(
            name: "baseline",
            strategy: NoPreload(),
            poolCapacity: .bounded(3),
            hypothesis: "Control. Establishes worst-case startup and lowest memory."
        ),
        Arm(
            name: "preload1",
            strategy: PreloadNext1(),
            poolCapacity: .bounded(3),
            hypothesis: "One-ahead preparation should cut startup substantially on forward scroll for modest cost."
        ),
        Arm(
            name: "preload3-capped",
            strategy: PreloadNext3Capped(),
            poolCapacity: .bounded(4),
            hypothesis: "Depth helps fast scrollers; capped buffers and bitrate should contain the cost."
        ),
        Arm(
            name: "window",
            strategy: PreloadWindow(),
            poolCapacity: .bounded(4),
            hypothesis: "Preparing backward too should help back-scroll startup; costs a slot."
        ),
        Arm(
            name: "pool-unbounded",
            strategy: PreloadNext1(),
            poolCapacity: .unbounded,
            hypothesis: """
            Deliberate negative control — should look fine on startup and bad on memory \
            and dropped frames.
            """
        )
    ]

    /// The control. Also what the engine did before arms existed, so the baseline is the absence of
    /// a strategy rather than a special case built to lose.
    static let control: Arm = all[0]

    static func arm(named name: String) -> Arm? {
        all.first { $0.name == name }
    }

    /// Every arm satisfies `poolCapacity ≥ |itemsToPrepare|`, so each strategy can actually achieve
    /// player-backed preparation for its whole set rather than silently degrading to warm-only.
    /// Asserted by a unit test rather than trusted — the rule was derived from a measurement and is
    /// easy to break by editing one number here.
    static func capacityCoversPreparedSet(_ arm: Arm, totalCount: Int = 100) -> Bool {
        guard case .bounded(let limit) = arm.poolCapacity else { return true }
        // Mid-manifest, where the prepared set is at its largest.
        let desired = arm.strategy.itemsToPrepare(currentIndex: totalCount / 2, totalCount: totalCount)
        return desired.count <= limit
    }
}

import Foundation
import Testing

@testable import FeedLab

@Suite("Preparation planner — strategy against capacity")
struct PreparationPlannerTests {
    @Test("Under capacity, every desired item is player-backed")
    func underCapacityAllBacked() {
        let plan = PreparationPlanner.plan(
            currentIndex: 10,
            totalCount: 22,
            strategy: PreloadNext1(),
            capacity: .bounded(3)
        )

        #expect(plan.playerBacked == [10, 11])
        #expect(plan.warmOnly.isEmpty)
    }

    @Test("Over capacity, the overflow degrades to warm-only rather than being dropped")
    func overCapacityDegradesGracefully() {
        // A deliberately under-provisioned arm: four wanted, two available.
        let plan = PreparationPlanner.plan(
            currentIndex: 10,
            totalCount: 22,
            strategy: PreloadNext3Capped(),
            capacity: .bounded(2)
        )

        #expect(plan.playerBacked == [10, 11], "the current item and its nearest neighbour keep players")
        #expect(plan.warmOnly == [12, 13], "the rest still load their assets — the arm degrades measurably")
        #expect(plan.allPrepared.count == 4, "nothing is silently dropped")
    }

    @Test("The current item always keeps a player, even at capacity 1")
    func currentItemAlwaysBacked() {
        let plan = PreparationPlanner.plan(
            currentIndex: 10,
            totalCount: 22,
            strategy: PreloadWindow(),
            capacity: .bounded(1)
        )

        #expect(plan.playerBacked == [10])
        // Losing the current item's player would mean the thing the user is looking at does not play.
        #expect(plan.warmOnly == [11, 9, 12])
    }

    @Test("Forward wins over backward when capacity forces a cut")
    func forwardBeatsBackwardOnTie() {
        // Both are one step away. Forward scroll dominates a feed, so spending the last slot
        // backwards would buy the less likely case.
        let plan = PreparationPlanner.plan(
            currentIndex: 10,
            totalCount: 22,
            strategy: PreloadWindow(),
            capacity: .bounded(2)
        )

        #expect(plan.playerBacked == [10, 11])
        #expect(plan.warmOnly.first == 9)
    }

    @Test("Priority is by distance from current, nearest first")
    func priorityIsByDistance() {
        #expect(PreparationPlanner.prioritise([13, 9, 10, 11], around: 10) == [10, 11, 9, 13])
    }

    @Test("The unbounded control backs everything, which is the point of it")
    func unboundedBacksEverything() {
        let plan = PreparationPlanner.plan(
            currentIndex: 10,
            totalCount: 22,
            strategy: PreloadNext3Capped(),
            capacity: .unbounded
        )

        #expect(plan.playerBacked == [10, 11, 12, 13])
        #expect(plan.warmOnly.isEmpty)
    }

    @Test("A zero-capacity pool backs nothing but still warms")
    func zeroCapacity() {
        let plan = PreparationPlanner.plan(
            currentIndex: 5,
            totalCount: 22,
            strategy: PreloadNext1(),
            capacity: .bounded(0)
        )

        #expect(plan.playerBacked.isEmpty)
        #expect(plan.warmOnly == [5, 6])
    }

    @Test("An empty manifest plans nothing")
    func emptyManifest() {
        let plan = PreparationPlanner.plan(
            currentIndex: 0,
            totalCount: 0,
            strategy: PreloadNext1(),
            capacity: .bounded(3)
        )

        #expect(plan.playerBacked.isEmpty)
        #expect(plan.warmOnly.isEmpty)
    }
}

@Suite("Arm registry")
struct ArmRegistryTests {
    @Test("Every declared arm has capacity for its own prepared set")
    func everyArmIsSelfConsistent() {
        // The rule comes from a measurement: an AVPlayerItem does not buffer without a player, so
        // poolCapacity >= |itemsToPrepare| or the arm silently degrades to warm-only and stops
        // testing what its name claims. Easy to break by editing one number in the registry.
        for arm in ArmRegistry.all {
            #expect(
                ArmRegistry.capacityCoversPreparedSet(arm),
                "\(arm.name) cannot back its own prepared set"
            )
        }
    }

    @Test("Arm names are unique, since records are keyed by them")
    func armNamesAreUnique() {
        let names = ArmRegistry.all.map(\.name)
        #expect(names.count == Set(names).count)
    }

    @Test("The control arm is the absence of a strategy, not a special case built to lose")
    func controlIsNoPreload() {
        #expect(ArmRegistry.control.name == "baseline")
        #expect(ArmRegistry.control.strategy.name == NoPreload().name)
    }

    @Test("The negative control is the only unbounded arm")
    func onlyOneUnboundedArm() {
        let unbounded = ArmRegistry.all.filter {
            if case .unbounded = $0.poolCapacity { return true }
            return false
        }

        #expect(unbounded.count == 1)
        #expect(unbounded.first?.name == "pool-unbounded")
    }

    @Test("Lookup by name finds declared arms and rejects unknown ones")
    func lookupByName() {
        #expect(ArmRegistry.arm(named: "preload1")?.strategy.name == PreloadNext1().name)
        #expect(ArmRegistry.arm(named: "nonexistent") == nil)
    }

    @Test("Every arm states a hypothesis, so a losing arm is still legible")
    func everyArmStatesAHypothesis() {
        for arm in ArmRegistry.all {
            #expect(!arm.hypothesis.isEmpty, "\(arm.name) has no stated hypothesis")
        }
    }
}

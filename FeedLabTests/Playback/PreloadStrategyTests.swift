import Foundation
import Testing

@testable import FeedLab

@Suite("Preload strategies — index math")
struct PreloadStrategyTests {
    // MARK: - Exact prepared sets

    @Test(
        "Each strategy prepares exactly its documented set, mid-manifest",
        arguments: [
            ("none", [10]),
            ("next-1", [10, 11]),
            ("next-3-capped", [10, 11, 12, 13]),
            ("window", [10, 11, 9, 12])
        ]
    )
    func exactPreparedSet(name: String, expected: [Int]) throws {
        let strategy = try #require(Self.strategy(named: name))

        #expect(strategy.itemsToPrepare(currentIndex: 10, totalCount: 22) == expected)
    }

    @Test("Priority order puts the current item first, forward before backward")
    func windowOrdersByPriorityNotPosition() {
        // Positional order would be [9, 10, 11, 12]. Priority order matters because it decides
        // which item keeps a player when capacity forces a cut.
        #expect(PreloadWindow().itemsToPrepare(currentIndex: 10, totalCount: 22) == [10, 11, 9, 12])
    }

    // MARK: - Boundaries

    @Test(
        "At the first item, nothing is prepared before it — feeds do not wrap",
        arguments: ["none", "next-1", "next-3-capped", "window"]
    )
    func startBoundary(name: String) throws {
        let strategy = try #require(Self.strategy(named: name))

        let prepared = strategy.itemsToPrepare(currentIndex: 0, totalCount: 22)

        #expect(prepared.first == 0)
        #expect(prepared.allSatisfy { $0 >= 0 }, "wrapping would fetch items the user is not about to see")
    }

    @Test(
        "At the last item, nothing is prepared past the end",
        arguments: ["none", "next-1", "next-3-capped", "window"]
    )
    func endBoundary(name: String) throws {
        let strategy = try #require(Self.strategy(named: name))

        let prepared = strategy.itemsToPrepare(currentIndex: 21, totalCount: 22)

        #expect(prepared.first == 21)
        #expect(prepared.allSatisfy { $0 < 22 })
    }

    @Test("Near the end the prepared set shrinks rather than clamping onto duplicates")
    func nearEndShrinks() {
        #expect(PreloadNext3Capped().itemsToPrepare(currentIndex: 20, totalCount: 22) == [20, 21])
        #expect(PreloadWindow().itemsToPrepare(currentIndex: 21, totalCount: 22) == [21, 20])
    }

    @Test(
        "A single-item manifest prepares only that item",
        arguments: ["none", "next-1", "next-3-capped", "window"]
    )
    func singleItemManifest(name: String) throws {
        let strategy = try #require(Self.strategy(named: name))

        #expect(strategy.itemsToPrepare(currentIndex: 0, totalCount: 1) == [0])
    }

    @Test(
        "An empty manifest prepares nothing rather than crashing",
        arguments: ["none", "next-1", "next-3-capped", "window"]
    )
    func emptyManifest(name: String) throws {
        let strategy = try #require(Self.strategy(named: name))

        #expect(strategy.itemsToPrepare(currentIndex: 0, totalCount: 0).isEmpty)
    }

    @Test(
        "An out-of-range current index yields nothing rather than a negative or overflowing index",
        arguments: [-5, -1, 22, 99]
    )
    func outOfRangeCurrentIndex(currentIndex: Int) {
        // Reachable transiently: the feed can settle on an index while the manifest is being
        // replaced. Producing garbage indices here would fetch the wrong media.
        let prepared = PreloadWindow().itemsToPrepare(currentIndex: currentIndex, totalCount: 22)

        #expect(prepared.allSatisfy { (0..<22).contains($0) })
        #expect(!prepared.contains(currentIndex) || (0..<22).contains(currentIndex))
    }

    @Test("Prepared sets never contain duplicates")
    func noDuplicates() {
        for currentIndex in -2...4 {
            let prepared = PreloadNext3Capped().itemsToPrepare(currentIndex: currentIndex, totalCount: 3)
            #expect(prepared.count == Set(prepared).count, "duplicate at currentIndex \(currentIndex)")
        }
    }

    // MARK: - Buffer configuration

    @Test("The capped strategy leaves the current item on system defaults")
    func cappedLeavesCurrentAlone() {
        #expect(PreloadNext3Capped().bufferConfiguration(for: 0) == .systemDefault)
    }

    @Test("The capped strategy caps only the non-current items", arguments: [1, 2, 3])
    func cappedLimitsNonCurrent(offset: Int) {
        let configuration = PreloadNext3Capped().bufferConfiguration(for: offset)

        #expect(configuration.preferredForwardBufferDuration == PreloadTuning.cappedForwardBuffer)
        #expect(configuration.preferredPeakBitRate == PreloadTuning.nonCurrentPeakBitRate)
    }

    @Test("The forward-buffer cap is at least one segment, or it does nothing at all")
    func capIsAtLeastOneSegment() {
        // Measured in M2: `preferredForwardBufferDuration` cannot go below one segment, and the
        // corpus uses ~10 s segments. A smaller value would make the capped arm indistinguishable
        // from an uncapped one while still being labelled "capped" — an arm that silently tests
        // preload depth alone.
        #expect(PreloadTuning.cappedForwardBuffer >= 10)
    }

    @Test("Uncapped strategies leave buffer configuration at system defaults", arguments: [-1, 0, 1, 2])
    func uncappedStrategiesUseDefaults(offset: Int) {
        #expect(NoPreload().bufferConfiguration(for: offset) == .systemDefault)
        #expect(PreloadNext1().bufferConfiguration(for: offset) == .systemDefault)
        #expect(PreloadWindow().bufferConfiguration(for: offset) == .systemDefault)
    }

    // MARK: - Helpers

    private static func strategy(named name: String) -> (any PreloadStrategy)? {
        [NoPreload(), PreloadNext1(), PreloadNext3Capped(), PreloadWindow()]
            .first { $0.name == name }
    }
}

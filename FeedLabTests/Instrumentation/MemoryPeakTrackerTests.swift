import Foundation
import Testing

@testable import FeedLab

/// Replays a scripted sequence of footprints so peak tracking can be asserted without depending on
/// what the test host happens to be using at the time.
private final class ScriptedSampler: MemorySampling, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    func footprintBytes() -> UInt64 {
        lock.withLock {
            guard index < values.count else { return values.last ?? 0 }
            defer { index += 1 }
            return values[index]
        }
    }
}

@Suite("Memory peak tracking")
struct MemoryPeakTrackerTests {
    @Test("Peak is the maximum seen, not the most recent")
    func peakIsMaximum() async {
        let tracker = MemoryPeakTracker(sampler: ScriptedSampler([100, 400, 250, 180]))

        for _ in 0..<4 { await tracker.sample() }

        #expect(await tracker.peakBytes == 400)
        #expect(await tracker.latestBytes == 180, "latest tracks the last sample independently")
    }

    @Test("Reset clears the peak so one arm's cost is not attributed to another")
    func resetClearsPeak() async {
        let tracker = MemoryPeakTracker(sampler: ScriptedSampler([500, 100]))

        await tracker.sample()
        #expect(await tracker.peakBytes == 500)

        await tracker.reset()
        #expect(await tracker.peakBytes == 0)
        #expect(await tracker.sampleCount == 0)

        await tracker.sample()
        #expect(await tracker.peakBytes == 100, "a new session starts from its own samples")
    }

    @Test("A failed sample reads as zero and cannot lower an established peak")
    func failedSampleDoesNotLowerPeak() async {
        let tracker = MemoryPeakTracker(sampler: ScriptedSampler([300, 0]))

        await tracker.sample()
        await tracker.sample()

        #expect(await tracker.peakBytes == 300)
    }

    @Test("Sample count is exposed so a reported peak can be qualified by how often it was sampled")
    func sampleCountIsTracked() async {
        let tracker = MemoryPeakTracker(sampler: ScriptedSampler([10, 20, 30]))

        for _ in 0..<3 { await tracker.sample() }

        // The count matters because the figure is a peak *observed*, not a true peak: a spike
        // between samples is invisible, so the sampling density qualifies the claim.
        #expect(await tracker.sampleCount == 3)
    }

    @Test("The real sampler returns a plausible non-zero footprint")
    func physFootprintSamplerWorks() {
        let bytes = PhysFootprintSampler().footprintBytes()

        // Not asserting a range — that would be asserting something about the test host rather than
        // about our code. Only that the mach call succeeded and returned something usable.
        #expect(bytes > 0, "task_info(TASK_VM_INFO) returned no footprint")
    }
}

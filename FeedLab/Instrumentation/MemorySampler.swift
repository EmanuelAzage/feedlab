import Foundation

/// Reads the process's current memory footprint.
///
/// Protocol-wrapped so the peak tracker can be tested against scripted values instead of whatever
/// the test host happens to be using.
protocol MemorySampling: Sendable {
    /// Bytes. `0` if the sample could not be taken.
    func footprintBytes() -> UInt64
}

/// `phys_footprint` from `task_vm_info`.
///
/// Chosen over `resident_size` deliberately, even though `qoe-metrics.md` originally said "resident
/// size". `phys_footprint` is what Instruments shows in its Memory column and what jetsam uses to
/// decide which app to kill — so it is both the number a reader will recognise and the number that
/// actually constrains the app. `resident_size` counts shared and file-backed pages the process did
/// not really cost the system, which would flatter or inflate depending on what else is running.
struct PhysFootprintSampler: MemorySampling {
    func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

/// Tracks the highest footprint seen across a session.
///
/// **This reports the peak *observed*, not the true peak**, and the distinction is not pedantic: a
/// transient spike between two samples is invisible. Sampling faster narrows the window but never
/// closes it, so the figure is a lower bound on true peak. `observability.md` and the README must
/// say "peak observed at N Hz" rather than "peak", or the number claims a precision it does not
/// have.
///
/// Sampling runs whether or not the HUD is visible, because peak memory is a session metric that
/// must not depend on whether someone was looking at it.
actor MemoryPeakTracker {
    /// 5 Hz. `task_info` costs microseconds, so this is chosen to narrow the miss window rather
    /// than to save work — the HUD's 4 Hz budget is about *rendering*, which this does not do.
    static let sampleInterval: Duration = .milliseconds(200)

    private let sampler: any MemorySampling
    private(set) var peakBytes: UInt64 = 0
    private(set) var latestBytes: UInt64 = 0
    private(set) var sampleCount: Int = 0

    init(sampler: any MemorySampling = PhysFootprintSampler()) {
        self.sampler = sampler
    }

    @discardableResult
    func sample() -> UInt64 {
        let bytes = sampler.footprintBytes()
        latestBytes = bytes
        sampleCount += 1
        peakBytes = max(peakBytes, bytes)
        return bytes
    }

    /// Selecting an arm resets the session, and peak memory is attributed to the arm — carrying a
    /// previous arm's peak forward would attribute one arm's cost to another.
    func reset() {
        peakBytes = 0
        latestBytes = 0
        sampleCount = 0
    }
}

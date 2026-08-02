import Foundation

/// Monotonic time source for measurement.
///
/// Injected rather than read inline so pool waits and metric intervals can be exercised
/// against synthetic time — a test for "waiting 250 ms is recorded as 250 ms" should not
/// take 250 ms, and should not be flaky when CI is loaded.
///
/// Monotonic, never wall clock: `Date` can step backwards when NTP corrects the clock
/// mid-session, which would produce negative intervals. See the measurement-discipline
/// section of `docs/qoe-metrics.md`.
protocol TimestampSource: Sendable {
    /// Seconds since an arbitrary fixed origin. Never decreases.
    func now() -> TimeInterval
}

/// Backed by `mach_absolute_time` (via `DispatchTime.uptimeNanoseconds`).
struct MonotonicTimestampSource: TimestampSource {
    func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

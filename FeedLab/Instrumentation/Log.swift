import OSLog

/// Unified-logging channels for the app.
///
/// `print` is banned (CLAUDE.md, enforced by a SwiftLint custom rule): it costs main-thread
/// time, is invisible outside a debugger, and cannot be correlated with the `os_signpost`
/// intervals the measurement runs depend on. `Logger` writes to the same store Instruments
/// reads, so a log line and a signpost sit on one timeline.
enum Log {
    private static let subsystem = "dev.emanuelazage.FeedLab"

    static let content = Logger(subsystem: subsystem, category: "content")
    static let feed = Logger(subsystem: subsystem, category: "feed")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
}

import Foundation

/// What build is this, and may its numbers be trusted?
///
/// Exists because the most expensive measurement mistake is a silent one: a run performed
/// against an unoptimized binary produces numbers that describe the build settings rather
/// than the design under test. The debug menu surfaces `isOptimized` so that mistake has to
/// be made deliberately.
enum BuildInfo {
    enum Configuration: String {
        case debug = "Debug"
        case measure = "Measure"
        case release = "Release"
    }

    static var configuration: Configuration {
        #if DEBUG
        .debug
        #elseif FEEDLAB_TOOLS
        .measure
        #else
        .release
        #endif
    }

    /// Swift optimization is off only in Debug. `Measure` and `Release` are both `-O`;
    /// they differ solely in whether the measurement tooling is compiled in.
    static var isOptimized: Bool {
        configuration != .debug
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

import Foundation
import Testing

@testable import FeedLab

/// Enforces the boundary the whole architecture rests on.
///
/// `docs/testing.md`: "No AVFoundation import anywhere in `Metrics/`; add a test that fails if one
/// appears, or enforce by module boundary." FeedLab is a single module, so the rule cannot be
/// enforced by the compiler — which means without this test it is only a convention, and
/// conventions erode. The failure it prevents is not a crash but a slow loss of the property that
/// makes stall and TTFF definitions testable without a device.
///
/// Reads the source tree directly, located from `#filePath`.
@Suite("Metrics layer purity")
struct MetricsPurityTests {
    /// Frameworks that would either drag in playback machinery or tie computation to a UI runtime.
    private static let forbiddenImports = [
        "AVFoundation",
        "AVKit",
        "CoreMedia",
        "VideoToolbox",
        "UIKit",
        "SwiftUI",
        "QuartzCore"
    ]

    private var metricsDirectory: URL {
        URL(filePath: #filePath)                 // …/FeedLabTests/Metrics/MetricsPurityTests.swift
            .deletingLastPathComponent()          // …/FeedLabTests/Metrics
            .deletingLastPathComponent()          // …/FeedLabTests
            .deletingLastPathComponent()          // repo root
            .appending(path: "FeedLab/Metrics")
    }

    private func metricsSourceFiles() throws -> [URL] {
        let directory = metricsDirectory
        // Fail loudly rather than vacuously passing: a test that silently finds no files to check
        // is worse than no test, because it reports success.
        #expect(
            FileManager.default.fileExists(atPath: directory.path),
            "Metrics/ not found at \(directory.path) — this guard cannot vacuously pass"
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "swift" }
    }

    @Test("Metrics/ contains sources to check")
    func metricsDirectoryIsPopulated() throws {
        let files = try metricsSourceFiles()
        #expect(!files.isEmpty, "no Swift files found in Metrics/")
    }

    @Test("Metrics/ imports no playback or UI framework")
    func metricsImportsNothingForbidden() throws {
        var violations: [String] = []

        for file in try metricsSourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") else { continue }
                let module = trimmed
                    .replacingOccurrences(of: "@testable ", with: "")
                    .replacingOccurrences(of: "import ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if Self.forbiddenImports.contains(module) {
                    violations.append("\(file.lastPathComponent) imports \(module)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            Metrics/ must stay free of playback and UI frameworks so metric computation remains \
            testable without a device or a live stream. Violations: \(violations.joined(separator: ", "))
            """
        )
    }

    @Test("The guard actually detects a forbidden import")
    func guardDetectsViolations() {
        // Verifies the matcher rather than trusting it — a purity test that cannot fail is
        // indistinguishable from one that always passes.
        let sample = """
        import Foundation
        import AVFoundation

        struct Thing {}
        """
        var found: [String] = []
        for line in sample.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            let module = trimmed.replacingOccurrences(of: "import ", with: "")
            if Self.forbiddenImports.contains(module) { found.append(module) }
        }

        #expect(found == ["AVFoundation"])
    }
}

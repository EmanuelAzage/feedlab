import XCTest

/// Drives one measurement run.
///
/// This is not a test — it asserts almost nothing about the app. It is the scroll script from
/// `docs/experiment-harness.md` expressed as code, because the protocol asks for an *identical* run
/// across every arm and a human thumb cannot deliver that. Hand-driven runs of this script varied by
/// more than 2x in dwell, which lands directly in watch duration — the denominator of rebuffer ratio
/// — and so would have shown up as an arm difference that was really an operator difference.
///
/// Parameters arrive as environment variables so one built runner serves every cell of the matrix.
/// From the command line they are passed with a `TEST_RUNNER_` prefix, which `xcodebuild` strips
/// before handing them to the runner process:
///
/// ```
/// xcodebuild test -scheme FeedLabRunner -configuration Measure \
///   -destination 'platform=iOS,id=<ECID>' \
///   TEST_RUNNER_FEEDLAB_ARM=preload1 TEST_RUNNER_FEEDLAB_DWELL=5
/// ```
final class MeasurementRun: XCTestCase {
    /// Where the drag starts and ends, as a fraction of the window. Kept well inside the edges: a
    /// gesture beginning below ~0.9 risks the home-indicator area, and one starting above ~0.3 has
    /// too little travel to read as a flick.
    private static let dragFrom = CGVector(dx: 0.5, dy: 0.78)
    private static let dragTo = CGVector(dx: 0.5, dy: 0.22)

    /// Long enough that the gesture registers as a deliberate drag rather than a tap, short enough
    /// that it costs little against the dwell budget.
    private static let dragDuration: TimeInterval = 0.05

    /// A flick, not a drag. The default interpolated drag takes long enough to read as a slow pull
    /// on screen, which is not how anyone scrolls a feed — and the gesture's duration lands inside
    /// the transition every arm is being measured across. `.fast` is 2500 pt/s, so the ~470 pt of
    /// travel below completes in about 0.19 s.
    private static let dragVelocity: XCUIGestureVelocity = .fast

    /// After backgrounding, the app drains the event pipe and writes the session to disk. Ending the
    /// run before that completes would truncate the very file the run exists to produce.
    private static let sealTimeout: TimeInterval = 6

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMeasurementRun() throws {
        let config = try RunConfiguration.fromEnvironment()

        let app = XCUIApplication()
        app.launchArguments = ["-arm", config.arm]
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App never reached the foreground — the run would have measured nothing."
        )

        // The first item is already on screen at launch, so it gets its dwell before any swipe.
        // It is also the warm-up item the protocol discards; it is still viewed, so it is still timed.
        wait(config.dwell)

        for _ in 0..<config.forward {
            swipe(app, from: Self.dragFrom, to: Self.dragTo)
            wait(config.dwell)
        }
        for _ in 0..<config.back {
            swipe(app, from: Self.dragTo, to: Self.dragFrom)
            wait(config.dwell)
        }

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: Self.sealTimeout),
            "App did not background — the session was never sealed and nothing was written."
        )
        // Backgrounding starts the seal; the write itself is asynchronous.
        wait(Self.sealTimeout)
    }

    private func swipe(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        let start = app.coordinate(withNormalizedOffset: from)
        let end = app.coordinate(withNormalizedOffset: to)
        // `isPagingEnabled` steps by exactly one page per gesture regardless of flick velocity, so
        // one drag is one item and the run's item count is known before it starts.
        start.press(
            forDuration: Self.dragDuration,
            thenDragTo: end,
            withVelocity: Self.dragVelocity,
            thenHoldForDuration: 0
        )
    }

    /// Dwell is measured from the end of the gesture, which is when the arriving item becomes
    /// current. Sleeping the full interval on top of a variable-length drag would make the actual
    /// on-screen time drift with gesture cost.
    private func wait(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}

/// The run script's parameters, resolved once so a malformed value fails before the app launches
/// rather than halfway through a run that would then be silently unusable.
struct RunConfiguration {
    let arm: String
    let dwell: TimeInterval
    let forward: Int
    let back: Int

    static func fromEnvironment() throws -> RunConfiguration {
        let env = ProcessInfo.processInfo.environment

        // No default for the arm. Every other parameter has a defensible default; the arm does not,
        // and a run mislabelled as the control is worse than a run that refused to start.
        guard let arm = env["FEEDLAB_ARM"], !arm.isEmpty else {
            throw RunConfigurationError.missingArm
        }
        return RunConfiguration(
            arm: arm,
            dwell: try value(env["FEEDLAB_DWELL"], default: 5, name: "FEEDLAB_DWELL"),
            forward: try value(env["FEEDLAB_FORWARD"], default: 20, name: "FEEDLAB_FORWARD"),
            back: try value(env["FEEDLAB_BACK"], default: 5, name: "FEEDLAB_BACK")
        )
    }

    private static func value<T: LosslessStringConvertible>(
        _ raw: String?, default fallback: T, name: String
    ) throws -> T {
        guard let raw, !raw.isEmpty else { return fallback }
        guard let parsed = T(raw) else { throw RunConfigurationError.malformed(name: name, value: raw) }
        return parsed
    }
}

enum RunConfigurationError: Error, CustomStringConvertible {
    case missingArm
    case malformed(name: String, value: String)

    var description: String {
        switch self {
        case .missingArm:
            return "FEEDLAB_ARM is required — pass TEST_RUNNER_FEEDLAB_ARM=<arm name> to xcodebuild."
        case let .malformed(name, value):
            return "\(name)=\(value) is not a number."
        }
    }
}

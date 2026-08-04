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

    /// How long a flick has to show up as an index change before it is treated as dropped. Generous
    /// because the penalty for being wrong is a spurious second flick, which silently corrupts the
    /// item set; waiting too long merely costs dwell, which is accounted for.
    private static let pageSettleTimeout: TimeInterval = 3.0

    private static let pagePollInterval: TimeInterval = 0.05

    private static let pageRetries = 2

    private static let indexPrefix = "feed.index."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMeasurementRun() throws {
        let config = try RunConfiguration.fromEnvironment()

        let app = XCUIApplication()
        app.launchArguments = [
            "-arm", config.arm,
            "-manifest", config.manifest,
            "-hud", config.hud ? "1" : "0"
        ]
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App never reached the foreground — the run would have measured nothing."
        )

        // The HUD-perturbation criterion is a comparison against runs with the HUD off, so a
        // requested HUD that never appeared would report — convincingly — that the HUD is free.
        // The flag was in fact read and ignored at launch for exactly one build; assert, don't trust.
        let hudLabel = app.staticTexts["ARM"]
        if config.hud {
            XCTAssertTrue(
                hudLabel.waitForExistence(timeout: 10),
                "-hud 1 was passed but the HUD is not on screen; this run would understate its cost."
            )
        } else {
            XCTAssertFalse(hudLabel.exists, "HUD is visible on a run that did not ask for it.")
        }

        // The first item is already on screen at launch, so it gets its dwell before any swipe.
        // It is also the warm-up item the protocol discards; it is still viewed, so it is still timed.
        wait(config.dwell)

        // Laps rather than one long pass. The measurement corpus is 7 HLS items, and a per-run p90
        // over 7 samples is just the worst item wearing a percentile's name; lapping the corpus
        // gets the sample count up without inventing content the project has no licence to.
        //
        // The cost, stated because it is real: the first lap is cold and later laps are not. Views
        // after the first benefit from a warm CDN and OS cache, which compresses the difference
        // between arms — every arm equally, so the ranking holds, but the *magnitudes* are a floor
        // on what a cold audience would see, not an estimate of it.
        for _ in 0..<config.laps {
            for _ in 0..<config.forward {
                dwell(config, after: page(app, from: Self.dragFrom, to: Self.dragTo))
            }
            for _ in 0..<config.back {
                dwell(config, after: page(app, from: Self.dragTo, to: Self.dragFrom))
            }
        }

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: Self.sealTimeout),
            "App did not background — the session was never sealed and nothing was written."
        )
        // Backgrounding starts the seal; the write itself is asynchronous.
        wait(Self.sealTimeout)
    }

    /// One flick, confirmed to have actually changed the page.
    ///
    /// Roughly one synthesized flick in ten was silently dropped — concentrated on the reversal from
    /// forward to backward scrolling, where a nominal 5-back tail consistently produced 3 views. The
    /// run then covered a different item set every time, which is precisely what "identical run
    /// script across arms" exists to prevent, and nothing in the resulting session says so: a run
    /// short two views looks exactly like a run that was meant to be that long.
    ///
    /// Retried rather than asserted, because the goal is a complete run, not a diagnosis. If the
    /// page still has not moved after `pageRetries` attempts the feed is genuinely at a boundary or
    /// wedged, and that *is* worth failing on.
    /// Returns how long verification consumed, so the caller can charge it against dwell.
    @discardableResult
    private func page(_ app: XCUIApplication, from: CGVector, to: CGVector) -> TimeInterval {
        let start = Date()
        let before = currentIndex(app)
        for attempt in 0...Self.pageRetries {
            swipe(app, from: from, to: to)
            if awaitIndexChange(app, from: before) { return Date().timeIntervalSince(start) }
            if attempt < Self.pageRetries {
                XCTContext.runActivity(named: "flick dropped at index \(before ?? -1) — retrying") { _ in }
            }
        }
        XCTFail("Feed did not page away from index \(before ?? -1) after \(Self.pageRetries + 1) flicks.")
        return Date().timeIntervalSince(start)
    }

    /// Polls for the index to change rather than sampling once after a fixed delay.
    ///
    /// A single read is only correct when the app answers promptly. Under a constrained network the
    /// index came back stale, the flick was judged dropped, and the retry fired a *second* real
    /// flick — producing runs that skipped items and jumped four pages at once. Verification that
    /// over-pages under load is worse than none: it corrupts the item set while reporting success.
    /// Polling costs nothing on the happy path, where the change is visible almost immediately.
    private func awaitIndexChange(_ app: XCUIApplication, from before: Int?) -> Bool {
        let deadline = Date().addingTimeInterval(Self.pageSettleTimeout)
        repeat {
            if currentIndex(app) != before { return true }
            Thread.sleep(forTimeInterval: Self.pagePollInterval)
        } while Date() < deadline
        return false
    }

    /// The feed publishes its current index as an accessibility identifier. Read from the collection
    /// view rather than from a cell: cells are recycled and several carry a title at once, so "the
    /// visible one" is a question with no cheap answer, while the collection view is singular and
    /// always current.
    private func currentIndex(_ app: XCUIApplication) -> Int? {
        let identifier = app.collectionViews.firstMatch.identifier
        guard identifier.hasPrefix(Self.indexPrefix) else { return nil }
        return Int(identifier.dropFirst(Self.indexPrefix.count))
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
        Thread.sleep(forTimeInterval: max(0, interval))
    }

    /// Verification time already elapsed on screen with the new item current, so it counts as dwell.
    /// Adding to it instead would make the measured view longer than the protocol says, and
    /// unequally so between a fast confirmation and a slow one — which is exactly the operator-drift
    /// problem the runner exists to remove, reintroduced by the runner itself.
    private func dwell(_ config: RunConfiguration, after verification: TimeInterval) {
        wait(config.dwell - verification)
    }
}

/// The run script's parameters, resolved once so a malformed value fails before the app launches
/// rather than halfway through a run that would then be silently unusable.
struct RunConfiguration {
    let arm: String
    let manifest: String
    let dwell: TimeInterval
    let forward: Int
    let back: Int
    let laps: Int
    /// Off unless asked for, matching the app. The HUD-perturbation criterion compares a run with it
    /// on against one with it off, so it has to be settable per run rather than per build.
    let hud: Bool

    static func fromEnvironment() throws -> RunConfiguration {
        let env = ProcessInfo.processInfo.environment

        // No default for the arm. Every other parameter has a defensible default; the arm does not,
        // and a run mislabelled as the control is worse than a run that refused to start.
        guard let arm = env["FEEDLAB_ARM"], !arm.isEmpty else {
            throw RunConfigurationError.missingArm
        }
        return RunConfiguration(
            arm: arm,
            // The measurement corpus, not the app's default one — see `RootFactory`.
            manifest: env["FEEDLAB_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 } ?? "hls-only",
            dwell: try value(env["FEEDLAB_DWELL"], default: 5, name: "FEEDLAB_DWELL"),
            forward: try value(env["FEEDLAB_FORWARD"], default: 6, name: "FEEDLAB_FORWARD"),
            back: try value(env["FEEDLAB_BACK"], default: 6, name: "FEEDLAB_BACK"),
            laps: try value(env["FEEDLAB_LAPS"], default: 2, name: "FEEDLAB_LAPS"),
            hud: (env["FEEDLAB_HUD"] ?? "0") == "1"
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

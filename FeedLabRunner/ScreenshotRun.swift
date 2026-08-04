import XCTest

/// Captures the README screenshots on a real device.
///
/// Separate from `MeasurementRun` because it is a different job: that one must not be perturbed by
/// anything, this one taps through UI and takes pictures. Sharing a class would mean every
/// measurement run carried screenshot code it never uses.
///
/// **On device rather than a simulator, deliberately.** The HUD renders live figures from the
/// session in progress, so a simulator capture would put simulator numbers in the README — which
/// `docs/testing.md` forbids. The dashboard is a viewer of stored sessions and could in principle be
/// shot anywhere, but shooting everything the same way removes the question.
///
/// ```
/// xcodebuild test -scheme FeedLabRunner -configuration Measure \
///   -destination 'platform=iOS,id=<ECID>' -only-testing:FeedLabRunner/ScreenshotRun
/// xcrun xcresulttool export attachments --path <result>.xcresult --output-path docs/images
/// ```
final class ScreenshotRun: XCTestCase {
    private static let dragFrom = CGVector(dx: 0.5, dy: 0.78)
    private static let dragTo = CGVector(dx: 0.5, dy: 0.22)

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The feed itself, HUD off — it is still a real app, not only a rig.
    func testFeedScreenshot() throws {
        let app = launch(hud: false)
        // Two items in, so the frame shown is one the feed navigated to rather than the cold first
        // item, and playback has had time to start.
        swipe(app)
        Thread.sleep(forTimeInterval: 4)
        capture(app, named: "feed")
    }

    /// The HUD mid-session, arm name visible. The figures in it are this device's.
    func testHUDScreenshot() throws {
        let app = launch(hud: true)
        XCTAssertTrue(
            app.staticTexts["ARM"].waitForExistence(timeout: 10),
            "HUD absent — the screenshot would show the feed and be captioned as the HUD."
        )
        // Several items so the session block reads a real p90 and pool occupancy rather than the
        // first item's degenerate one-sample state.
        for _ in 0..<4 {
            swipe(app)
            Thread.sleep(forTimeInterval: 5)
        }
        capture(app, named: "hud")
    }

    /// The dashboard's charts, over whatever sessions are on the device.
    ///
    /// Those are pushed there beforehand with `devicectl device copy to`, so the charts show the
    /// committed measurement corpus rather than whatever the last run happened to leave behind.
    func testDashboardScreenshots() throws {
        let app = launch(hud: false)

        app.buttons["Debug menu"].tap()
        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 10), "Debug menu did not open.")
        capture(app, named: "debug-menu")

        app.buttons["Dashboard"].tap()
        // The store reads every session file off disk; give it time before photographing an empty chart.
        Thread.sleep(forTimeInterval: 3)
        capture(app, named: "dashboard-1")

        // The charts are a vertical stack; walk it so each one gets its own frame.
        for index in 2...5 {
            app.swipeUp(velocity: .slow)
            // Swift Charts lays out lazily inside the scroll view, and a chart photographed too
            // early renders its axes with no marks — which reads as "this arm has no data" rather
            // than as a screenshot taken too soon. Peak memory came out empty at 1.5 s.
            Thread.sleep(forTimeInterval: 4)
            capture(app, named: "dashboard-\(index)")
        }
    }

    // MARK: - Helpers

    private func launch(hud: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-arm", ProcessInfo.processInfo.environment["FEEDLAB_ARM"] ?? "preload3-capped",
            "-manifest", ProcessInfo.processInfo.environment["FEEDLAB_MANIFEST"] ?? "hls-only",
            "-hud", hud ? "1" : "0"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        Thread.sleep(forTimeInterval: 4)
        return app
    }

    private func swipe(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: Self.dragFrom)
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: Self.dragTo),
                   withVelocity: .fast,
                   thenHoldForDuration: 0)
    }

    /// `.keepAlways`, or XCTest discards attachments from passing tests and the run produces
    /// nothing — the failure mode being a green test and an empty output directory.
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

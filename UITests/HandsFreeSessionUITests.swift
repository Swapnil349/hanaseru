import XCTest

/// Plays real sessions end-to-end in the Simulator with the scripted demo voice (no microphone needed),
/// and attaches screenshots so the app can be reviewed from a CI run without a Mac.
final class HandsFreeSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTwoMinuteSessionPlaysThroughToSummary() throws {
        let app = launch(onboarded: true)
        screenshot(app, "01-home")

        app.buttons["time-2"].tap()
        app.buttons["start-session"].tap()

        let yourTurn = app.descendants(matching: .any)["status-listening"]
        XCTAssertTrue(yourTurn.waitForExistence(timeout: 90), "The learner's turn never came")
        screenshot(app, "02-your-turn")

        let done = app.buttons["summary-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 240), "The session never reached its summary")
        screenshot(app, "03-summary")
        done.tap()

        XCTAssertTrue(app.buttons["start-session"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testFiveMinuteWorkSessionReachesConversation() throws {
        let app = launch(onboarded: true)
        app.buttons["time-5"].tap()
        app.buttons["Work Japanese"].tap()
        app.buttons["start-session"].tap()

        let done = app.buttons["summary-done"]
        var shots = 0
        // Take a few screenshots along the way (listening, speaking, role-play), then wait for the summary.
        while !done.exists && shots < 6 {
            sleep(15)
            shots += 1
            screenshot(app, "10-work-session-\(shots)")
        }
        XCTAssertTrue(done.waitForExistence(timeout: 300), "The work session never reached its summary")
        screenshot(app, "11-work-summary")
    }

    @MainActor
    func testTabsAndOnboardingRender() throws {
        let first = launch(onboarded: false)
        screenshot(first, "20-onboarding")
        first.terminate()

        let app = launch(onboarded: true)
        for (tab, name) in [("My Japanese", "21-my-japanese"), ("Progress", "22-progress"), ("Settings", "23-settings")] {
            app.tabBars.buttons[tab].tap()
            screenshot(app, name)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // Launch arguments of the form "-key value" land in UserDefaults' argument domain.
        app.launchArguments += ["-demoVoice", "YES", "-onboardingDone", onboarded ? "YES" : "NO"]
        app.launch()
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

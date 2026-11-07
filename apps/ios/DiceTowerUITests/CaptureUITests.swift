import XCTest

@MainActor final class CaptureUITests: XCTestCase {
    func testTowerSetupCanKeepCapturesLocal() throws {
        let app = XCUIApplication(); app.launchArguments = ["-capture-demo"]; app.launch()
        let sharing = app.buttons["tower-sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 15))
        app.scrollViews.firstMatch.swipeUp()
        sharing.tap()
        XCTAssertTrue(app.textFields["tower-name"].waitForExistence(timeout: 10))
        app.buttons["keep-local"].tap()
        XCTAssertTrue(app.buttons["manual-photo"].exists)
    }

    func testLiveFirebaseTowerRegistrationAndRollUpload() throws {
        guard ProcessInfo.processInfo.environment["DICETOWER_LIVE_QA"] == "1" else { throw XCTSkip("Live Firebase QA requires explicit opt-in.") }
        let app = XCUIApplication()
        app.launchArguments = ["-capture-demo", "-cloud-demo", "-cloudTowerOnboarded", "NO"]
        app.launch()
        let field = app.textFields["tower-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "QA Simulator Rig")
        app.buttons["connect-tower"].tap()
        let status = app.buttons["tower-sharing"]
        XCTAssertTrue(status.waitForExistence(timeout: 40))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Live"), evaluatedWith: status)
        waitForExpectations(timeout: 40)
        let recognition = app.staticTexts["recognition-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Quiescent"), evaluatedWith: recognition)
        waitForExpectations(timeout: 40)
        attach(app, "07-firebase-sharing")
        let next = app.buttons["next-arrangement"]
        if !next.isHittable { app.swipeUp() }; next.tap()
        let delivery = expectation(description: "Deliver the new motion episode")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { delivery.fulfill() }
        waitForExpectations(timeout: 25)
    }

    func testBundledModelProducesASettledReading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-capture-demo"]
        app.launch()
        let status = app.staticTexts["recognition-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Quiescent", "No dice detected"), evaluatedWith: status)
        waitForExpectations(timeout: 60)
        let metrics = app.descendants(matching: .any)["recognition-metrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 10))
        let frozen = metrics.value as? String ?? ""
        XCTAssertTrue(frozen.contains("quiescent"))
        let unchanged = expectation(for: NSPredicate(format: "value != %@", frozen), evaluatedWith: metrics)
        unchanged.isInverted = true
        waitForExpectations(timeout: 1.0)
        attach(app, "06-live-model-settled")
    }

    func testAutomaticCaptureRearrangementManualCaptureAndExport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-capture-demo"]
        app.launch()
        let start = app.buttons["toggle-auto"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: start)
        waitForExpectations(timeout: 15)
        let initial = Int(app.staticTexts["saved-count"].value as? String ?? "0") ?? 0
        start.tap()
        let count = app.staticTexts["saved-count"]
        expectation(for: NSPredicate(format: "value == %@", String(initial + 1)), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        attach(app, "01-auto-captured")
        let next = app.buttons["next-arrangement"]
        if !next.isHittable { app.swipeUp() }
        next.tap()
        expectation(for: NSPredicate(format: "value == %@", String(initial + 2)), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        start.tap()
        app.buttons["manual-photo"].tap()
        expectation(for: NSPredicate(format: "value == %@", String(initial + 3)), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        attach(app, "02-manual-captured")
        let export = app.buttons["export-session"]
        if !export.isHittable { app.swipeUp() }
        export.tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 15))
        attach(app, "03-session-share")
        app.buttons["Close"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["saved-count"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value == %@", String(initial + 3)), evaluatedWith: app.staticTexts["saved-count"])
        waitForExpectations(timeout: 15)
        attach(app, "04-photos-restored")
        app.buttons["open-library"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 10))
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["\(initial + 3) photos"].waitForExistence(timeout: 10))
        app.buttons["Export session ZIP"].tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 15))
        attach(app, "05-library-share")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot());attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
    }
}

import XCTest

@MainActor final class CaptureUITests: XCTestCase {
    func testNoiseRearmsRecognitionButDuplicateIsDiscardedAndCounted() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-capture-demo", "-recognition-noise-demo", "-recognition-fast-roll-demo"]
        app.launch()
        let status = app.staticTexts["recognition-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Quiescent"), evaluatedWith: status)
        waitForExpectations(timeout: 60)
        let metrics = app.descendants(matching: .any)["recognition-metrics"]
        expectation(for: NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            return value.contains("duplicates ") && !value.contains("duplicates 0")
        }, evaluatedWith: metrics)
        waitForExpectations(timeout: 20)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "duplicate discarded"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let frozen = metrics.value as? String ?? ""
        let next = app.buttons["next-arrangement"]
        if !next.isHittable { app.swipeUp() }
        next.tap()
        expectation(for: NSPredicate(format: "value != %@", frozen), evaluatedWith: metrics)
        waitForExpectations(timeout: 15)
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Quiescent"), evaluatedWith: status)
        waitForExpectations(timeout: 20)
    }

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
        app.launchArguments = ["-capture-demo", "-recognition-noise-demo", "-cloud-demo", "-upload-poison-demo", "-cloudTowerOnboarded", "NO"]
        app.launch()
        let field = app.textFields["tower-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "QA Simulator Rig")
        app.buttons["connect-tower"].tap()
        let status = app.buttons["tower-sharing"]
        XCTAssertTrue(status.waitForExistence(timeout: 40))
        expectation(for: NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Live", "held"), evaluatedWith: status)
        waitForExpectations(timeout: 40)
        let recognition = app.staticTexts["recognition-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Quiescent"), evaluatedWith: recognition)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(app.staticTexts["roll-delivery"].exists)
        attach(app, "07-firebase-sharing")
        let next = app.buttons["next-arrangement"]
        if !next.isHittable { app.swipeUp() }; next.tap()
        let delivery = expectation(description: "Deliver the new motion episode")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { delivery.fulfill() }
        waitForExpectations(timeout: 25)
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Delivered"), evaluatedWith: app.staticTexts["roll-delivery"])
        waitForExpectations(timeout: 20)
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
        let torch = app.switches["torch-toggle"]
        XCTAssertTrue(torch.exists)
        XCTAssertFalse(torch.isEnabled) // Simulator fixture has no physical light.
        XCTAssertEqual(torch.value as? String, "0")
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

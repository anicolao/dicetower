import XCTest

final class CaptureUITests: XCTestCase {
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

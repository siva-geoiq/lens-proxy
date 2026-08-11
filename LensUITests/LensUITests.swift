import XCTest

@MainActor
final class LensUITests: XCTestCase {
    func testThreePaneCaptureAndFiltering() {
        let app = launchApplication()

        XCTAssertTrue(app.staticTexts["Lens · Listening on :8080"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'firebaseremoteconfig.googleapis.com'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["1/1 flows"].exists)

        let filter = app.textFields["Filter by URL, method, or status"]
        XCTAssertTrue(filter.exists)
        filter.click()
        filter.typeText("not-present")
        XCTAssertTrue(app.staticTexts["0/1 flows"].waitForExistence(timeout: 2))
    }

    func testMapLocalResponseOpensRuleEditor() {
        let app = launchApplication()

        let flow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'firebaseremoteconfig.googleapis.com/v1/projects'")).firstMatch
        XCTAssertTrue(flow.waitForExistence(timeout: 3))
        flow.rightClick()
        let mapLocal = app.menuItems["Map Local Response"]
        XCTAssertTrue(mapLocal.waitForExistence(timeout: 2))
        mapLocal.click()
        XCTAssertTrue(app.staticTexts["First enabled matching rule wins."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save"].exists)
    }

    func testDetachedDeviceBannerOffersOneClickAttach() {
        let app = launchApplication()

        XCTAssertTrue(app.staticTexts["Device detached"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["sdk_gphone64_arm64 traffic is not routed through Lens."].exists)
        XCTAssertTrue(app.buttons["Attach"].isEnabled)
    }

    private func launchApplication() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }
}

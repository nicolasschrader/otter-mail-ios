import XCTest

/** The bottom bar on the demo mailbox: Threads, Mail, Calendar, Tasks, and what ⌃⌄ opens in each. */
final class HomeBarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        XCTAssertTrue(app.buttons["Mail"].waitForExistence(timeout: 8), "Mail tab missing")
    }

    func testBarHasThreadsMailCalendarTasks() {
        let app = XCUIApplication()
        for tab in ["Threads", "Mail", "Calendar"] {
            XCTAssertTrue(app.buttons[tab].exists, "\(tab) tab missing")
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tasks")).firstMatch.exists, "Tasks tab missing")
        XCTAssertTrue(app.buttons["All places"].exists, "Mail's ⌃⌄ missing")
    }

    func testCalendarScopeListsTheCalendars() {
        let app = XCUIApplication()
        app.buttons["Calendar"].tap()
        let calendars = app.buttons.matching(NSPredicate(format: "label == %@", "Calendars")).firstMatch
        XCTAssertTrue(calendars.waitForExistence(timeout: 5))
        calendars.tap()
        XCTAssertTrue(app.buttons["Back to Calendar"].waitForExistence(timeout: 5), "calendar list didn't open in place")
    }

    func testTasksHasNoScopeButton() {
        let app = XCUIApplication()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tasks")).firstMatch.tap()
        XCTAssertFalse(app.buttons["All places"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Calendars"].exists)
    }

    /** The demo calendar has an invitation waiting (Garden planning), so Threads opens on it. */
    func testThreadsOpensOnTheInvitation() {
        let app = XCUIApplication()
        app.buttons["Threads"].tap()
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 8), "invitation card missing")
        XCTAssertTrue(app.buttons["Decline"].exists)
        XCTAssertTrue(app.buttons["Maybe"].exists)
    }
}

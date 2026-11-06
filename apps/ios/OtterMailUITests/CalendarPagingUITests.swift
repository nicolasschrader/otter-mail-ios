import XCTest

/**
 * Drives Agenda ↔ Day ↔ Month swipes for hitch measurement and a basic
 * functional check of the phone calendar pager.
 */
final class CalendarPagingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-otter:shot", "calendar"]
        app.launch()
        enterDemoIfNeeded(app)
        openCalendar(app)
    }

    func testSwipeAgendaDayMonthAndBack() throws {
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["Agenda"].waitForExistence(timeout: 8), "Agenda picker missing")

        swipeContent(app, left: true)
        sleep(1)
        swipeContent(app, left: true)
        sleep(1)
        XCTAssertTrue(app.buttons["Month"].exists)

        swipeContent(app, left: false)
        sleep(1)
        swipeContent(app, left: false)
        sleep(1)

        for _ in 0..<4 {
            swipeContent(app, left: true)
            usleep(500_000)
            swipeContent(app, left: false)
            usleep(500_000)
        }
    }

    func testPickerStaysInSyncAndChevronsWork() throws {
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["Day"].waitForExistence(timeout: 8))
        app.buttons["Day"].tap()
        sleep(1)

        // Pages stay mounted with their own steppers; prefer a hittable Next.
        let next = hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Next")))
        let previous = hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Previous")))
        XCTAssertNotNil(next, "Day Next chevron")
        next?.tap()
        usleep(400_000)
        previous?.tap()

        app.buttons["Month"].tap()
        sleep(1)
        hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Next")))?.tap()
        usleep(400_000)
        hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Previous")))?.tap()

        app.buttons["Agenda"].tap()
        sleep(1)
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        if list.exists {
            list.swipeUp()
            usleep(300_000)
            list.swipeDown()
        }
    }

    private func hittable(_ query: XCUIElementQuery) -> XCUIElement? {
        let count = query.count
        for index in 0..<count {
            let element = query.element(boundBy: index)
            if element.exists && element.isHittable { return element }
        }
        return query.element(boundBy: 0).exists ? query.element(boundBy: 0) : nil
    }

    private func swipeContent(_ app: XCUIApplication, left: Bool) {
        let start = left ? CGVector(dx: 0.85, dy: 0.55) : CGVector(dx: 0.15, dy: 0.55)
        let end = left ? CGVector(dx: 0.15, dy: 0.55) : CGVector(dx: 0.85, dy: 0.55)
        app.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: end))
    }

    private func enterDemoIfNeeded(_ app: XCUIApplication) {
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) {
            demo.tap()
            sleep(2)
        }
    }

    private func openCalendar(_ app: XCUIApplication) {
        if app.buttons["Agenda"].waitForExistence(timeout: 3) { return }
        let calendar = app.buttons["Calendar"]
        if calendar.waitForExistence(timeout: 5) {
            calendar.tap()
            _ = app.buttons["Agenda"].waitForExistence(timeout: 5)
        }
    }
}

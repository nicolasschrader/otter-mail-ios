import XCTest

/**
 * Tapping an event pushes that event alone, whatever page it's on, and one
 * Back returns to the page it was tapped on, as it was left. Each test turns
 * to another page first, so the pages kept mounted beside the one in front
 * are part of it. On the demo mailbox: its events open in the editor or the
 * read-only view, both titled "Event", and nothing is saved.
 */
final class CalendarNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-otter:shot", "calendar"]
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        if !app.buttons["Agenda"].waitForExistence(timeout: 5) {
            app.buttons["Calendar"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["Agenda"].waitForExistence(timeout: 8), "the calendar didn't open")
    }

    func testAgendaOpensOneEvent() throws {
        let app = XCUIApplication()
        turn(app, to: "Month")
        turn(app, to: "Agenda")
        let page = self.page(app, "agenda")
        let rows = page.buttons
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the agenda lists nothing")
        // A row with others in its section and around it.
        let row = rows.element(boundBy: min(2, rows.count - 1))
        opensOnce(app, row, from: "Agenda")
        XCTAssertTrue(row.exists, "the agenda's row is gone after Back")
    }

    func testDayOpensOneTimedEvent() throws {
        let app = XCUIApplication()
        turn(app, to: "Month")
        turn(app, to: "Day")
        let page = self.page(app, "day")
        let grid = page.descendants(matching: .any)["day-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "the day's grid is missing")
        // Today's lunch has the printer's call over its end: two blocks side by side.
        let lunch = grid.buttons.matching(identifier: "day-grid-event")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Lunch with Mum")).firstMatch
        XCTAssertTrue(lunch.waitForExistence(timeout: 5), "lunch isn't in the grid")
        XCTAssertGreaterThan(grid.buttons.matching(identifier: "day-grid-event").count, 1, "the day has one event")
        opensOnce(app, lunch, from: "Day")
        XCTAssertTrue(lunch.waitForExistence(timeout: 3), "Back didn't return to the same day")
    }

    func testDayOpensOneAllDayEvent() throws {
        let app = XCUIApplication()
        turn(app, to: "Agenda")
        turn(app, to: "Day")
        let page = self.page(app, "day")
        let allDay = page.buttons.matching(identifier: "day-grid-all-day").firstMatch
        for _ in 0..<31 where !allDay.waitForExistence(timeout: 1.5) { page.buttons["Next"].tap() }
        XCTAssertTrue(allDay.exists, "no all-day event in the month ahead")
        let label = allDay.label
        opensOnce(app, allDay, from: "Day")
        XCTAssertEqual(page.buttons.matching(identifier: "day-grid-all-day").firstMatch.label, label, "Back didn't return to the same day")
    }

    /**
     * The week under the month is one list row holding every day's events: a
     * week with events on several days, and a day with more than one, taps one
     * of them in the middle.
     */
    func testMonthWeekOpensOneEvent() throws {
        let app = XCUIApplication()
        turn(app, to: "Day")
        turn(app, to: "Month")
        let page = self.page(app, "month")
        let week = page.descendants(matching: .any)["month-week"]

        var target: (day: Date, link: XCUIElement)?
        var month = Date.now
        for offset in 0..<5 where target == nil {
            let day = Calendar.current.date(byAdding: .day, value: offset * 7, to: .now)!
            if !Calendar.current.isDate(day, equalTo: month, toGranularity: .month) {
                page.buttons["Next"].tap()
                month = day
            }
            pick(app, page, day)
            for _ in 0..<4 where !(rows(week).last?.isHittable ?? false) { page.swipeUp() }
            XCTAssertTrue(week.waitForExistence(timeout: 3), "the week isn't under the month")
            let days = rows(week)
            let withEvents = days.filter { links($0).count > 0 }
            if withEvents.count > 1, let busy = days.first(where: { links($0).count > 1 }) {
                target = (day, links(busy).last!)
            }
            if target == nil { for _ in 0..<4 { page.swipeDown() } }
        }
        guard let (day, link) = target else { return XCTFail("no week with events on several days, one with two") }
        XCTAssertGreaterThan(week.buttons.count - 7, 2, "the week holds one event link")
        opensOnce(app, link, from: "Month")
        let row = week.descendants(matching: .any)["month-week-\(key(day))"]
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the picked week is gone after Back")
        XCTAssertTrue(row.buttons.firstMatch.isSelected, "the picked day wasn't kept")
    }

    /**
     * Taps the element, expects one event pushed, and backs out once: the
     * page it came from is in front again with nothing left on the stack.
     */
    private func opensOnce(_ app: XCUIApplication, _ element: XCUIElement, from mode: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, "\(element.label) isn't tappable", file: file, line: line)
        element.tap()
        let detail = app.navigationBars["Event"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "tapping \(element.label) didn't open it", file: file, line: line)
        // Let any further pushes land before backing out.
        Thread.sleep(forTimeInterval: 1)

        var backs = 0
        while detail.exists, backs < 20 {
            detail.buttons.firstMatch.tap()
            backs += 1
            _ = waitGone(detail, timeout: 2)
        }
        XCTAssertEqual(backs, 1, "one tap on \(element.label) pushed \(backs) events", file: file, line: line)
        let picker = app.buttons[mode]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Back didn't return to the calendar", file: file, line: line)
        XCTAssertTrue(picker.isSelected, "Back didn't return to \(mode)", file: file, line: line)
        XCTAssertTrue(page(app, mode.lowercased()).exists, "\(mode) isn't in front after Back", file: file, line: line)
    }

    private func turn(_ app: XCUIApplication, to mode: String) {
        let button = app.buttons[mode]
        button.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, "the picker didn't turn to \(mode)")
        XCTAssertTrue(page(app, mode.lowercased()).waitForExistence(timeout: 5), "\(mode) isn't in front")
    }

    private func pick(_ app: XCUIApplication, _ page: XCUIElement, _ day: Date) {
        let label = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let cell = page.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "\(label) isn't in the month's grid")
        cell.tap()
    }

    /** The week's seven days, in order. */
    private func rows(_ week: XCUIElement) -> [XCUIElement] {
        let found = week.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "month-week-"))
        return (0..<found.count).map { found.element(boundBy: $0) }
    }

    /** A day's event links: its buttons after the day's own. */
    private func links(_ row: XCUIElement) -> [XCUIElement] {
        let buttons = row.buttons
        return (0..<buttons.count).dropFirst().map { buttons.element(boundBy: $0) }
    }

    private func page(_ app: XCUIApplication, _ mode: String) -> XCUIElement {
        app.descendants(matching: .any)["calendar-page-\(mode)"]
    }

    private func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}

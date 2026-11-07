import XCTest

/**
 * The sections' toolbars on the demo mailbox: the calendar's + and ⋯ and its
 * event editor (create, change, delete, all on the demo's pretend calendar,
 * never Google), Tasks' + and ⋯ with the editor in place, and the mail's ⌃⌄
 * panel without Search and Settings. The editors and ⋯ › Settings open in the
 * section's own navigation, so the bar stays under them. Screenshots are kept
 * (`keepAlways`): cal-toolbar, event-edit, tasks-toolbar, mail-scope.
 */
final class ToolbarEditingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        XCTAssertTrue(app.buttons["Mail"].waitForExistence(timeout: 8), "Mail tab missing")
    }

    func testCalendarCreatesChangesAndDeletesAnEventInPlace() {
        let app = XCUIApplication()
        app.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["Agenda"].waitForExistence(timeout: 8))

        let add = app.navigationBars.buttons["New event"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "the toolbar's + is missing")
        XCTAssertFalse(app.navigationBars.buttons["Calendars"].exists, "the old Calendars button is back")
        app.navigationBars.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "⋯ has no Settings")
        let today = app.buttons["Go to today"]
        XCTAssertTrue(today.exists)
        attach(app, "cal-toolbar")
        // Closed by one of its own items, as a person would: Go to today leaves the agenda as it is.
        today.tap()
        XCTAssertTrue(waitGone(today), "the menu stayed open after Go to today")
        XCTAssertTrue(app.buttons["Agenda"].exists)

        // A new event, made in place: the bar is still there under the editor.
        let suffix = Int.random(in: 100...999)
        let title = "Demo dentist \(suffix)"
        add.tap()
        let field = titleField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the editor didn't open")
        XCTAssertTrue(app.buttons["places-scope"].exists, "the bar went away under the editor")
        XCTAssertTrue(app.switches["All-day"].exists)
        field.tap()
        field.typeText(title)
        let location = app.textFields["Location"]
        location.tap()
        location.typeText("Studio")
        // The bar steps aside while typing, so it covers none of the form's fields.
        XCTAssertTrue(waitGone(app.buttons["places-scope"]), "the bar rides over the editor while typing")
        attach(app, "event-edit")
        app.navigationBars.buttons["Save"].tap()

        // In the agenda, and it opens to be changed.
        let row = eventRow(app, title)
        XCTAssertTrue(app.buttons["places-scope"].waitForExistence(timeout: 5), "the bar didn't come back after Save")
        // Save with the keyboard up once left the pages sized for it: the picker off the top, the rows under the bar.
        XCTAssertTrue(waitTappable(app.buttons["Agenda"]), "the calendar is laid out off screen after Save")
        XCTAssertTrue(waitTappable(row), "the new event isn't in view in the agenda")
        row.tap()
        XCTAssertTrue(titleField(app).waitForExistence(timeout: 5), "tapping the event didn't open the editor")
        XCTAssertEqual(titleField(app).value as? String, title)
        let renamed = "Demo dentist moved \(suffix)"
        let edit = titleField(app)
        // At the end of the title, so the deletes take all of it.
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        edit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: title.count) + renamed)
        app.navigationBars.buttons["Save"].tap()
        let moved = eventRow(app, renamed)
        XCTAssertTrue(waitTappable(moved), "the changed event isn't in view in the agenda")
        XCTAssertFalse(eventRow(app, title + ",").exists, "the old title is still listed")

        // Deleted from the editor.
        moved.tap()
        let delete = app.buttons["Delete event"]
        // At the foot of the form, which may not have made the row yet: asking `isHittable` of nothing fails.
        XCTAssertTrue(titleField(app).waitForExistence(timeout: 5), "tapping the changed event didn't open the editor")
        for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        XCTAssertTrue(delete.exists && delete.isHittable, "Delete event isn't reachable")
        delete.tap()
        XCTAssertTrue(app.buttons["Agenda"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitGone(eventRow(app, renamed)), "the deleted event is still there")
    }

    func testTasksToolbarAddsInPlaceAndHasSettings() {
        let app = XCUIApplication()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tasks")).firstMatch.tap()
        let add = app.navigationBars.buttons["Add task"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        app.navigationBars.buttons["More"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⋯ has no Settings")
        attach(app, "tasks-toolbar")
        // Closed by its own item: Settings opens in place, and back returns to the list.
        settings.tap()
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 5), "Settings didn't open from Tasks' ⋯")
        settingsBar.buttons.firstMatch.tap()
        XCTAssertTrue(waitGone(settingsBar), "back didn't leave Settings")
        XCTAssertTrue(add.waitForExistence(timeout: 5))

        add.tap()
        XCTAssertTrue(app.navigationBars["New task"].waitForExistence(timeout: 5), "the task editor didn't open")
        XCTAssertTrue(app.buttons["places-scope"].exists, "the task editor isn't in place: the bar went away")
        let task = app.textFields["Task"].exists ? app.textFields["Task"] : app.textViews["Task"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        let content = "Water the plants \(Int.random(in: 100...999))"
        task.tap()
        task.typeText(content)
        app.navigationBars.buttons["Save"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", content)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the task wasn't added")
    }

    func testMailScopePanelHasNoSearchOrSettings() {
        let app = XCUIApplication()
        app.buttons["places-scope"].tap()
        XCTAssertTrue(app.buttons["Inbox"].waitForExistence(timeout: 5), "the panel didn't open")
        let everySearch = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).count
        let toolbarSearch = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Search")).count
        XCTAssertEqual(everySearch, toolbarSearch, "Search is still in the panel")
        XCTAssertFalse(app.buttons["Settings"].exists, "Settings is still in the panel")
        attach(app, "mail-scope")
        app.buttons["Inbox"].tap()

        // The toolbar keeps Search, and ⋯ has Settings.
        XCTAssertTrue(app.navigationBars.buttons["Search"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }

    /** ⋯ › Settings opens in place in Calendar and Tasks, the bar still under it, and back returns to the section. */
    func testSettingsOpensInPlaceAndGoesBack() {
        let app = XCUIApplication()
        let tasks = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tasks")).firstMatch
        let sections: [(String, XCUIElement, String)] = [
            ("Calendar", app.buttons["Calendar"], "New event"),
            ("Tasks", tasks, "Add task"),
        ]
        for (name, tab, landmark) in sections {
            tab.tap()
            XCTAssertTrue(app.navigationBars.buttons[landmark].waitForExistence(timeout: 8), "\(name) didn't open")
            app.navigationBars.buttons["More"].tap()
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "\(name)'s ⋯ has no Settings")
            settings.tap()

            let bar = app.navigationBars["Settings"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "Settings didn't open from \(name)")
            XCTAssertFalse(bar.buttons["Close"].exists, "Settings opened as a sheet from \(name)")
            XCTAssertTrue(app.buttons["places-scope"].exists, "the bar went away under Settings in \(name)")
            XCTAssertTrue(app.buttons["Mail"].exists, "the bar's tabs went away under Settings in \(name)")

            bar.buttons.firstMatch.tap()
            XCTAssertTrue(waitGone(bar), "back didn't leave Settings in \(name)")
            XCTAssertTrue(app.navigationBars.buttons[landmark].waitForExistence(timeout: 5), "back didn't return to \(name)")
            XCTAssertTrue(app.buttons["places-scope"].exists, "the bar is missing after Settings in \(name)")
        }
    }

    /** A row of the agenda in front, by its title. */
    private func eventRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)["calendar-page-agenda"]
            .buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /**
     * Waits for a row the app has just scrolled to (`Reveal`: the agenda
     * brings an event saved into view) to be there and tappable, wherever the
     * clock puts it in the list. The test never scrolls the lazy list itself.
     */
    private func waitTappable(_ row: XCUIElement) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: row)
        return XCTWaiter.wait(for: [ready], timeout: 8) == .completed
    }

    /** A text field or, as a growing one may be, a text view. */
    private func titleField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["event-title"]
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

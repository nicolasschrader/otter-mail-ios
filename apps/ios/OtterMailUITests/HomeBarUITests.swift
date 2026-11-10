import XCTest

/**
 * The bar on the demo mailbox: Mail and Calendar, labeled, ⌃⌄ for what the
 * one in front is scoped by, and only on a module's first page, so it never
 * sits over a pushed page's last row.
 */
final class HomeBarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        XCTAssertTrue(app.buttons["Mail"].waitForExistence(timeout: 8), "Mail tab missing")
    }

    func testBarHasMailAndCalendar() {
        let app = XCUIApplication()
        XCTAssertTrue(app.buttons["Calendar"].exists, "Calendar tab missing")
        XCTAssertTrue(app.staticTexts["Mail"].exists && app.staticTexts["Calendar"].exists, "the tabs aren't labeled")
        XCTAssertEqual(app.buttons["places-scope"].label, "All places")
        app.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["Agenda"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["places-scope"].label, "Calendars")
        app.buttons["places-scope"].tap()
        XCTAssertTrue(app.buttons["All calendars"].waitForExistence(timeout: 5), "the calendars' panel didn't open")
    }

    /**
     * Threads is every inbox's Catch up, in the bar: it counts what it shows,
     * at least the inbox's pill, the invitation first, its answers above the
     * bar, and a card skipped there is one fewer in the tab.
     */
    func testThreadsCatchesUpOnEveryInbox() {
        let app = XCUIApplication()
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Catch up")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 8), "no Catch up pill in the inbox")
        let pillCount = Int(pill.label.components(separatedBy: "· ").last ?? "") ?? 0

        let threads = app.buttons["Threads"]
        XCTAssertTrue(threads.exists, "Threads tab missing")
        XCTAssertTrue(app.staticTexts["Threads"].exists, "the Threads tab isn't labeled")
        threads.tap()
        XCTAssertTrue(app.navigationBars["Catch up"].waitForExistence(timeout: 5), "Threads didn't open Catch up")
        let total = left(app)
        XCTAssertEqual(threads.value as? String, "\(total) left", "the tab and Catch up count different cards")
        XCTAssertGreaterThanOrEqual(total, pillCount, "Threads holds fewer cards than one inbox")

        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 5), "the invitation isn't first")
        for answer in ["Accept", "Decline", "Maybe", "Skip"] {
            XCTAssertTrue(app.buttons[answer].isHittable, "\(answer) is under the bar")
        }
        XCTAssertEqual(app.buttons["places-scope"].label, "Inboxes")

        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["\(total - 1) left"].waitForExistence(timeout: 5))
        XCTAssertEqual(threads.value as? String, "\(total - 1) left")
    }

    /** The tabs' labels share one baseline and their icons one box, whatever the symbol or the label's length. */
    func testTabLabelsShareABaseline() {
        let app = XCUIApplication()
        let labels = ["Threads", "Mail", "Calendar", "Tasks"].map { app.staticTexts[$0].frame }
        let tabs = ["Threads", "Mail", "Calendar", "Tasks"].map { app.buttons[$0].frame }
        // ⌃⌄'s icon is pinned to the top of a box like the tabs', so the same box puts it at their icons' height.
        let scope = app.buttons["places-scope"].frame
        XCTAssertEqual(scope.minY, tabs[0].minY, accuracy: 0.5, "⌃⌄ sits off the tabs")
        XCTAssertEqual(scope.height, tabs[0].height, accuracy: 0.5, "⌃⌄'s box differs from the tabs'")
        for (label, tab) in zip(labels, tabs) {
            XCTAssertEqual(label.maxY, labels[0].maxY, accuracy: 0.5, "a label sits off the others' baseline")
            XCTAssertEqual(tab.height, tabs[0].height, accuracy: 0.5, "the tabs differ in height")
            XCTAssertEqual(tab.maxY - label.maxY, tabs[0].maxY - labels[0].maxY, accuracy: 0.5, "a label's gap to its tab's edge differs")
        }
    }

    /** All new is the first row of the mail's places, over the mailboxes and folders, and opens the same All new. */
    func testAllNewIsFirstInThePlaces() {
        let app = XCUIApplication()
        let unread = app.buttons["Unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5), "the inbox's pills are missing")

        app.buttons["places-scope"].tap()
        let allNew = app.buttons["places-all-new"]
        XCTAssertTrue(allNew.waitForExistence(timeout: 5), "the places have no All new")
        XCTAssertEqual(allNew.label, "All new")
        // The lowest Inbox is the panel's row; the title over the list may read Inbox too.
        let inbox = app.buttons.matching(NSPredicate(format: "label == %@", "Inbox")).allElementsBoundByIndex.map(\.frame.minY).max()
        XCTAssertNotNil(inbox, "the places have no Inbox")
        XCTAssertLessThan(allNew.frame.minY, inbox ?? 0, "All new isn't above the folders")
        let mailboxes = app.buttons.matching(identifier: "places-mailbox").allElementsBoundByIndex
        XCTAssertFalse(mailboxes.isEmpty, "the places have no mailboxes")
        for mailbox in mailboxes {
            XCTAssertLessThan(allNew.frame.minY, mailbox.frame.minY, "All new isn't above the mailboxes")
        }

        allNew.tap()
        XCTAssertTrue(gone(unread), "All new still shows the conversations")
        XCTAssertTrue(app.buttons["Mail"].isSelected, "the Mail tab isn't lit in All new")
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 5), "it isn't Mail's All new")
    }

    /** All new is a view of Mail, not a tab: Mail's ⋯ switches to it with the Mail tab still lit, and its own ⋯ switches back. */
    func testMailsMoreSwitchesBetweenConversationsAndAllNew() {
        let app = XCUIApplication()
        let unread = app.buttons["Unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5), "the inbox's pills are missing")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["All new"].waitForExistence(timeout: 5), "Mail's ⋯ has no All new")
        app.buttons["All new"].tap()
        XCTAssertTrue(gone(unread), "All new still shows the conversations")
        XCTAssertTrue(app.buttons["Mail"].isSelected, "the Mail tab isn't lit in All new")
        XCTAssertEqual(app.buttons.matching(identifier: "All new").count, 0, "All new is a tab")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Conversations"].waitForExistence(timeout: 5), "All new's ⋯ can't switch back")
        app.buttons["Conversations"].tap()
        XCTAssertTrue(unread.waitForExistence(timeout: 5), "Conversations didn't come back")
        XCTAssertTrue(app.buttons["Mail"].isSelected)
    }

    /** An event and a conversation are pushed without the bar, and their last row can be reached. */
    func testPushedPagesHaveNoBarAndTheirLastRowIsReachable() {
        let app = XCUIApplication()
        let bar = app.buttons["places-scope"]

        app.buttons["Calendar"].tap()
        let event = app.buttons.matching(identifier: "event-row").firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 8), "no event in the agenda")
        event.tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 5))
        XCTAssertTrue(gone(bar), "the bar stayed over the event")
        reachesTheEnd(app, of: app.scrollViews.firstMatch, "the event")
        app.navigationBars["Event"].buttons.firstMatch.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the bar didn't come back with the agenda")

        app.buttons["Mail"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Dinner Saturday")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(gone(bar), "the bar stayed over the conversation")
    }

    /** Settings is a sheet with no bar under it: its last row comes into view. */
    func testSettingsLastRowIsReachable() {
        let app = XCUIApplication()
        app.navigationBars.buttons["More"].firstMatch.tap()
        app.buttons["Settings"].tap()
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let version = app.staticTexts["Version"]
        for _ in 0..<8 where !(version.exists && version.isHittable) { form.swipeUp() }
        XCTAssertTrue(version.isHittable, "Settings' last row can't be reached")
        XCTAssertLessThan(version.frame.maxY, app.windows.firstMatch.frame.maxY - 20)
    }

    private func reachesTheEnd(_ app: XCUIApplication, of scroll: XCUIElement, _ what: String) {
        for _ in 0..<6 { scroll.swipeUp() }
        let last = scroll.descendants(matching: .staticText).allElementsBoundByIndex.last
        XCTAssertNotNil(last, "\(what) is empty")
        XCTAssertTrue(last?.isHittable ?? false, "the end of \(what) can't be reached")
    }

    private func left(_ app: XCUIApplication) -> Int {
        let counter = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " left")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        return Int(counter.label.split(separator: " ").first ?? "") ?? 0
    }

    private func gone(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}

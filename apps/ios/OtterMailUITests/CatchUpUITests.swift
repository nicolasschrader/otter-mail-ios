import XCTest

/**
 * Catch up on the demo mailbox keeps what was done across tabs: an unsubscribed
 * newsletter stays gone, a card kept unread stays passed. The demo's unsubscribes
 * post, send and open nothing.
 */
final class CatchUpUITests: XCTestCase {
    private let newsletters = [
        "The Sunday Otter — Issue #112: Rivers, rafts, and remote work",
        "48 hours only: 30% off all hiking gear",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        XCTAssertTrue(app.buttons["Mail"].waitForExistence(timeout: 8), "Mail tab missing")
    }

    func testUnsubscribedMailStaysGoneAfterSwitchingTabs() {
        let app = XCUIApplication()
        openMailCards(app)
        var subject: String?
        for _ in 0..<30 {
            if app.buttons["Unsubscribe"].exists, let shown = newsletters.first(where: { app.staticTexts[$0].exists }) {
                subject = shown
                break
            }
            app.buttons["Keep Unread"].tap()
            XCTAssertTrue(app.buttons["Keep Unread"].waitForExistence(timeout: 5), "ran out of cards before a newsletter")
        }
        guard let subject else { return XCTFail("no newsletter card with Unsubscribe") }

        app.buttons["Unsubscribe"].tap()
        XCTAssertTrue(gone(app.staticTexts[subject]), "card stayed after unsubscribing")

        switchAway(app)
        XCTAssertFalse(app.staticTexts[subject].exists, "unsubscribed mail came back")
        // Through every card left: it isn't further down either.
        for _ in 0..<40 {
            if app.buttons["Later"].exists { app.buttons["Later"].tap(); continue }
            guard app.buttons["Keep Unread"].waitForExistence(timeout: 2) else { break }
            XCTAssertFalse(app.staticTexts[subject].exists, "unsubscribed mail came back")
            app.buttons["Keep Unread"].tap()
        }
    }

    func testKeepUnreadSurvivesSwitchingTabs() {
        let app = XCUIApplication()
        openMailCards(app)
        let before = left(app)
        XCTAssertGreaterThan(before, 1)
        app.buttons["Keep Unread"].tap()
        XCTAssertTrue(app.staticTexts["\(before - 1) left"].waitForExistence(timeout: 5))

        switchAway(app)
        XCTAssertTrue(app.staticTexts["\(before - 1) left"].waitForExistence(timeout: 5), "kept-unread card came back")
        XCTAssertFalse(app.buttons["Later"].exists, "invitations passed over came back")
    }

    /** Threads, past the invitations to the first mail card. */
    private func openMailCards(_ app: XCUIApplication) {
        app.buttons["Threads"].tap()
        let later = app.buttons["Later"]
        while later.waitForExistence(timeout: 3) { later.tap() }
        XCTAssertTrue(app.buttons["Keep Unread"].waitForExistence(timeout: 5), "no mail card")
    }

    private func switchAway(_ app: XCUIApplication) {
        app.buttons["Calendar"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Calendars"].waitForExistence(timeout: 5))
        app.buttons["Mail"].tap()
        XCTAssertTrue(app.buttons["All places"].waitForExistence(timeout: 5))
        app.buttons["Threads"].tap()
        XCTAssertTrue(app.buttons["Keep Unread"].waitForExistence(timeout: 8), "Threads didn't come back to a card")
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

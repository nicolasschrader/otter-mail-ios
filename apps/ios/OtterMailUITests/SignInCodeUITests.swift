import XCTest

/**
 * The demo mailbox's "Your Linden sign-in code" (482913) shows its code card
 * in the inbox, in Catch up and in the reader. Copy says "Copied" on the
 * button without opening the conversation; the row's title still opens it,
 * the card stays once the mail is read, and the row still swipes. Made-up
 * mail only: nothing is sent.
 */
final class SignInCodeUITests: XCTestCase {
    private let subject = "Your Linden sign-in code"
    private let code = "482913"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // "Copied" normally goes after 1.5s, before XCUITest is done waiting for the tap to settle; keep it here.
        app.launchEnvironment["OTTER_COPIED_SECONDS"] = "0"
        app.launch()
        let demo = app.buttons["Try the demo mailbox"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        XCTAssertTrue(app.buttons["Mail"].waitForExistence(timeout: 8), "Mail tab missing")
    }

    func testCodeCardInInboxCatchUpAndThread() {
        let app = XCUIApplication()

        // The inbox: the code mail's row carries the card, and Copy stays in the list.
        app.buttons["Mail"].tap()
        XCTAssertTrue(app.buttons["All places"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["otp-copy"].firstMatch.waitForExistence(timeout: 8), "no code card in the inbox")
        XCTAssertTrue(app.staticTexts[code].exists, "code card shows the wrong code")
        attach(app, "otp-home")
        copy(app, "in the inbox")
        XCTAssertTrue(app.buttons["All places"].exists, "Copy opened the conversation")

        // Catch up, past the invitations and any newer mail, to the code mail's card.
        app.buttons["Threads"].tap()
        let later = app.buttons["Later"]
        while later.waitForExistence(timeout: 3) { later.tap() }
        for _ in 0..<30 where !app.staticTexts[subject].exists {
            XCTAssertTrue(app.buttons["Keep Unread"].waitForExistence(timeout: 5), "ran out of cards before the code mail")
            app.buttons["Keep Unread"].tap()
        }
        XCTAssertTrue(app.staticTexts[subject].waitForExistence(timeout: 5), "no Catch up card for the code mail")
        copy(app, "in Catch up")
        XCTAssertTrue(app.buttons["Keep Unread"].exists, "Copy left the card")

        // The row's title opens the reader, which has the card too.
        app.buttons["Mail"].tap()
        XCTAssertTrue(app.buttons["All places"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", subject)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "code mail missing from the inbox")
        row.tap()
        XCTAssertTrue(app.staticTexts[subject].waitForExistence(timeout: 5), "tapping the row didn't open the conversation")
        XCTAssertFalse(app.buttons["All places"].exists)
        XCTAssertTrue(app.staticTexts[code].waitForExistence(timeout: 5), "no code card in the reader")
        attach(app, "otp-thread")
        copy(app, "in the reader")

        // Back in the inbox, read now, the row keeps its card; and it still swipes (right: Archive).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["All places"].waitForExistence(timeout: 5), "didn't come back to the inbox")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let card = app.otherElements.matching(identifier: "otp-card").allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(card, "the read row lost its code card")
        card?.swipeRight()
        XCTAssertTrue(gone(row), "swiping the row on its card didn't archive it")
    }

    /** Taps the Copy on screen and waits for one more "Copied". Hidden tabs keep their cards, hence the counting. */
    private func copy(_ app: XCUIApplication, _ place: String) {
        let buttons = app.buttons.matching(identifier: "otp-copy")
        guard let button = buttons.allElementsBoundByIndex.first(where: { $0.isHittable && $0.label == "Copy code" }) else {
            return XCTFail("no Copy \(place)")
        }
        let copied = buttons.matching(NSPredicate(format: "label == %@", "Copied"))
        let before = copied.count
        button.tap()
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", before), object: copied)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "Copy didn't say Copied \(place)")
    }

    private func gone(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

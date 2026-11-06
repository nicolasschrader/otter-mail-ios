import Foundation
import Testing
@testable import Otter_Mail

struct CatchUpTests {
    private func thread(_ id: String, unread: Bool = true, starred: Bool = false, labels: Set<String> = ["INBOX"],
                        mailbox: String = "me@example.com", date: Date = .now) -> MailThread {
        let message = Message(id: "\(id)-m", from: Person(name: "Ann", email: "ann@example.com"), to: [], cc: [], date: date,
                              text: "", html: nil, attachments: [], unread: unread, starred: starred, draft: false, headers: [:])
        return MailThread(id: id, mailbox: mailbox, subject: id, labels: labels, messages: [message])
    }

    @Test func queuesTheUnreadInTheListsOrder() {
        let inbox = [thread("c"), thread("b", unread: false), thread("a")]
        #expect(CatchUp.queue(inbox).map(\.id) == ["c", "a"])
        #expect(CatchUp.queue(inbox, passed: ["c"]).map(\.id) == ["a"])
        #expect(CatchUp.queue([thread("b", unread: false)]).isEmpty)
    }

    @Test func findsTheLabelByNameInAnyCaseOrById() {
        let byName = [MailLabel(id: "Label_1", name: "Todo"), MailLabel(id: "Label_2", name: "bearbeiten")]
        #expect(CatchUp.label(in: byName)?.id == "Label_2")
        let byID = [MailLabel(id: "Bearbeiten", name: "Work/Edit")]
        #expect(CatchUp.label(in: byID)?.id == "Bearbeiten")
        #expect(CatchUp.label(in: [MailLabel(id: "Label_3", name: "Bearbeitet")]) == nil)
        #expect(CatchUp.label(in: []) == nil)
    }

    @Test func marksWithTheLabelElseTheStar() {
        let labels = [MailLabel(id: "Label_2", name: "Bearbeiten")]
        #expect(CatchUp.mark(thread("a"), labels: labels) == .label("Label_2"))
        #expect(CatchUp.mark(thread("a", labels: ["INBOX", "Label_2"]), labels: labels) == nil)
        #expect(CatchUp.mark(thread("a"), labels: []) == .star)
        #expect(CatchUp.mark(thread("a", starred: true), labels: []) == nil)
    }

    @MainActor @Test func movesOnOnceAnUnsubscribeGoesThroughOrIsHandedOff() {
        #expect(CatchUp.advances(after: .done))
        #expect(CatchUp.advances(after: .openedPage))
        #expect(!CatchUp.advances(after: .failed("No network")))
    }

    @Test func queuesEveryInboxNewestFirst() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let work = [thread("w2", mailbox: "work@example.com", date: t + 20), thread("w1", mailbox: "work@example.com", date: t),
                    thread("w0", unread: false, mailbox: "work@example.com", date: t + 99)]
        let home = [thread("h1", mailbox: "home@example.com", date: t + 10), thread("h0", mailbox: "home@example.com", date: t)]
        #expect(CatchUp.queue(inboxes: [work, home]).map(\.id) == ["w2", "h1", "h0", "w1"])
        #expect(CatchUp.queue(inboxes: [home, work]).map(\.id) == ["w2", "h1", "h0", "w1"])
        #expect(CatchUp.queue(inboxes: [work, home], passed: ["w2", "h0"]).map(\.id) == ["h1", "w1"])
        #expect(CatchUp.queue(inboxes: [work, work]).map(\.id) == ["w2", "w1"])
        #expect(CatchUp.queue(inboxes: []).isEmpty)
    }

    @Test func putsInvitationsBeforeTheMail() {
        let invite = CalendarEvent(eventId: "e", calendar: EventCalendar(id: "primary", name: "Me"), title: "Lunch",
                                   start: .now, end: .now, response: .needsAction)
        let items = CatchUp.items(invites: [invite], mail: [thread("a"), thread("b")])
        #expect(items.map(\.id) == ["invite/\(invite.id)", "mail/a", "mail/b"])
    }

    @Test func mapsTheAnswersToGooglesResponses() {
        #expect(CatchUp.Answer.allCases.map(\.title) == ["Accept", "Decline", "Maybe"])
        #expect(CatchUp.Answer.accept.response.rawValue == "accepted")
        #expect(CatchUp.Answer.decline.response.rawValue == "declined")
        #expect(CatchUp.Answer.maybe.response.rawValue == "tentative")
    }

    @Test func handsBackToMailOnceNothingIsLeft() {
        #expect(CatchUp.isDone(items: 0, invitesPending: false, noticeShowing: false))
        #expect(!CatchUp.isDone(items: 1, invitesPending: false, noticeShowing: false))
        #expect(!CatchUp.isDone(items: 0, invitesPending: true, noticeShowing: false))
        #expect(!CatchUp.isDone(items: 0, invitesPending: false, noticeShowing: true))
    }
}

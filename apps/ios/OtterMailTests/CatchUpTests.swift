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

    @Test func queuesEveryInboxNewestFirst() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let work = [thread("w2", mailbox: "work@example.com", date: t + 20), thread("w1", mailbox: "work@example.com", date: t),
                    thread("w0", unread: false, mailbox: "work@example.com", date: t + 99)]
        let home = [thread("h1", mailbox: "home@example.com", date: t + 10), thread("h0", mailbox: "home@example.com", date: t)]
        #expect(CatchUp.queue(inboxes: [work, home]).map(\.id) == ["w2", "h1", "w1", "h0"])
        #expect(CatchUp.queue(inboxes: [home, work]).map(\.id) == ["w2", "h1", "h0", "w1"])
        #expect(CatchUp.queue(inboxes: [work, home], passed: ["w2", "h0"]).map(\.id) == ["h1", "w1"])
        #expect(CatchUp.queue(inboxes: [work, work]).map(\.id) == ["w2", "w1"])
        #expect(CatchUp.queue(inboxes: []).isEmpty)
    }

    /**
     * Threads holds every inbox's cards, the same ones each inbox's pill
     * counts, and a card passed over in one is gone from the other.
     */
    @MainActor @Test func threadsHoldsWhatEveryPillCounts() async {
        let work = Mailbox(email: "work@gmail.com", name: "Me", displayName: "Work", color: "#993366", signature: "", labels: [])
        let home = Mailbox(email: "me@example.com", name: "Me", displayName: "Personal", color: "#336699", signature: "", labels: [])
        let store = MailStore(preferences: Preferences(), mailboxes: [home, work], threads: [
            thread("a"), thread("b", unread: false), thread("w", mailbox: work.email), thread("x", labels: ["SENT"]),
        ])
        let calendar = CalendarStore()
        let dates = CalendarDates()
        await calendar.load(CatchUp.window(dates), sources: [home, work], demo: true, google: GoogleAuth(), dates: dates)
        let state = CatchUpState()
        let scopes = [home.email, work.email]
        let pill = { (scope: String) in state.items(scope: scope, store: store, calendar: calendar, shown: [:], dates: dates) }
        let threads = { state.items(scopes: scopes, store: store, calendar: calendar, shown: [:], dates: dates) }
        let isMail = { (item: CatchUp.Item) in if case .mail = item { true } else { false } }

        let all = threads()
        let each = scopes.flatMap(pill)
        #expect(all.count == each.count)
        #expect(Set(all.map(\.id)) == Set(each.map(\.id)))
        #expect(all.filter(isMail).map(\.id).sorted() == ["mail/a", "mail/w"])
        let firstMail = all.firstIndex(where: isMail) ?? all.count
        #expect(!all[..<firstMail].contains(where: isMail))
        #expect(all[firstMail...].allSatisfy(isMail))

        state.passed.insert("w")
        #expect(threads().count == all.count - 1)
        #expect(!pill(work.email).contains { $0.id == "mail/w" })
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

}

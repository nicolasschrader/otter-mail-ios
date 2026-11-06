import Foundation
import Testing
@testable import Otter_Mail

struct CatchUpTests {
    private func thread(_ id: String, unread: Bool = true, starred: Bool = false, labels: Set<String> = ["INBOX"]) -> MailThread {
        let message = Message(id: "\(id)-m", from: Person(name: "Ann", email: "ann@example.com"), to: [], cc: [], date: .now,
                              text: "", html: nil, attachments: [], unread: unread, starred: starred, draft: false, headers: [:])
        return MailThread(id: id, mailbox: "me@example.com", subject: id, labels: labels, messages: [message])
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
}

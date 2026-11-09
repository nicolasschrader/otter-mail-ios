import Foundation
import Testing
@testable import Otter_Mail

struct AllNewTests {
    private func message(_ id: String, from: String, at date: Date, unread: Bool, labels: Set<String> = ["INBOX"]) -> Message {
        Message(id: id, from: Person(name: from, email: "\(from)@example.com"), to: [], cc: [], date: date,
                text: "", html: nil, attachments: [], unread: unread, starred: false, draft: false, headers: [:], labels: labels)
    }

    @Test func listsBothMailboxesMessagesOneByOneNewestFirstWithReadOnesNotBold() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let home = MailThread(id: "h", mailbox: "me@example.com", subject: "Dinner", labels: ["INBOX"], messages: [
            message("h0", from: "ann", at: t - 10, unread: false, labels: []),
            message("h1", from: "ann", at: t, unread: false),
            message("h2", from: "me", at: t + 10, unread: false),
            message("h3", from: "ann", at: t + 30, unread: true),
        ])
        let work = MailThread(id: "w", mailbox: "work@example.com", subject: "Report", labels: ["INBOX"], messages: [
            message("w1", from: "bob", at: t + 20, unread: false),
        ])
        let entries = AllNew.entries(
            inboxes: [(scope: "me@example.com", threads: [home]), (scope: "work@example.com", threads: [work])],
            mine: ["me@example.com": ["me@example.com"], "work@example.com": ["work@example.com"]]
        )

        #expect(entries.map(\.message.id) == ["h3", "w1", "h1"])
        #expect(entries.map(\.row.unread) == [true, false, false])
        #expect(entries.map(\.row.mailbox) == ["me@example.com", "work@example.com", "me@example.com"])
        #expect(entries.allSatisfy { $0.row.messages.count == 1 })
        #expect(entries.map(\.opened.message) == ["h3", "w1", "h1"])
    }
}

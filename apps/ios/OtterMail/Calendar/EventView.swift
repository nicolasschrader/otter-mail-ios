import SwiftUI

/**
 * One event: when it is, which calendar it's on, where, its meeting link, what
 * it says, and who's coming with their answers. Read-only, like the reader for
 * a message that isn't yours to change.
 */
struct EventView: View {
    @Environment(\.palette) private var palette
    let event: CalendarEvent
    var dates: CalendarDates = CalendarDates()
    var color: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                head
                facts
                if let details {
                    Text(details)
                        .font(.inter(.subheadline))
                        .foregroundStyle(palette.text.opacity(0.85))
                        .textSelection(.enabled)
                }
                if !event.attendees.isEmpty { guests }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(palette.canvas)
        .navigationTitle("Event")
        .toolbarTitleDisplayMode(.inline)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(.inter(.title2).weight(.semibold))
                .foregroundStyle(palette.text)
                .strikethrough(event.status == .cancelled)
            Text(when)
                .font(.inter(.subheadline))
                .foregroundStyle(palette.muted)
            HStack(spacing: 8) {
                chip(event.calendar.name, color: color)
                if event.status != .confirmed {
                    chip(event.status == .cancelled ? "Cancelled" : "Tentative", color: palette.warning)
                }
                if event.recurring {
                    chip("Repeats", color: palette.muted)
                }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let link = event.meetingLink, let meeting = URL(string: link) {
                fact("video", title: Meetings.provider(link).title) {
                    Link("Join", destination: meeting)
                        .font(.inter(.subheadline).weight(.semibold))
                }
            }
            if let location = text(event.location) {
                fact("mappin.and.ellipse", title: location)
            }
            if let organizer = event.organizer {
                fact("person.crop.circle", title: organizer.label, detail: "Organizer")
            }
            if let response = event.response {
                fact(response.symbol, title: response.title, detail: "Your answer")
            }
            if let htmlLink = event.htmlLink.flatMap(URL.init(string:)) {
                fact("calendar", title: "Google Calendar") {
                    Link("Open", destination: htmlLink)
                        .font(.inter(.subheadline).weight(.semibold))
                }
            }
        }
    }

    private var guests: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.attendees.count == 1 ? "1 guest" : "\(event.attendees.count) guests")
                .font(.inter(.footnote))
                .foregroundStyle(palette.muted)
            ForEach(event.attendees) { attendee in
                HStack(spacing: 12) {
                    SenderAvatar(person: attendee.person, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attendee.person.label)
                            .font(.inter(.subheadline))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        if !attendee.person.name.isEmpty {
                            Text(attendee.person.email)
                                .font(.inter(.footnote))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Label(attendee.response.title, systemImage: attendee.response.symbol)
                        .labelStyle(.iconOnly)
                        .font(.inter(.subheadline))
                        .foregroundStyle(attendee.response == .declined ? palette.error : palette.muted)
                        .accessibilityLabel(attendee.response.title)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func chip(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.inter(.footnote)).foregroundStyle(palette.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.text.opacity(0.06), in: .capsule)
    }

    private func fact(_ symbol: String, title: String, detail: String? = nil) -> some View {
        fact(symbol, title: title, detail: detail) { EmptyView() }
    }

    private func fact<Action: View>(
        _ symbol: String,
        title: String,
        detail: String? = nil,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(palette.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.inter(.body))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail).font(.inter(.footnote)).foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .frame(minHeight: 52)
    }

    private var when: String {
        let first = dates.startOfDay(event.start)
        let last = EventDays.endDay(of: event, dates: dates)
        let day = { (date: Date) in self.dates.dayTitle(date) }
        if event.allDay {
            return last > first ? "\(day(first)) – \(day(last))" : "All-day · \(day(first))"
        }
        if last > first {
            return "\(day(first)), \(dates.timeLabel(event.start)) – \(day(last)), \(dates.timeLabel(event.end))"
        }
        let length = CalendarDates.durationLabel(event.end.timeIntervalSince(event.start))
        return "\(day(first)) · \(dates.rangeLabel(event.start, event.end)) · \(length)"
    }

    /** Google's descriptions are often HTML; the reader's plain text does for a calendar. */
    private var details: String? {
        guard let raw = text(event.details) else { return nil }
        return raw.contains("<") && raw.contains(">") ? HTMLText.plain(raw) : raw
    }

    private func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

import SwiftUI

/**
 * One event in a day's list, laid out like the mail rows (ThreadRow): when it
 * is in the gutter, its calendar's color beside that, then the title and a line
 * of where it is. A cancelled event keeps its place, struck through.
 */
struct EventRow: View {
    @Environment(\.palette) private var palette
    let event: CalendarEvent
    /** The day it's listed under, so a longer event can say how far along it is. */
    var day: Date? = nil
    var calendar: Calendar = .current

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.allDay {
                    Text("All day")
                } else {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                    Text(event.end.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(palette.muted.opacity(0.7))
                }
            }
            .font(.inter(.footnote).monospacedDigit())
            .foregroundStyle(palette.muted)
            .frame(width: 62, alignment: .trailing)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.inter(.subheadline).weight(.medium))
                    .foregroundStyle(palette.text)
                    .strikethrough(event.status == .cancelled)
                    .lineLimit(2)
                if let line {
                    Text(line)
                        .font(.inter(.footnote))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if let response = event.response, response != .accepted {
                Image(systemName: response.symbol)
                    .font(.inter(.footnote))
                    .foregroundStyle(palette.muted)
                    .accessibilityLabel(response.title)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        event.calendar.color.map(Color.init(hex:)) ?? palette.action
    }

    private var line: String? {
        var parts: [String] = []
        if event.status == .cancelled { parts.append("Cancelled") }
        if let runs { parts.append(runs) }
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !location.isEmpty {
            parts.append(location)
        } else if let link = event.meetingLink {
            parts.append(Meetings.provider(link).title)
        } else if event.attendees.count > 1 {
            parts.append("\(event.attendees.count) people")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /** "Day 2 of 3" while a longer event runs. */
    private var runs: String? {
        let first = calendar.startOfDay(for: event.start)
        let last = EventDays.lastDay(of: event, calendar: calendar)
        guard last > first, let span = calendar.dateComponents([.day], from: first, to: last).day else { return nil }
        guard let day, let reached = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: day)).day else {
            return "\(span + 1) days"
        }
        return "Day \(reached + 1) of \(span + 1)"
    }
}

/** A day in the week's strip or the month's grid: its number, and a dot for each event. */
struct DayCell: View {
    @Environment(\.palette) private var palette
    let day: Date
    let events: [CalendarEvent]
    var weekday = false
    /** In the month being shown; the days around it fade. */
    var inMonth = true
    var selected = false
    var today = false
    var action: (() -> Void)? = nil

    var body: some View {
        let cell = VStack(spacing: 3) {
            if weekday {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.inter(.caption2))
                    .foregroundStyle(palette.muted)
            }
            Text(day.formatted(.dateTime.day()))
                .font(.inter(.subheadline).weight(today ? .semibold : .regular))
                .foregroundStyle(inMonth ? palette.text : palette.muted.opacity(0.6))
                .monospacedDigit()
                .frame(width: 30, height: 30)
                .background(today ? palette.action.opacity(0.18) : .clear, in: .circle)
            dots
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(selected ? palette.text.opacity(0.1) : .clear, in: .rect(cornerRadius: 12))

        if let action {
            Button(action: action) { cell.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            cell.accessibilityElement(children: .ignore).accessibilityLabel(label)
        }
    }

    private var dots: some View {
        HStack(spacing: 2) {
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                Circle()
                    .fill(event.calendar.color.map(Color.init(hex:)) ?? palette.action)
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 4)
        .opacity(inMonth ? 1 : 0.5)
    }

    private var label: String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return events.isEmpty ? date : "\(date), \(events.count) \(events.count == 1 ? "event" : "events")"
    }
}

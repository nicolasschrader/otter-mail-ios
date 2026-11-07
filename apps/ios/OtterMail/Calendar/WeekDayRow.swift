import SwiftUI

/**
 * A day of the picked week under the month: its name and number, which pick
 * it, beside a compact line for each of its events (time, color, title).
 */
struct WeekDayRow: View {
    @Environment(\.palette) private var palette
    let day: Date
    let events: [CalendarEvent]
    let picked: Bool
    let today: Bool
    let dates: CalendarDates
    let color: (EventCalendar) -> Color
    let onPick: () -> Void
    let onOpen: (CalendarEvent) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPick) {
                VStack(spacing: 1) {
                    Text(dates.weekdayShort(day))
                        .font(.inter(.caption2))
                        .foregroundStyle(palette.muted)
                    Text(day.formatted(.dateTime.day()))
                        .font(.inter(.subheadline).weight(today || picked ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                        .frame(width: 28, height: 28)
                        .background(today ? palette.action.opacity(0.18) : .clear, in: .circle)
                }
                .frame(width: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityAddTraits(picked ? .isSelected : [])

            VStack(alignment: .leading, spacing: 2) {
                if events.isEmpty {
                    Text("No events")
                        .font(.inter(.footnote))
                        .foregroundStyle(palette.muted.opacity(0.7))
                        .frame(height: 26, alignment: .leading)
                }
                // Buttons, not NavigationLinks: the week is one list row, and a row's links all push on any tap in it.
                ForEach(events) { event in
                    Button { onOpen(event) } label: { line(event) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(picked ? palette.text.opacity(0.06) : .clear, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("month-week-\(dates.dayKey(day))")
    }

    private func line(_ event: CalendarEvent) -> some View {
        let tone = EventStyle.tone(of: event)
        let struck = event.status == .cancelled || tone == .declined
        return HStack(spacing: 8) {
            Text(time(event))
                .font(.inter(.caption).monospacedDigit())
                .foregroundStyle(palette.muted)
                .frame(width: 52, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(event.calendar).opacity(tone == .solid ? 1 : 0.45))
                .frame(width: 3, height: 14)
            Text(event.title)
                .font(.inter(.footnote).weight(.medium))
                .foregroundStyle(struck ? palette.muted : palette.text)
                .strikethrough(struck)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func time(_ event: CalendarEvent) -> String {
        switch EventDays.timing(of: event, on: day, dates: dates).kind {
        case .allDay: "All-day"
        case .until: "–\(dates.timeLabel(event.end))"
        case .from, .range: dates.timeLabel(event.start)
        }
    }
}

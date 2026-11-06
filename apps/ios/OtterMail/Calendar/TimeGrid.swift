import Foundation

/**
 * Where a day's events sit in the Day page's hours, ported from the Mac and
 * web apps' apps/web/src/main/calendar/time-grid.tsx: the timed ones by their
 * times, in layoutDay's columns where they overlap and TimedEvent's widths;
 * those all day or a day or more long in the all-day row above.
 */
nonisolated enum TimeGrid {
    struct Placement: Hashable {
        var col: Int
        var cols: Int
    }

    /** TimeGrid's split: all day, or a day or more long, is in the all-day row. */
    static func inAllDayRow(_ event: CalendarEvent) -> Bool {
        event.allDay || event.end.timeIntervalSince(event.start) >= 24 * 3600
    }

    static func timed(_ events: [CalendarEvent], on day: Date, dates: CalendarDates) -> [CalendarEvent] {
        events.filter { !inAllDayRow($0) && EventDays.spans($0, day, dates: dates) }
    }

    static func allDay(_ events: [CalendarEvent], on day: Date, dates: CalendarDates) -> [CalendarEvent] {
        EventDays.sorted(events.filter { inAllDayRow($0) && EventDays.spans($0, day, dates: dates) })
    }

    /**
     * layoutDay: where they overlap, Notion Calendar's way, each cluster's
     * events take a column, a later one laid over the one before, so each
     * keeps more than its share. Keyed by the event's `id`.
     */
    static func columns(_ events: [CalendarEvent]) -> [String: Placement] {
        let sorted = events.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
        var placed: [String: Placement] = [:]
        var cluster: [String] = []
        var columns: [Date] = []
        var clusterEnd = Date.distantPast
        func close() {
            for id in cluster { placed[id]?.cols = columns.count }
            cluster = []
            columns = []
        }
        for event in sorted {
            let end = max(event.end, event.start.addingTimeInterval(20 * 60))
            if event.start >= clusterEnd { close() }
            let col: Int
            if let free = columns.firstIndex(where: { $0 <= event.start }) {
                col = free
                columns[free] = end
            } else {
                col = columns.count
                columns.append(end)
            }
            placed[event.id] = Placement(col: col, cols: 0)
            cluster.append(event.id)
            clusterEnd = max(clusterEnd, end)
        }
        close()
        return placed
    }

    /** TimedEvent's left, as a share of the day's width. */
    static func leading(_ placement: Placement) -> Double {
        Double(placement.col) / Double(placement.cols)
    }

    /** TimedEvent's width: the last column takes what's left, the others half a column more than their share. */
    static func width(_ placement: Placement) -> Double {
        let rest = 1 - leading(placement)
        return placement.col == placement.cols - 1 ? rest : min(rest, 1.5 / Double(placement.cols))
    }

    /**
     * The minutes from the day's midnight it covers on that day, clipped to
     * the day: an event across midnight shows its part on each.
     */
    static func minutes(_ event: CalendarEvent, on day: Date, dates: CalendarDates) -> ClosedRange<Double> {
        let dayStart = dates.startOfDay(day)
        let dayEnd = dates.addDays(dayStart, 1)
        let length = min(dayEnd.timeIntervalSince(dayStart) / 60, 24 * 60)
        let start = max(event.start, dayStart).timeIntervalSince(dayStart) / 60
        let end = min(event.end, dayEnd).timeIntervalSince(dayStart) / 60
        let from = min(max(start, 0), length)
        return from...min(max(end, from), length)
    }

    /**
     * The hour the grid opens at: two before now on today (TimeGrid's
     * openingHour), else the hour before the day's first event, else 8.
     */
    static func openingHour(_ timed: [CalendarEvent], on day: Date, now: Date, dates: CalendarDates) -> Int {
        if dates.sameDay(day, now) { return max(0, dates.calendar.component(.hour, from: now) - 2) }
        let dayStart = dates.startOfDay(day)
        guard let first = timed.map({ max($0.start, dayStart) }).min() else { return 8 }
        return max(0, Int(first.timeIntervalSince(dayStart) / 3600) - 1)
    }
}

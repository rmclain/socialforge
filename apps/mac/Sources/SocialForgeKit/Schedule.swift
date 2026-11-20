import Foundation

/// A calendar day with no time and no time zone: 2026-12-01.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int
    public init(_ year: Int, _ month: Int, _ day: Int) { self.year = year; self.month = month; self.day = day }

    public init(_ date: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// A wall-clock time: 9:00.
public struct LocalTime: Hashable, Comparable, Sendable, Codable {
    public var hour: Int, minute: Int
    public init(_ hour: Int, _ minute: Int = 0) { self.hour = hour; self.minute = minute }
    public static func < (a: LocalTime, b: LocalTime) -> Bool { (a.hour, a.minute) < (b.hour, b.minute) }
}

/// "One Pin every day at 9:00 AM, starting Dec 1, skipping weekends."
public struct ScheduleRule: Sendable, Codable, Equatable {
    public var timeZoneID: String
    public var start: LocalDay
    /// Posting times within a day. More than one means several posts per day.
    public var times: [LocalTime]
    /// Every N days (1 = daily, 7 = weekly).
    public var everyDays: Int
    /// Allowed weekdays, 1 = Sunday ... 7 = Saturday. Empty means all.
    public var weekdays: Set<Int>
    /// Days never used.
    public var skipDays: Set<LocalDay>
    /// When set, only these days are used ("Pick dates"), in order, from `start`.
    public var onlyDays: Set<LocalDay>?
    /// When set, posts go out every N hours from the first time (absolute hours, so a DST change shifts the wall clock).
    public var everyHours: Int?

    public init(timeZoneID: String, start: LocalDay, times: [LocalTime], everyDays: Int = 1,
                weekdays: Set<Int> = [], skipDays: Set<LocalDay> = [], onlyDays: Set<LocalDay>? = nil, everyHours: Int? = nil) {
        self.timeZoneID = timeZoneID; self.start = start; self.times = times
        self.everyDays = everyDays; self.weekdays = weekdays; self.skipDays = skipDays
        self.onlyDays = onlyDays; self.everyHours = everyHours
    }

    public static let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
}

public struct ScheduleSlot: Sendable, Equatable {
    public let day: LocalDay
    public let time: LocalTime
    /// The real instant (UTC) the backend publishes at.
    public let instant: Date
}

public enum ScheduleBuilder {
    public enum BuildError: Error, Equatable {
        case unknownTimeZone(String)
        case noTimes
        case noUsableDays
    }

    /// The first `count` slots of `rule`, strictly after `after` when given
    /// (to append to an existing queue). Wall-clock times are kept across
    /// daylight saving changes: 9:00 stays 9:00 local, so the UTC instant
    /// moves by an hour. A time that does not exist on a spring-forward day
    /// (2:30 AM) moves to the next valid minute, as Calendar does.
    public static func slots(_ rule: ScheduleRule, count: Int, after: Date? = nil) throws(BuildError) -> [ScheduleSlot] {
        guard let zone = TimeZone(identifier: rule.timeZoneID) else { throw .unknownTimeZone(rule.timeZoneID) }
        guard !rule.times.isEmpty else { throw .noTimes }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard var cursor = cal.date(from: DateComponents(year: rule.start.year, month: rule.start.month, day: rule.start.day, hour: 12)) else {
            throw .noUsableDays
        }
        let times = rule.times.sorted()
        if let hours = rule.everyHours, hours > 0 {
            return try hourlySlots(rule, hours: hours, count: count, after: after, cal: cal, zone: zone, first: times[0])
        }
        if let only = rule.onlyDays {
            var out: [ScheduleSlot] = []
            for day in only.sorted() where day >= rule.start && !rule.skipDays.contains(day) {
                for t in times where out.count < count {
                    guard let instant = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: t.hour, minute: t.minute)) else { continue }
                    if let after, instant <= after { continue }
                    out.append(ScheduleSlot(day: day, time: t, instant: instant))
                }
            }
            return out
        }
        let step = max(1, rule.everyDays)
        var out: [ScheduleSlot] = []
        var emptyDays = 0
        while out.count < count {
            let day = LocalDay(cursor, in: zone)
            let weekday = cal.component(.weekday, from: cursor)
            let dayOK = (rule.weekdays.isEmpty || rule.weekdays.contains(weekday)) && !rule.skipDays.contains(day)
            var used = false
            if dayOK {
                for t in times where out.count < count {
                    let comps = DateComponents(year: day.year, month: day.month, day: day.day, hour: t.hour, minute: t.minute)
                    guard let instant = cal.date(from: comps) else { continue }
                    if let after, instant <= after { continue }
                    out.append(ScheduleSlot(day: day, time: t, instant: instant))
                    used = true
                }
            }
            emptyDays = used ? 0 : emptyDays + 1
            // A rule that allows no day at all would loop forever.
            if emptyDays > 3_700 { throw .noUsableDays }
            cursor = cal.date(byAdding: .day, value: step, to: cursor)!
        }
        return out
    }

    private static func hourlySlots(_ rule: ScheduleRule, hours: Int, count: Int, after: Date?, cal: Calendar, zone: TimeZone,
                                    first: LocalTime) throws(BuildError) -> [ScheduleSlot] {
        guard var instant = cal.date(from: DateComponents(year: rule.start.year, month: rule.start.month, day: rule.start.day,
                                                          hour: first.hour, minute: first.minute)) else { throw .noUsableDays }
        var out: [ScheduleSlot] = []
        var guardCount = 0
        while out.count < count {
            let day = LocalDay(instant, in: zone)
            let weekday = cal.component(.weekday, from: instant)
            let ok = (rule.weekdays.isEmpty || rule.weekdays.contains(weekday)) && !rule.skipDays.contains(day) && (after.map { instant > $0 } ?? true)
            if ok {
                let c = cal.dateComponents([.hour, .minute], from: instant)
                out.append(ScheduleSlot(day: day, time: LocalTime(c.hour ?? 0, c.minute ?? 0), instant: instant))
            }
            guardCount += 1
            if guardCount > 100_000 { throw .noUsableDays }
            instant = instant.addingTimeInterval(Double(hours) * 3600)
        }
        return out
    }
}

/// The time a post starts with when someone picks a day on the calendar.
public enum CalendarSlot {
    /// 9:00 on `day`, or the next full hour when 9:00 has already passed today.
    /// `nil` for a day before today: posts are not scheduled in the past.
    public static func defaultTime(on day: Date, now: Date = .now, calendar: Calendar = .current,
                                   preferred: LocalTime = LocalTime(9)) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard start >= calendar.startOfDay(for: now) else { return nil }
        if let nine = calendar.date(bySettingHour: preferred.hour, minute: preferred.minute, second: 0, of: start), nine > now {
            return nine
        }
        // Today, after 9:00: the next full hour, if it is still today.
        guard let hour = calendar.dateInterval(of: .hour, for: now)?.end,
              calendar.isDate(hour, inSameDayAs: now) else { return nil }
        return hour
    }
}

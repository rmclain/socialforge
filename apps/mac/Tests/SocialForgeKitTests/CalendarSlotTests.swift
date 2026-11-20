import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Double-clicking a calendar day")
struct CalendarSlotTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func aFutureDayStartsAtNine() {
        let t = CalendarSlot.defaultTime(on: date(2026, 12, 3, 15), now: date(2026, 11, 19, 14), calendar: cal)
        #expect(t == date(2026, 12, 3, 9))
    }

    @Test func todayBeforeNineIsNine() {
        #expect(CalendarSlot.defaultTime(on: date(2026, 11, 19), now: date(2026, 11, 19, 7, 30), calendar: cal) == date(2026, 11, 19, 9))
    }

    @Test func todayAfterNineIsTheNextHour() {
        #expect(CalendarSlot.defaultTime(on: date(2026, 11, 19), now: date(2026, 11, 19, 14, 20), calendar: cal) == date(2026, 11, 19, 15))
    }

    @Test func lateTonightHasNoSlotLeft() {
        #expect(CalendarSlot.defaultTime(on: date(2026, 11, 19), now: date(2026, 11, 19, 23, 30), calendar: cal) == nil)
    }

    @Test func aPastDayIsRefused() {
        #expect(CalendarSlot.defaultTime(on: date(2026, 11, 18, 12), now: date(2026, 11, 19, 8), calendar: cal) == nil)
    }

    @Test func nineAMOnTheDaylightSavingDayIsWallClockNine() {
        // US clocks spring forward on 2027-03-14.
        let t = CalendarSlot.defaultTime(on: date(2027, 3, 14), now: date(2027, 3, 1), calendar: cal)!
        #expect(cal.component(.hour, from: t) == 9)
    }
}

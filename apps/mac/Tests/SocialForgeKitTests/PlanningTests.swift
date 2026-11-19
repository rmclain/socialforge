import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Sidebar pages")
struct PageTests {
    @Test("Every page has a title, symbol and section", arguments: AppPage.allCases)
    func complete(page: AppPage) {
        #expect(!page.title.isEmpty)
        #expect(!page.symbol.isEmpty)
        #expect(AppPage.Section.allCases.contains(page.section))
    }

    @Test func thirteenPagesInOrder() {
        #expect(AppPage.allCases.count == 13)
        #expect(AppPage.allCases.first == .home)
        #expect(AppPage.allCases.last == .settings)
    }
}

@Suite("CSV parsing")
struct CSVTests {
    @Test func quotedFieldsWithCommasQuotesAndNewlines() throws {
        let text = "\u{FEFF}filename,title,description\r\n" +
            "mug.jpg,\"Mug, Fog\",\"Line one\nLine \"\"two\"\"\"\r\n" +
            "plate.png,Plate,\n\n"
        let t = try CSVTable.parse(text)
        #expect(t.header == ["filename", "title", "description"])
        #expect(t.rows.count == 2)
        #expect(t.rows[0] == ["mug.jpg", "Mug, Fog", "Line one\nLine \"two\""])
        #expect(t.rows[1] == ["plate.png", "Plate", ""])
    }

    @Test func shortRowsArePadded() throws {
        let t = try CSVTable.parse("a,b,c\n1\n")
        #expect(t.rows == [["1", "", ""]])
    }

    @Test func unterminatedQuoteFails() {
        #expect(throws: CSVTable.ParseError.unterminatedQuote(line: 2)) { try CSVTable.parse("a\n\"open") }
    }

    @Test func emptyFails() {
        #expect(throws: CSVTable.ParseError.empty) { try CSVTable.parse("\n\n") }
    }
}

@Suite("Matching media to CSV rows")
struct MatchingTests {
    let table = try! CSVTable.parse("""
    File Name,SKU,Product URL,Title
    OE-Winter-01.JPG,,https://oakandember.com/products/mug,Stoneware Mug
    ,OE-THROW-CLAY,https://oakandember.com/products/throw,Linen Throw
    oe-winter-03.png,,not a url,Beeswax Tapers
    """)

    @Test func guessesColumns() {
        let m = ColumnMapping.guess(from: table.header)
        #expect(m.file == "File Name")
        #expect(m.sku == "SKU")
        #expect(m.url == "Product URL")
        #expect(m.title == "Title")
    }

    @Test func filenameIgnoresCaseAndExtensionThenSKU() {
        let media = [MatchCandidate(id: "a", filename: "oe-winter-01.jpg"),
                     MatchCandidate(id: "b", filename: "photo_oe-throw-clay_final.heic"),
                     MatchCandidate(id: "c", filename: "oe-winter-03.jpeg"),
                     MatchCandidate(id: "d", filename: "unrelated.png")]
        let r = MetadataMatcher.match(media: media, table: table, mapping: .guess(from: table.header), strategy: .filename)
        #expect(r.matched.map(\.mediaID) == ["a", "b", "c"])
        #expect(r.matched[0].url == "https://oakandember.com/products/mug")
        #expect(r.matched[1].title == "Linen Throw")
        #expect(r.unmatchedMedia == ["d"])
        #expect(r.unmatchedRows.isEmpty)
        #expect(r.rowWarnings["c"]?.first?.contains("not an http") == true)
    }

    @Test func twoImagesClaimingOneRowAreAmbiguous() {
        let media = [MatchCandidate(id: "a", filename: "oe-winter-01.jpg"),
                     MatchCandidate(id: "b", filename: "OE-WINTER-01.png")]
        let r = MetadataMatcher.match(media: media, table: table, mapping: .guess(from: table.header), strategy: .filename)
        #expect(r.matched.isEmpty)
        #expect(r.ambiguous["a"] == [0])
        #expect(r.ambiguous["b"] == [0])
        #expect(!r.unmatchedRows.contains(0))
    }

    @Test func oneImageMatchingTwoRowsIsAmbiguous() throws {
        let t = try CSVTable.parse("filename,url\nmug.jpg,https://a.example\nmug.png,https://b.example\n")
        let r = MetadataMatcher.match(media: [MatchCandidate(id: "m", filename: "mug.webp")], table: t,
                                      mapping: .guess(from: t.header), strategy: .filename)
        #expect(r.ambiguous["m"] == [0, 1])
        #expect(r.matched.isEmpty)
    }

    @Test func rowOrderPairsInOrder() {
        let media = (1...4).map { MatchCandidate(id: "\($0)", filename: "x\($0).jpg") }
        let r = MetadataMatcher.match(media: media, table: table, mapping: .guess(from: table.header), strategy: .rowOrder)
        #expect(r.matched.map(\.rowIndex) == [0, 1, 2])
        #expect(r.unmatchedMedia == ["4"])
    }
}

@Suite("Schedules")
struct ScheduleTests {
    let ny = "America/New_York"

    func local(_ slot: ScheduleSlot, _ zone: String) -> (Int, Int, Int, Int, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: slot.instant)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    @Test func thirtyDailyAtNine() throws {
        let rule = ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 12, 1), times: [LocalTime(9)])
        let slots = try ScheduleBuilder.slots(rule, count: 30)
        #expect(slots.count == 30)
        #expect(slots.first?.day == LocalDay(2026, 12, 1))
        #expect(slots.last?.day == LocalDay(2026, 12, 30))
        for s in slots { #expect(local(s, ny).3 == 9 && local(s, ny).4 == 0) }
    }

    @Test("9:00 stays 9:00 local across both DST changes")
    func dst() throws {
        let fall = try ScheduleBuilder.slots(ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 10, 31), times: [LocalTime(9)]), count: 2)
        #expect(local(fall[0], ny).3 == 9 && local(fall[1], ny).3 == 9)
        #expect(fall[1].instant.timeIntervalSince(fall[0].instant) == 25 * 3600)

        let spring = try ScheduleBuilder.slots(ScheduleRule(timeZoneID: ny, start: LocalDay(2027, 3, 13), times: [LocalTime(9)]), count: 2)
        #expect(local(spring[1], ny).3 == 9)
        #expect(spring[1].instant.timeIntervalSince(spring[0].instant) == 23 * 3600)
    }

    @Test func missingSpringForwardTimeMovesLater() throws {
        let s = try ScheduleBuilder.slots(ScheduleRule(timeZoneID: ny, start: LocalDay(2027, 3, 14), times: [LocalTime(2, 30)]), count: 1)
        #expect(local(s[0], ny).3 == 3)
    }

    @Test func skipsWeekendsAndDates() throws {
        // Dec 1 2026 is a Tuesday.
        let rule = ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 12, 1), times: [LocalTime(9)],
                                weekdays: ScheduleRule.weekdaysOnly, skipDays: [LocalDay(2026, 12, 2)])
        let days = try ScheduleBuilder.slots(rule, count: 5).map(\.day)
        #expect(days == [LocalDay(2026, 12, 1), LocalDay(2026, 12, 3), LocalDay(2026, 12, 4), LocalDay(2026, 12, 7), LocalDay(2026, 12, 8)])
    }

    @Test func severalPerDayAndEveryOtherDay() throws {
        let rule = ScheduleRule(timeZoneID: "Europe/Berlin", start: LocalDay(2026, 12, 1),
                                times: [LocalTime(20, 30), LocalTime(8)], everyDays: 2)
        let s = try ScheduleBuilder.slots(rule, count: 4)
        #expect(s.map(\.day) == [LocalDay(2026, 12, 1), LocalDay(2026, 12, 1), LocalDay(2026, 12, 3), LocalDay(2026, 12, 3)])
        #expect(s.map(\.time) == [LocalTime(8), LocalTime(20, 30), LocalTime(8), LocalTime(20, 30)])
    }

    @Test func appendsAfterExistingQueue() throws {
        let rule = ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 12, 1), times: [LocalTime(9)])
        let existing = try ScheduleBuilder.slots(rule, count: 10)
        let more = try ScheduleBuilder.slots(rule, count: 3, after: existing.last!.instant)
        #expect(more.map(\.day) == [LocalDay(2026, 12, 11), LocalDay(2026, 12, 12), LocalDay(2026, 12, 13)])
    }

    @Test func errors() {
        #expect(throws: ScheduleBuilder.BuildError.unknownTimeZone("Mars/Base")) {
            try ScheduleBuilder.slots(ScheduleRule(timeZoneID: "Mars/Base", start: LocalDay(2026, 1, 1), times: [LocalTime(9)]), count: 1)
        }
        #expect(throws: ScheduleBuilder.BuildError.noTimes) {
            try ScheduleBuilder.slots(ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 1, 1), times: []), count: 1)
        }
        #expect(throws: ScheduleBuilder.BuildError.noUsableDays) {
            try ScheduleBuilder.slots(ScheduleRule(timeZoneID: ny, start: LocalDay(2026, 1, 1), times: [LocalTime(9)], weekdays: [9]), count: 1)
        }
    }
}

@Suite("Schedules: hours and picked dates")
struct ScheduleExtraTests {
    @Test func everyFourHours() throws {
        let rule = ScheduleRule(timeZoneID: "UTC", start: LocalDay(2026, 12, 1), times: [LocalTime(8)], everyHours: 4)
        let s = try ScheduleBuilder.slots(rule, count: 5)
        #expect(s.map(\.time) == [LocalTime(8), LocalTime(12), LocalTime(16), LocalTime(20), LocalTime(0)])
        #expect(s[4].day == LocalDay(2026, 12, 2))
    }

    @Test func pickedDatesOnly() throws {
        let days: Set<LocalDay> = [LocalDay(2026, 12, 9), LocalDay(2026, 12, 3), LocalDay(2026, 11, 20)]
        let rule = ScheduleRule(timeZoneID: "America/New_York", start: LocalDay(2026, 12, 1), times: [LocalTime(9)], onlyDays: days)
        let s = try ScheduleBuilder.slots(rule, count: 10)
        #expect(s.map(\.day) == [LocalDay(2026, 12, 3), LocalDay(2026, 12, 9)])
    }
}

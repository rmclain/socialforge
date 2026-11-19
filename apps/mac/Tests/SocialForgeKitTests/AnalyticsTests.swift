import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Analytics")
struct AnalyticsTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    func day(_ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 5, day: d, hour: h))! }

    @Test func summarizes() throws {
        let rows = [
            PostRecord(platform: "pinterest", status: "published", scheduledAt: day(1), publishedAt: day(1, 13), campaign: "winter"),
            PostRecord(platform: "pinterest", status: "failed", scheduledAt: day(2), campaign: "winter"),
            PostRecord(platform: "x", status: "scheduled", scheduledAt: day(3)),
            PostRecord(platform: "x", status: "approved", scheduledAt: day(3)),
            PostRecord(platform: "pinterest", status: "needsReview", scheduledAt: day(2)),
            PostRecord(platform: "pinterest", status: "published", scheduledAt: day(20), publishedAt: day(20)),  // out of range
        ]
        let s = Analytics.summarize(rows, from: day(1, 0), to: day(3, 23), calendar: cal)
        #expect(s.total == 5)
        #expect(s.published == 1 && s.failed == 1 && s.needsReview == 1 && s.scheduled == 2)
        #expect(s.byPlatform == ["pinterest": 3, "x": 2])
        #expect(s.byStatus["approved"] == 1)
        #expect(s.successRate == 0.5)
        #expect(s.perDay == [
            DayCount(day: day(1, 0), published: 1, scheduled: 0),
            DayCount(day: day(2, 0), published: 0, scheduled: 0),
            DayCount(day: day(3, 0), published: 0, scheduled: 2),
        ])

        let filtered = Analytics.summarize(rows, from: day(1, 0), to: day(3, 23), calendar: cal, platform: "pinterest", campaign: "winter")
        #expect(filtered.total == 2)
        #expect(Analytics.summarize([], from: day(1), to: day(1), calendar: cal).successRate == nil)
    }

    @Test func csvQuotesAndDates() {
        let rows = [PostRecord(platform: "pinterest", status: "published", scheduledAt: Date(timeIntervalSince1970: 0),
                               publishedAt: nil, campaign: "Say \"hi\", friends", account: "line\nbreak")]
        let csv = Analytics.csv(rows)
        #expect(csv == "platform,status,scheduled_at,published_at,campaign,account\r\n"
            + "pinterest,published,1970-01-01T00:00:00.000Z,,\"Say \"\"hi\"\", friends\",\"line\nbreak\"\r\n")
        let parsed = try? CSVTable.parse(csv)
        #expect(parsed?.rows.first?[4] == "Say \"hi\", friends")
    }
}

@Suite("UTM links")
struct UTMTests {
    @Test func addsAndReplaces() {
        let out = UTM.apply(to: "https://shop.example/p/mug?color=red&utm_source=old&UTM_term=x#reviews",
                            source: "pinterest", medium: "social", campaign: "Winter & Tea", content: "pin 1")
        #expect(out == "https://shop.example/p/mug?color=red&utm_source=pinterest&utm_medium=social&utm_campaign=Winter%20%26%20Tea&utm_content=pin%201#reviews")
        let items = URLComponents(string: out)?.queryItems ?? []
        #expect(items.first { $0.name == "utm_campaign" }?.value == "Winter & Tea")
    }

    @Test func plainURLAndNonHTTP() {
        #expect(UTM.apply(to: "http://a.example", source: "x", medium: "social", campaign: "c") == "http://a.example?utm_source=x&utm_medium=social&utm_campaign=c")
        #expect(UTM.apply(to: "mailto:a@b.example", source: "x", medium: "m", campaign: "c") == "mailto:a@b.example")
        #expect(UTM.apply(to: "not a url", source: "x", medium: "m", campaign: "c") == "not a url")
        #expect(UTM.apply(to: "", source: "x", medium: "m", campaign: "c") == "")
    }
}

import Foundation

/// One post, as the analytics page sees it. `status` is the app's raw value:
/// draft, needsReview, approved, scheduled, preparing, publishing, published, failed, paused, canceled.
public struct PostRecord: Sendable, Equatable {
    public var platform: String
    public var status: String
    public var scheduledAt: Date
    public var publishedAt: Date?
    public var campaign: String?
    public var account: String?

    public init(platform: String, status: String, scheduledAt: Date, publishedAt: Date? = nil, campaign: String? = nil, account: String? = nil) {
        self.platform = platform; self.status = status; self.scheduledAt = scheduledAt
        self.publishedAt = publishedAt; self.campaign = campaign; self.account = account
    }
}

/// Posts on one calendar day: published that day, and still waiting to go out that day.
public struct DayCount: Sendable, Equatable, Hashable {
    public var day: Date
    public var published: Int
    public var scheduled: Int
    public init(day: Date, published: Int, scheduled: Int) { self.day = day; self.published = published; self.scheduled = scheduled }
}

public struct AnalyticsSummary: Sendable, Equatable {
    public var total: Int
    /// approved + scheduled + preparing + publishing
    public var scheduled: Int
    public var published: Int
    public var failed: Int
    public var needsReview: Int
    public var byPlatform: [String: Int]
    public var byStatus: [String: Int]
    /// Every day from `from` to `to`, including days with nothing.
    public var perDay: [DayCount]
    /// published / (published + failed). Nil when neither happened.
    public var successRate: Double?

    public init(total: Int, scheduled: Int, published: Int, failed: Int, needsReview: Int, byPlatform: [String: Int],
                byStatus: [String: Int], perDay: [DayCount], successRate: Double?) {
        self.total = total; self.scheduled = scheduled; self.published = published; self.failed = failed; self.needsReview = needsReview
        self.byPlatform = byPlatform; self.byStatus = byStatus; self.perDay = perDay; self.successRate = successRate
    }
}

public enum Analytics {
    static let waitingStatuses: Set<String> = ["approved", "scheduled", "preparing", "publishing"]

    /// Posts whose scheduled or published time falls between `from` and `to` (inclusive),
    /// optionally for one platform or campaign.
    public static func summarize(_ records: [PostRecord], from: Date, to: Date, calendar: Calendar = .current,
                                 platform: String? = nil, campaign: String? = nil) -> AnalyticsSummary {
        let range = min(from, to)...max(from, to)
        let rows = records.filter { r in
            (platform == nil || r.platform == platform) && (campaign == nil || r.campaign == campaign)
                && (range.contains(r.scheduledAt) || r.publishedAt.map(range.contains) == true)
        }

        var byPlatform: [String: Int] = [:], byStatus: [String: Int] = [:]
        var publishedPerDay: [Date: Int] = [:], scheduledPerDay: [Date: Int] = [:]
        for r in rows {
            byPlatform[r.platform, default: 0] += 1
            byStatus[r.status, default: 0] += 1
            if r.status == "published" {
                let when = r.publishedAt ?? r.scheduledAt
                if range.contains(when) { publishedPerDay[calendar.startOfDay(for: when), default: 0] += 1 }
            } else if waitingStatuses.contains(r.status), range.contains(r.scheduledAt) {
                scheduledPerDay[calendar.startOfDay(for: r.scheduledAt), default: 0] += 1
            }
        }

        var perDay: [DayCount] = []
        var day = calendar.startOfDay(for: range.lowerBound)
        let last = calendar.startOfDay(for: range.upperBound)
        while day <= last {
            perDay.append(DayCount(day: day, published: publishedPerDay[day] ?? 0, scheduled: scheduledPerDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let published = byStatus["published"] ?? 0
        let failed = byStatus["failed"] ?? 0
        return AnalyticsSummary(
            total: rows.count,
            scheduled: waitingStatuses.reduce(0) { $0 + (byStatus[$1] ?? 0) },
            published: published,
            failed: failed,
            needsReview: byStatus["needsReview"] ?? 0,
            byPlatform: byPlatform,
            byStatus: byStatus,
            perDay: perDay,
            successRate: published + failed > 0 ? Double(published) / Double(published + failed) : nil
        )
    }

    /// RFC 4180 CSV with a header row and CRLF line ends. Dates are ISO 8601 in UTC.
    public static func csv(_ records: [PostRecord]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["platform,status,scheduled_at,published_at,campaign,account"]
        for r in records {
            lines.append([r.platform, r.status, ISO8601.format(r.scheduledAt), r.publishedAt.map(ISO8601.format) ?? "",
                          r.campaign ?? "", r.account ?? ""].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

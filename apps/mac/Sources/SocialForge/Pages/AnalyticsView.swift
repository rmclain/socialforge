import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

@Observable
final class AnalyticsFilter {
    var days = 30
    var platform: String?
    var campaign: UUID?
}

struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query(sort: \AIJob.createdAt) private var allJobs: [AIJob]
    @Query(sort: \Campaign.name) private var campaigns: [Campaign]
    @State private var filter = AnalyticsFilter()

    private var records: [PostRecord] {
        allPubs.filter { $0.workspaceID == model.workspaceID && (filter.campaign == nil || $0.campaignID == filter.campaign) }.map { p in
            PostRecord(platform: p.platform, status: p.statusRaw, scheduledAt: p.scheduledAt,
                       publishedAt: p.status == .published ? p.updatedAt : nil,
                       campaign: campaigns.first(where: { $0.uuid == p.campaignID })?.name, account: p.accountName)
        }
    }

    private var range: (Date, Date) {
        let cal = Calendar.current
        // The last N days and the next N days: what happened and what is queued.
        let today = cal.startOfDay(for: .now)
        return (cal.date(byAdding: .day, value: -filter.days, to: today)!, cal.date(byAdding: .day, value: filter.days + 1, to: today)!)
    }

    var body: some View {
        let (from, to) = range
        let s = Analytics.summarize(records, from: from, to: to, platform: filter.platform)
        let jobs = allJobs.filter { $0.workspaceID == model.workspaceID && $0.createdAt >= from && $0.createdAt <= to }
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text("Publishing activity").font(DS.display(30))
                    Spacer()
                    PillPicker(options: [7, 30, 90], selection: $filter.days) { "±\($0) days" }
                    Picker("", selection: $filter.platform) {
                        Text("All platforms").tag(String?.none)
                        ForEach(PlatformRegistry.all) { Text($0.name).tag(String?.some($0.platform)) }
                    }
                    .labelsHidden().fixedSize()
                    Picker("", selection: $filter.campaign) {
                        Text("All campaigns").tag(UUID?.none)
                        ForEach(campaigns.filter { $0.workspaceID == model.workspaceID }) { Text($0.name).tag(UUID?.some($0.uuid)) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Export CSV…") { exportCSV() }.buttonStyle(SecondaryButtonStyle())
                }
                Text("\(from.formatted(date: .abbreviated, time: .omitted)) – \(to.formatted(date: .abbreviated, time: .omitted)). Counts come from this workspace's posts; nothing is estimated.")
                    .font(DS.small).foregroundStyle(DS.text2)
                HStack(spacing: Space.md) {
                    stat("Scheduled", s.scheduled, DS.accent)
                    stat("Published", s.published, DS.green)
                    stat("Failed", s.failed, DS.red)
                    stat("Needs review", s.needsReview, DS.amber)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Success rate").font(DS.small).foregroundStyle(DS.text2)
                        Text(s.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Posts per day").font(.system(size: 15, weight: .semibold))
                    Chart {
                        ForEach(s.perDay, id: \.day) { d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Posts", d.scheduled), stacking: .standard)
                                .foregroundStyle(by: .value("Kind", "Scheduled"))
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Posts", d.published), stacking: .standard)
                                .foregroundStyle(by: .value("Kind", "Published"))
                        }
                        RuleMark(x: .value("Today", Date.now, unit: .day)).foregroundStyle(DS.text3).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    .chartForegroundStyleScale(["Scheduled": DS.accent.opacity(0.7), "Published": DS.green])
                    .frame(height: 220)
                }
                .card(padding: Space.xl)
                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("By platform").font(.system(size: 15, weight: .semibold))
                        if s.byPlatform.isEmpty { Text("No posts in this period.").foregroundStyle(DS.text2) }
                        ForEach(s.byPlatform.sorted { $0.value > $1.value }, id: \.key) { p, n in
                            HStack {
                                PlatformBadge(platform: p, size: 18)
                                Text(PlatformRegistry.spec(p)?.name ?? p).font(DS.body)
                                Spacer()
                                Text("\(n)").font(DS.bodyMedium).monospacedDigit()
                            }
                            ThinProgress(segments: [(Double(n) / Double(max(1, s.total)), Color(hex: PlatformBadge.color(p)))])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).card(padding: Space.xl)
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("By status").font(.system(size: 15, weight: .semibold))
                        ForEach(s.byStatus.sorted { $0.value > $1.value }, id: \.key) { k, n in
                            let st = PublicationStatus(rawValue: k) ?? .draft
                            HStack { StatusChip(status: st); Spacer(); Text("\(n)").font(DS.bodyMedium).monospacedDigit() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).card(padding: Space.xl)
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("AI usage").font(.system(size: 15, weight: .semibold))
                        KeyValueRow("Requests", "\(jobs.count)")
                        KeyValueRow("Images made", "\(jobs.reduce(0) { $0 + $1.outputAssetIDs.count })")
                        KeyValueRow("Tokens in / out", "\(jobs.reduce(0) { $0 + $1.inputTokens }) / \(jobs.reduce(0) { $0 + $1.outputTokens })")
                        KeyValueRow("Cost", "Not shown: providers bill you directly")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading).card(padding: Space.xl)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Engagement").font(.system(size: 15, weight: .semibold))
                    Text("Impressions, saves, outbound clicks, and engagement rate need each platform's analytics permission and a verified live connection. They show as unavailable until then; SocialForge never estimates them.")
                        .font(DS.body).foregroundStyle(DS.text2)
                    HStack(spacing: Space.md) {
                        ForEach(["Impressions", "Saves", "Outbound clicks", "Engagement rate"], id: \.self) { m in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(m).font(DS.small).foregroundStyle(DS.text2)
                                Text("Unavailable").font(DS.bodyMedium).foregroundStyle(DS.text3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                    }
                }
            }
            .padding(Space.xxl)
        }
    }

    private func stat(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(DS.small).foregroundStyle(color)
            Text("\(n)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SocialForge posts.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Analytics.csv(records).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct AnalyticsInspector: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.updatedAt, order: .reverse) private var pubs: [Publication]

    var body: some View {
        let recent = pubs.filter { $0.workspaceID == model.workspaceID && ($0.status == .published || $0.status == .failed) }.prefix(12)
        VStack(spacing: 0) {
            PanelHeader(title: "Recent results")
            Divider().overlay(DS.stroke)
            InspectorScroll {
                if recent.isEmpty { Text("Published and failed posts appear here with their links and errors.").font(DS.body).foregroundStyle(DS.text2) }
                ForEach(Array(recent)) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { PlatformBadge(platform: p.platform, size: 16); Text(p.title).font(DS.bodyMedium).lineLimit(1); Spacer(); StatusChip(status: p.status) }
                        if let u = p.publishedURL, let url = URL(string: u) { Link(u.replacingOccurrences(of: "https://", with: ""), destination: url).font(DS.small).lineLimit(1) }
                        if let e = p.lastError, p.status == .failed { Text(e).font(DS.small).foregroundStyle(DS.red).lineLimit(2) }
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }
}

import SwiftData
import SwiftUI
import SocialForgeKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query(sort: \ActivityEntry.at, order: .reverse) private var allActivity: [ActivityEntry]
    @State private var activityFilter = "all"
    @AppStorage("home.checklist.dismissed") private var checklistDismissed = false

    private var pubs: [Publication] { allPubs.filter { $0.workspaceID == model.workspaceID } }
    private var upcoming: [Publication] {
        pubs.filter { [.scheduled, .preparing, .uploading, .awaitingProcessing, .publishing, .verifying].contains($0.status) && $0.scheduledAt >= .now }
    }
    private var approvedUnscheduled: [Publication] {
        pubs.filter { $0.status == .approved }
    }
    private var review: [Publication] { pubs.filter { $0.status == .needsReview } }
    private var attention: [Publication] { pubs.filter { [.failed, .authRequired, .actionRequired, .outcomeUnknown].contains($0.status) } }
    private var badAccounts: [SocialAccount] {
        model.accounts.filter { [.reauthRequired, .revoked, .missingPermissions, .configurationError].contains($0.connectionStatus) }
    }
    private var activity: [ActivityEntry] {
        Array(allActivity.filter {
            $0.workspaceID == model.workspaceID && (activityFilter == "all" || $0.category == activityFilter)
        }.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(DS.body).foregroundStyle(DS.text2)
                    Text(greeting).font(.system(size: 32, weight: .semibold)).foregroundStyle(DS.text)
                    Text(summary).font(.system(size: 15)).foregroundStyle(DS.text2)
                }
                .gridProbe("home.title", area: "home")

                if !badAccounts.isEmpty || !attention.isEmpty || !approvedUnscheduled.isEmpty {
                    HStack(spacing: Space.md) {
                        if !badAccounts.isEmpty {
                            attentionBanner(
                                title: "\(badAccounts.count) connection\(badAccounts.count == 1 ? "" : "s") need\(badAccounts.count == 1 ? "s" : "") attention",
                                detail: badAccounts.map(\.name).joined(separator: ", "),
                                color: DS.red, action: "Open Connections"
                            ) { model.page = .accounts }
                        }
                        if !attention.isEmpty {
                            attentionBanner(
                                title: "\(attention.count) post\(attention.count == 1 ? "" : "s") need\(attention.count == 1 ? "s" : "") attention",
                                detail: attention.first?.lastError ?? "Check failures or unknown outcomes.",
                                color: DS.amber, action: "Open Queue"
                            ) {
                                model.publicationSelection = [attention[0].id]
                                model.page = .calendar
                            }
                        }
                        if !approvedUnscheduled.isEmpty {
                            attentionBanner(
                                title: "\(approvedUnscheduled.count) approved (not yet scheduled)",
                                detail: "Approved posts wait until you schedule them.",
                                color: DS.accent, action: "Schedule All"
                            ) { Task { _ = await model.activate(approvedUnscheduled) } }
                        }
                    }
                    .gridProbe("home.attention", area: "home")
                }

                if !checklistDismissed && (model.accounts.isEmpty || pubs.isEmpty) {
                    setupChecklist
                        .gridProbe("home.checklist", area: "home")
                }

                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text("Up next").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("Open calendar") { model.page = .calendar }.buttonStyle(LinkButtonStyle())
                    }
                    if upcoming.isEmpty {
                        HStack {
                            Text("Nothing scheduled yet. Start a bulk run or write a post.").foregroundStyle(DS.text2)
                            Spacer()
                            Button("Bulk Publisher") { model.page = .bulk }.buttonStyle(SecondaryButtonStyle())
                        }
                        .card()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: Space.lg) {
                                ForEach(upcoming.prefix(8)) { p in UpNextTile(pub: p) }
                            }
                        }
                    }
                }
                .gridProbe("home.upnext", area: "home")

                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Awaiting approval").font(.system(size: 15, weight: .semibold)).padding(.bottom, Space.md)
                        if review.isEmpty {
                            Text("Nothing is waiting for you.").foregroundStyle(DS.text2)
                        }
                        ForEach(Array(review.prefix(5).enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Divider().overlay(DS.stroke) }
                            ApprovalRow(pub: p)
                        }
                        if review.count > 5 {
                            Button("\(review.count - 5) more in Bulk Publisher") { model.page = .bulk }.buttonStyle(LinkButtonStyle()).padding(.top, Space.md)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .card(padding: Space.xl)

                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack {
                            Text("Activity").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Picker("", selection: $activityFilter) {
                                Text("All").tag("all")
                                Text("Publishing").tag("publishing")
                                Text("Connections").tag("connection")
                                Text("Agents").tag("agent")
                            }
                            .labelsHidden().fixedSize()
                        }
                        if activity.isEmpty {
                            Text("Imports, schedules, and results show up here.").foregroundStyle(DS.text2)
                        }
                        ForEach(activity) { a in
                            HStack(alignment: .top, spacing: Space.md) {
                                Circle().fill(dotColor(a.symbol)).frame(width: 8, height: 8).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.text).font(DS.body).foregroundStyle(DS.textBody).lineLimit(2)
                                    Text(a.at.formatted(.relative(presentation: .named))).font(DS.small).foregroundStyle(DS.text3)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .card(padding: Space.xl)
                }
                .gridProbe("home.cards", area: "home")
            }
            .padding(Space.xxl + Space.sm)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridArea("home")
        }
    }

    private func attentionBanner(title: String, detail: String, color: Color, action: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(DS.bodyMedium)
            }
            Text(detail).font(DS.small).foregroundStyle(DS.text2).lineLimit(2)
            Button(action, action: run).buttonStyle(LinkButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.md)
    }

    private var setupChecklist: some View {
        let hasBrand = model.brandKit != nil
        let hasAccount = !model.accounts.isEmpty
        let hasAI = AIProviderID.allCases.contains { model.isConfigured($0) }
        let hasPost = !pubs.isEmpty
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Quick Setup Checklist").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Dismiss") { checklistDismissed = true }.buttonStyle(.plain).font(DS.small).foregroundStyle(DS.text3)
            }
            HStack(spacing: Space.md) {
                checkStep("Brand kit", done: hasBrand) { model.page = .brandKits }
                checkStep("Social account", done: hasAccount) { model.page = .accounts }
                checkStep("AI or ComfyUI", done: hasAI) { model.page = .accounts }
                checkStep("First post", done: hasPost) { model.page = .composer }
            }
        }
        .card(padding: Space.lg)
    }

    private func checkStep(_ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? DS.green : DS.text3)
                Text(title).font(DS.body).foregroundStyle(done ? DS.text2 : DS.text)
            }
            .padding(.horizontal, Space.md).frame(height: 32)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl))
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ symbol: String) -> Color {
        if symbol.contains("exclamation") { return DS.red }
        if symbol.contains("checkmark") { return DS.green }
        if symbol.contains("clock") || symbol.contains("stack") { return DS.accent }
        return DS.text3
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        let first = (Store.isOverridden ? "Maya" : NSFullUserName()).split(separator: " ").first.map(String.init) ?? ""
        let part = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var summary: String {
        if pubs.isEmpty { return "Import images and a CSV in Bulk Publisher or draft a post in Composer to get started." }
        var s = "\(upcoming.count) scheduled"
        if let last = upcoming.last { s += " through \(last.scheduledAt.formatted(.dateTime.month(.wide).day()))" }
        s += "."
        if let first = review.first {
            s += " \(review.count) awaiting review before \(first.scheduledAt.formatted(.dateTime.month(.abbreviated).day()))."
        }
        if !attention.isEmpty { s += " \(attention.count) need attention." }
        return s
    }
}

struct UpNextTile: View {
    let pub: Publication
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.publicationSelection = [pub.id]
            model.page = .calendar
        } label: {
            VStack(alignment: .leading, spacing: Space.sm) {
                Thumbnail(path: model.asset(pub.assetID)?.storedPath, maxPixel: 420)
                    .frame(width: 168, height: 228)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                    .overlay(alignment: .topLeading) { PlatformBadge(platform: pub.platform, size: 20).padding(Space.sm) }
                Text(pub.title.isEmpty ? "Untitled" : pub.title).font(DS.bodyMedium).foregroundStyle(DS.text).lineLimit(1)
                Text(pub.scheduledAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · " + pub.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(DS.small).foregroundStyle(DS.text2)
            }
            .frame(width: 168, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct ApprovalRow: View {
    let pub: Publication
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasErrors = pub.hasErrors(model: model)
        HStack(spacing: Space.md) {
            Thumbnail(path: model.asset(pub.assetID)?.storedPath, maxPixel: 120)
                .frame(width: 40, height: 52).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(pub.title.isEmpty ? "Untitled" : pub.title).font(DS.bodyMedium).lineLimit(1)
                Text("\(pub.scheduledAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(PlatformRegistry.spec(pub.platform)?.name ?? pub.platform)")
                    .font(DS.small).foregroundStyle(DS.text2)
            }
            Spacer()
            Button("Review") {
                model.publicationSelection = [pub.id]
                model.page = .calendar
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Approve & Schedule") {
                pub.status = .approved
                try? model.context.save()
                Task { _ = await model.activate([pub]) }
            }
            .buttonStyle(SecondaryButtonStyle(tint: DS.green))
            .disabled(hasErrors)
            .help(hasErrors ? "Fix the problems first (Review)" : "Approve and schedule this post for publishing")
        }
        .padding(.vertical, Space.md)
    }
}

/// The dashboard inspector: accounts and data-driven suggestions.
struct HomeInspector: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query(sort: \MediaAsset.importedAt, order: .reverse) private var allAssets: [MediaAsset]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Overview") { Text("\(model.accounts.count) account\(model.accounts.count == 1 ? "" : "s")") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Connected accounts")
                    ForEach(model.accounts) { a in AccountRow(account: a, queued: queued(a)) }
                    Button { model.page = .accounts } label: { Label("Connect account", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(DS.text2).padding(.top, Space.xs)
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    SectionLabel("Suggestions")
                    if suggestions.isEmpty {
                        Text("Nothing to suggest right now.").font(DS.body).foregroundStyle(DS.text2)
                    }
                    ForEach(suggestions, id: \.title) { s in
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(s.title).font(DS.bodyMedium)
                            Text(s.detail).font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                            Button(s.action) { s.run() }.buttonStyle(LinkButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: Space.lg)
                    }
                }
            }
        }
    }

    private func queued(_ a: SocialAccount) -> Int {
        allPubs.filter { $0.accountID == a.serverID && [.approved, .scheduled].contains($0.status) }.count
    }

    struct Suggestion {
        let title: String
        let detail: String
        let action: String
        let run: () -> Void
    }

    /// Rules over real data. None of these are AI output.
    private var suggestions: [Suggestion] {
        var out: [Suggestion] = []
        let pubs = allPubs.filter { $0.workspaceID == model.workspaceID }
        let live = pubs.filter { [.approved, .scheduled, .needsReview].contains($0.status) }
        // A gap of 3+ days in the next three weeks.
        let cal = Calendar.current
        let days = (1...21).compactMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: .now)) }
        var run: [Date] = []
        var gap: [Date] = []
        for d in days {
            if live.contains(where: { cal.isDate($0.scheduledAt, inSameDayAs: d) }) {
                if run.count >= 3 && gap.isEmpty { gap = run }
                run = []
            } else { run.append(d) }
        }
        if run.count >= 3 && gap.isEmpty && !live.isEmpty { gap = run }
        if let first = gap.first, let last = gap.last {
            let f = Date.FormatStyle().month(.abbreviated).day()
            out.append(Suggestion(title: "Fill the \(first.formatted(f))–\(last.formatted(f)) gap",
                                  detail: "Nothing is scheduled for \(gap.count) days in a row. Add posts from your library to keep the cadence.",
                                  action: "Open Bulk Publisher") { model.page = .bulk })
        }
        let failed = pubs.filter { $0.status == .failed }
        if !failed.isEmpty {
            out.append(Suggestion(title: "\(failed.count) post\(failed.count == 1 ? "" : "s") failed",
                                  detail: failed.first?.lastError ?? "Check the attempt history.", action: "Open in calendar") {
                model.publicationSelection = Set(failed.map(\.id))
                model.page = .calendar
            })
        }
        let mine = allAssets.filter { $0.workspaceID == model.workspaceID && $0.kind == "image" }
        let byAsset = model.variantsByAsset()
        let noVariant = mine.filter { a in !(byAsset[a.uuid] ?? []).contains { $0.presetID == "pinterest-2x3" } }
        let wrongRatio = noVariant.filter { $0.height > 0 && abs(Double($0.width) / Double($0.height) - 2.0 / 3.0) > 0.05 }
        if !wrongRatio.isEmpty {
            out.append(Suggestion(title: "Resize \(wrongRatio.count) image\(wrongRatio.count == 1 ? "" : "s") for Pinterest",
                                  detail: "They are not 2:3 yet. A Pinterest variant keeps the original untouched.",
                                  action: "Select them in Media Library") {
                model.mediaSelection = Set(wrongRatio.map(\.uuid))
                model.page = .media
            })
        }
        return out
    }
}

struct AccountRow: View {
    let account: SocialAccount
    var queued: Int = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            PlatformBadge(platform: account.platform, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).font(DS.bodyMedium).lineLimit(1)
                Text(subtitle).font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                StatusDot(text: account.status == "connected" ? "Connected" : account.status.capitalized,
                          color: account.status == "connected" ? DS.green : DS.amber)
                Text("\(queued) queued").font(DS.small).foregroundStyle(DS.text2)
            }
        }
        .padding(.vertical, Space.sm)
    }

    private var subtitle: String {
        let name = PlatformRegistry.spec(account.platform)?.name ?? account.platform
        let boards = model.boards[account.serverID]?.count ?? 0
        return account.isMock ? "\(name) · mock (testing)" : boards > 0 ? "\(name) · \(boards) boards" : name
    }
}

struct PublicationRow: View {
    let pub: Publication
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.sm) {
            Thumbnail(path: model.asset(pub.assetID)?.storedPath, maxPixel: 96)
                .frame(width: 32, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            PlatformBadge(platform: pub.platform, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(pub.title.isEmpty ? "Untitled" : pub.title).lineLimit(1)
                Text(pub.scheduledAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(DS.small).foregroundStyle(DS.text2)
            }
            Spacer()
            StatusChip(status: pub.status)
        }
        .padding(.vertical, 2)
    }
}

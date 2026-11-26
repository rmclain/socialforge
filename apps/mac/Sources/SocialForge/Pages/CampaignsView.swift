import SwiftData
import SwiftUI
import SocialForgeKit

struct CampaignsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Campaign.startDate) private var allCampaigns: [Campaign]
    @Query private var allPubs: [Publication]
    @Query private var allAssets: [MediaAsset]

    static let kinds: [(String, String)] = [
        ("Product launch", "Introduce a new product and drive first sales."),
        ("Holiday promotion", "Seasonal offers on a fixed end date."),
        ("Event registration", "Get sign-ups before the event."),
        ("Blog promotion", "Send readers to new articles."),
        ("Evergreen Pinterest collection", "A steady daily Pin from a long-lived collection."),
    ]

    private var campaigns: [Campaign] { allCampaigns.filter { $0.workspaceID == model.workspaceID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Campaigns").font(DS.display(30))
                        Text("Group posts and media under a goal and dates, with UTM-tagged links for attribution.").foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Menu {
                        ForEach(Self.kinds, id: \.0) { k in Button(k.0) { add(kind: k.0, goal: k.1) } }
                    } label: { Label("New Campaign", systemImage: "plus").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.button).buttonStyle(PrimaryButtonStyle()).menuIndicator(.hidden).fixedSize()
                }
                if campaigns.isEmpty {
                    EmptyState(symbol: "flag", title: "No campaigns yet", message: "Start from a campaign type. Its posts, media, and links stay together, and the calendar and analytics can filter to it.")
                        .frame(height: 300)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(campaigns) { c in
                        let posts = allPubs.filter { $0.campaignID == c.uuid }
                        let media = allAssets.filter { $0.campaignID == c.uuid }
                        VStack(alignment: .leading, spacing: Space.md) {
                            HStack {
                                Text(c.kind.uppercased()).font(DS.sectionLabel).tracking(0.6).foregroundStyle(DS.accent)
                                Spacer()
                                Text(phase(c)).font(DS.small).foregroundStyle(DS.text2)
                            }
                            Text(c.name).font(DS.display(24))
                            Text(c.goal).font(DS.body).foregroundStyle(DS.text2).lineLimit(2)
                            Text("\(c.startDate.formatted(date: .abbreviated, time: .omitted)) – \(c.endDate.formatted(date: .abbreviated, time: .omitted))").font(DS.small).foregroundStyle(DS.textBody)
                            HStack(spacing: Space.lg) {
                                metric("Posts", posts.count)
                                metric("Published", posts.filter { $0.status == .published }.count)
                                metric("Review", posts.filter { $0.status == .needsReview }.count)
                                metric("Media", media.count)
                            }
                            if posts.isEmpty && c.endDate >= .now {
                                Label("No posts scheduled for this campaign yet", systemImage: "calendar.badge.exclamationmark")
                                    .font(DS.caption).foregroundStyle(DS.amber)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: Space.xl, selected: model.campaignSelection == c.uuid)
                        .onTapGesture { model.campaignSelection = c.uuid }
                        .contextMenu {
                            Button("Duplicate") { duplicate(c) }
                            Button("Delete", role: .destructive) { deleteCampaign(c) }
                        }
                    }
                }
            }
            .padding(Space.xxl)
        }
    }

    private func metric(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(DS.caption).foregroundStyle(DS.text2)
        }
    }

    private func phase(_ c: Campaign) -> String {
        if c.endDate < .now { return "Ended" }
        if c.startDate > .now { return "Starts \(c.startDate.formatted(.relative(presentation: .named)))" }
        return "Running"
    }

    private func add(kind: String, goal: String) {
        guard let ws = model.workspaceID else { return }
        let c = Campaign(workspaceID: ws, name: "\(kind) \(Date.now.formatted(.dateTime.month(.abbreviated).year()))")
        c.kind = kind
        c.goal = goal
        if kind.hasPrefix("Evergreen") { c.endDate = .now.addingTimeInterval(180 * 86_400) }
        model.context.insert(c)
        try? model.context.save()
        model.campaignSelection = c.uuid
    }

    private func deleteCampaign(_ c: Campaign) {
        let id = c.uuid
        for p in allPubs where p.campaignID == id { p.campaignID = nil }
        for a in allAssets where a.campaignID == id { a.campaignID = nil }
        if model.campaignSelection == id { model.campaignSelection = nil }
        model.context.delete(c)
        try? model.context.save()
    }

    private func duplicate(_ c: Campaign) {
        guard let ws = model.workspaceID else { return }
        let d = Campaign(workspaceID: ws, name: c.name + " copy")
        d.kind = c.kind; d.goal = c.goal; d.utmSource = c.utmSource; d.utmMedium = c.utmMedium
        d.utmCampaign = c.utmCampaign.isEmpty ? "" : "\(c.utmCampaign)-copy"
        d.perPlatformUTMSource = c.perPlatformUTMSource
        d.notes = c.notes; d.templateID = c.templateID
        d.startDate = c.endDate
        d.endDate = c.endDate.addingTimeInterval(max(86_400, c.endDate.timeIntervalSince(c.startDate)))
        model.context.insert(d)
        try? model.context.save()
    }
}

struct CampaignInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var allCampaigns: [Campaign]
    @Query private var allPubs: [Publication]

    var body: some View {
        if let c = allCampaigns.first(where: { $0.uuid == model.campaignSelection && $0.workspaceID == model.workspaceID }) {
            CampaignEditor(campaign: c, posts: allPubs.filter { $0.campaignID == c.uuid && $0.workspaceID == model.workspaceID })
        } else {
            VStack(spacing: 0) {
                PanelHeader(title: "Campaign")
                Divider().overlay(DS.stroke)
                EmptyState(symbol: "flag", title: "No campaign selected", message: "Pick a campaign to edit its goal, dates, and links.")
            }
        }
    }
}

struct CampaignEditor: View {
    @Bindable var campaign: Campaign
    let posts: [Publication]
    @Environment(AppModel.self) private var model
    @Query(sort: \CreativeTemplate.createdAt) private var templates: [CreativeTemplate]

    var body: some View {
        let sample = UTM.apply(to: "https://example.com/product", source: campaign.utmSource, medium: campaign.utmMedium, campaign: campaign.utmCampaign)
        VStack(spacing: 0) {
            PanelHeader(title: "Campaign") { Text(campaign.kind) }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Details")
                    TextField("Name", text: $campaign.name).fieldStyle()
                    TextField("Goal", text: $campaign.goal, axis: .vertical).lineLimit(2...4).fieldStyle()
                    DatePicker("Starts", selection: $campaign.startDate, displayedComponents: .date).font(DS.body)
                        .onChange(of: campaign.startDate) { if campaign.endDate < campaign.startDate { campaign.endDate = campaign.startDate } }
                    DatePicker("Ends", selection: $campaign.endDate, in: campaign.startDate..., displayedComponents: .date).font(DS.body)
                    Picker("Template", selection: $campaign.templateID) {
                        Text("None").tag(UUID?.none)
                        ForEach(templates.filter { $0.workspaceID == model.workspaceID }) { Text($0.name).tag(UUID?.some($0.uuid)) }
                    }
                    .font(DS.body)
                    TextField("Notes", text: $campaign.notes, axis: .vertical).lineLimit(2...5).fieldStyle()
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("UTM links")
                    Toggle("Use platform name as utm_source", isOn: $campaign.perPlatformUTMSource).toggleStyle(SFToggleStyle()).font(DS.body)
                    if !campaign.perPlatformUTMSource {
                        HStack { Text("source").font(DS.mono).foregroundStyle(DS.text2).frame(width: 72, alignment: .leading); TextField("", text: $campaign.utmSource).fieldStyle() }
                    }
                    HStack { Text("medium").font(DS.mono).foregroundStyle(DS.text2).frame(width: 72, alignment: .leading); TextField("", text: $campaign.utmMedium).fieldStyle() }
                    HStack { Text("campaign").font(DS.mono).foregroundStyle(DS.text2).frame(width: 72, alignment: .leading); TextField("", text: $campaign.utmCampaign).fieldStyle() }
                    Text(sample).font(DS.mono).foregroundStyle(DS.text2).lineLimit(3).textSelection(.enabled)
                    let editable = posts.filter { $0.status.isLocal && !$0.link.isEmpty }
                    Button("Tag \(editable.count) post links") {
                        for p in editable {
                            let src = campaign.perPlatformUTMSource ? p.platform : campaign.utmSource
                            p.link = UTM.apply(to: p.link, source: src, medium: campaign.utmMedium, campaign: campaign.utmCampaign)
                        }
                        try? model.context.save()
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true)).disabled(editable.isEmpty)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Content")
                    Button("Add \(model.mediaSelection.count) selected media") {
                        for a in model.assets(model.mediaSelection) { a.campaignID = campaign.uuid }
                        try? model.context.save()
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true)).disabled(model.mediaSelection.isEmpty)
                    Button("Add \(model.publicationSelection.count) selected posts") {
                        let wsID = model.workspaceID
                        let all = ((try? model.context.fetch(FetchDescriptor<Publication>())) ?? []).filter { $0.workspaceID == wsID }
                        for p in all where model.publicationSelection.contains(p.id) { p.campaignID = campaign.uuid }
                        try? model.context.save()
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true)).disabled(model.publicationSelection.isEmpty)
                    Button("Plan posts in Bulk Publisher") {
                        let cid = campaign.uuid
                        let wsID = campaign.workspaceID
                        let media = ((try? model.context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == wsID }))) ?? []).filter { $0.campaignID == cid }
                        model.bulk.assetIDs = media.map(\.uuid)
                        model.bulk.campaignID = cid
                        model.bulk.runName = campaign.name
                        model.bulk.rule.start = LocalDay(max(campaign.startDate, .now.addingTimeInterval(86_400)), in: .current)
                        model.page = .bulk
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    Text("Posts created from campaign media in Bulk Publisher can be added here and tagged in one step.").font(DS.caption).foregroundStyle(DS.text3)
                }
            }
        }
    }
}

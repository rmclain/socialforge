import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

/// One post, many platforms: the canonical copy plus a version per platform.
@Observable
final class ComposerModel {
    struct Variant: Equatable {
        var platform: String
        var enabled: Bool
        var accountID: String = ""
        var boardID: String = ""
        var title: String = ""
        var text: String = ""
        var overridden = false
    }

    var contentID: UUID?
    var title = ""
    var body = ""
    var link = ""
    var altText = ""
    var hashtags: [String] = []
    var assetID: UUID?
    var campaignID: UUID?
    var when = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!)!
    var variants: [Variant] = ["pinterest", "instagram", "facebook", "threads", "x", "linkedin"].map { Variant(platform: $0, enabled: $0 == "pinterest") }
    var previewPlatform = "pinterest"
    var message: String?

    var subtitle: String { title.isEmpty ? "New post" : title }

    /// The design's tab names: Pin, FB, X, In.
    static func short(_ p: String) -> String {
        switch p { case "pinterest": "Pin"; case "facebook": "FB"; case "instagram": "IG"; case "threads": "Threads"; case "linkedin": "In"; default: "X" }
    }

    func startNew(model: AppModel) {
        contentID = nil
        title = ""; body = ""; link = ""; altText = ""
        hashtags = (model.brandKit?.hashtags ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        assetID = model.mediaSelection.first
        if let a = model.asset(assetID) { title = a.title; link = a.productURL; altText = a.altText }
        variants = ["pinterest", "instagram", "facebook", "threads", "x", "linkedin"].map { Variant(platform: $0, enabled: $0 == "pinterest") }
        // Meta accounts post to the Page or profile itself: preselect the first connected one.
        for i in variants.indices where variants[i].platform != "pinterest" {
            if let a = model.accounts.first(where: { $0.platform == variants[i].platform && $0.status == "connected" }) { variants[i].accountID = a.serverID }
        }
        if let pin = model.accounts.first(where: { $0.platform == "pinterest" }) {
            variants[0].accountID = pin.serverID
            variants[0].boardID = model.boards[pin.serverID]?.first?.id ?? ""
        }
        message = nil
    }

    /// The platform version derived from the canonical copy, unless the user edited it.
    func adapted(_ v: Variant) -> Variant {
        guard !v.overridden else { return v }
        var out = v
        let tags = hashtags.prefix(5).map { "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.joined(separator: " ")
        switch v.platform {
        case "pinterest":
            out.title = String(title.prefix(100))
            out.text = body
        case "x":
            // Short copy: X counts every link as 23 characters.
            let room = 280 - (link.isEmpty ? 0 : 24) - (tags.isEmpty ? 0 : tags.count + 1)
            let base = body.isEmpty ? title : body
            out.text = [String(base.prefix(max(0, room))), tags, link].filter { !$0.isEmpty }.joined(separator: " ")
        case "linkedin":
            out.text = [title, body, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
        default:
            out.text = [body.isEmpty ? title : body, link].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return out
    }

    func draft(_ v: Variant, model: AppModel) -> PostDraft {
        let a = adapted(v)
        let asset = model.asset(assetID)
        return PostDraft(platform: v.platform, title: a.title, description: a.text, link: link, altText: altText,
                         destinationID: v.platform == "pinterest" ? (v.boardID.isEmpty ? nil : v.boardID) : "none",
                         image: asset?.kind == "image" ? asset?.imageFacts : nil)
    }

    func issues(_ v: Variant, model: AppModel) -> [ValidationIssue] {
        var out = PostValidator.validate(draft(v, model: model))
        if v.platform != "pinterest" {
            // Map the canonical text into the platform's main text field for limits.
            let key = PlatformRegistry.spec(v.platform)?.text.keys.first ?? "text"
            if let rule = PlatformRegistry.spec(v.platform)?.text[key], adapted(v).text.count > rule.max {
                out.append(ValidationIssue(.error, key, "\(adapted(v).text.count) characters; \(PlatformRegistry.spec(v.platform)?.name ?? "") allows \(rule.max)."))
            }
        }
        if v.platform == "pinterest", v.accountID.isEmpty { out.append(ValidationIssue(.error, "account", "Choose a Pinterest account.")) }
        if assetID == nil && v.platform == "pinterest" { out.append(ValidationIssue(.error, "image", "A Pin needs an image.")) }
        let asset = model.asset(assetID)
        if ["facebook", "instagram", "threads"].contains(v.platform) {
            let name = PlatformRegistry.spec(v.platform)?.name ?? v.platform
            if v.accountID.isEmpty { out.append(ValidationIssue(.error, "account", "Connect a \(name) account in Accounts, then choose it.")) }
            if v.platform == "instagram" && asset == nil { out.append(ValidationIssue(.error, "image", "Instagram posts need a photo or a video.")) }
            let needsStorage = (v.platform == "instagram" && asset?.kind == "image") || (v.platform == "threads" && asset != nil)
            if needsStorage && PublicMediaSettings.config == nil {
                out.append(ValidationIssue(.error, "image", "\(name) fetches this media from a public address. Set up public media storage in Settings › Publishing."))
            }
        }
        if let asset, asset.kind == "video" {
            if v.platform == "pinterest" { out.append(ValidationIssue(.error, "video", "Video Pins aren't built yet; Pinterest takes the image only.")) }
            else {
                out += PostValidator.validateVideo(platform: v.platform, seconds: asset.duration, width: asset.width, height: asset.height,
                                                   bytes: asset.bytes, format: asset.format)
            }
        }
        if asset?.kind == "audio" { out.append(ValidationIssue(.error, "media", "Audio can't be posted on its own. Add it to a video in Creative Studio.")) }
        return out
    }

    /// Saves the canonical item and one Publication per enabled platform.
    @discardableResult
    func save(model: AppModel, status: PublicationStatus) -> [Publication] {
        guard let ws = model.workspaceID else { return [] }
        let item: ContentItem = contentID.flatMap { id in (try? model.context.fetch(FetchDescriptor<ContentItem>(predicate: #Predicate { $0.uuid == id })))?.first }
            ?? { let c = ContentItem(workspaceID: ws); model.context.insert(c); return c }()
        item.title = title; item.body = body; item.link = link; item.altText = altText; item.hashtags = hashtags
        item.assetID = assetID; item.campaignID = campaignID; item.updatedAt = .now
        contentID = item.uuid
        let itemID = item.uuid
        let existing = (try? model.context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.contentItemID == itemID }))) ?? []
        var out: [Publication] = []
        for v in variants where v.enabled {
            let a = adapted(v)
            let p = existing.first { $0.platform == v.platform && $0.status.isLocal }
                ?? { let n = Publication(workspaceID: ws, scheduledAt: when, timeZoneID: TimeZone.current.identifier); model.context.insert(n); return n }()
            p.contentItemID = item.uuid
            p.platform = v.platform
            p.assetID = assetID
            p.accountID = v.accountID
            p.accountName = model.accounts.first { $0.serverID == v.accountID }?.name ?? ""
            p.boardID = v.boardID
            p.boardName = model.boards[v.accountID]?.first { $0.id == v.boardID }?.name ?? ""
            p.title = v.platform == "pinterest" ? a.title : title
            p.desc = a.text
            p.link = link
            p.altText = altText
            p.scheduledAt = when
            p.campaignID = campaignID
            p.runName = "Composer"
            let blocked = issues(v, model: model).contains { $0.level == .error }
            p.status = status == .approved && blocked ? .needsReview : status
            out.append(p)
        }
        try? model.context.save()
        return out
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var c = model.composer
        ScrollView {
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.lg) {
                        ZStack {
                            if let a = model.asset(c.assetID) {
                                Thumbnail(path: a.storedPath, maxPixel: 400)
                            } else {
                                VStack(spacing: Space.xs) {
                                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(DS.accent)
                                    Text("Drop an image").font(DS.small).foregroundStyle(DS.text2)
                                }
                            }
                        }
                        .frame(width: 120, height: 160)
                        .background(DS.fillStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(dropTargeted ? DS.accentFill : DS.stroke, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: c.assetID == nil ? [5, 4] : [])))
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { if let a = await model.importMedia(urls).first { c.assetID = a.uuid } }
                            return true
                        } isTargeted: { dropTargeted = $0 }
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Button("Use Library Selection") { c.assetID = model.mediaSelection.first }.buttonStyle(SecondaryButtonStyle()).disabled(model.mediaSelection.isEmpty)
                            Button("Design in Creative Studio") {
                                model.studio.openNew(model: model, photoPath: model.asset(c.assetID)?.storedPath)
                                model.page = .studio
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            if c.assetID != nil { Button("Remove image") { c.assetID = nil }.buttonStyle(.plain).foregroundStyle(DS.text2).font(DS.small) }
                        }
                    }
                    TextField("Title", text: $c.title).font(DS.display(26)).textFieldStyle(.plain)
                    TextField("Write the post. Each platform's version is adapted from this; edit any of them on the right.", text: $c.body, axis: .vertical)
                        .lineLimit(5...14).fieldStyle()
                    HStack(spacing: Space.sm) {
                        Image(systemName: "link").foregroundStyle(DS.text3)
                        TextField("Destination link", text: $c.link).textFieldStyle(.plain)
                        if let campaign = model.campaign(c.campaignID), !c.link.isEmpty {
                            Button("Add UTM tags") {
                                c.link = UTM.apply(to: c.link, source: campaign.utmSource, medium: campaign.utmMedium, campaign: campaign.utmCampaign)
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                    }
                    .fieldStyle()
                    TextField("Alt text: what the image shows", text: $c.altText, axis: .vertical).lineLimit(1...3).fieldStyle()
                    HashtagEditor(tags: $c.hashtags, suggestions: model.brandKit?.hashtags ?? [])
                    SectionLabel("Platforms")
                    HStack(spacing: Space.sm) {
                        ForEach(c.variants.indices, id: \.self) { i in
                            let v = c.variants[i]
                            Button { c.variants[i].enabled.toggle(); c.previewPlatform = v.platform } label: {
                                HStack(spacing: Space.xs) {
                                    PlatformBadge(platform: v.platform, size: 18)
                                    Text(ComposerModel.short(v.platform)).font(DS.body).lineLimit(1).fixedSize()
                                    Image(systemName: v.enabled ? "checkmark.circle.fill" : "circle").foregroundStyle(v.enabled ? DS.green : DS.text3)
                                }
                                .padding(.horizontal, Space.md).frame(height: 32)
                                .background(v.enabled ? DS.fillSelected : DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card(padding: Space.xl)

                VStack(alignment: .leading, spacing: Space.md) {
                    PillPicker(options: c.variants.filter(\.enabled).map(\.platform), selection: $c.previewPlatform) { ComposerModel.short($0) }
                    if let i = c.variants.firstIndex(where: { $0.platform == c.previewPlatform && $0.enabled }) {
                        VariantPreview(index: i)
                    } else {
                        Text("Turn on a platform to preview it.").foregroundStyle(DS.text2)
                    }
                }
                .frame(width: 420, alignment: .topLeading)
            }
            .padding(Space.xxl)
        }
        .onAppear { if c.variants.allSatisfy({ $0.accountID.isEmpty }) && c.title.isEmpty { c.startNew(model: model) } }
    }
}

struct HashtagEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowLayout(spacing: Space.xs) {
                ForEach(tags, id: \.self) { t in
                    Button { tags.removeAll { $0 == t } } label: {
                        HStack(spacing: 4) { Text("#" + t); Image(systemName: "xmark").font(.system(size: 9)) }
                            .font(DS.small).padding(.horizontal, Space.sm).frame(height: 24).background(DS.accentSoft, in: Capsule()).foregroundStyle(DS.accent)
                    }
                    .buttonStyle(.plain)
                }
                TextField("Add hashtag", text: $input).textFieldStyle(.plain).frame(width: 120)
                    .onSubmit {
                        let t = input.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                        if !t.isEmpty, !tags.contains(t) { tags.append(t) }
                        input = ""
                    }
            }
            let unused = suggestions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.filter { !tags.contains($0) }
            if !unused.isEmpty {
                HStack(spacing: Space.xs) {
                    Text("Brand:").font(DS.caption).foregroundStyle(DS.text3)
                    ForEach(unused, id: \.self) { s in Button("#" + s) { tags.append(s) }.buttonStyle(.plain).font(DS.small).foregroundStyle(DS.text2) }
                }
            }
        }
    }
}

/// A platform's version: its own editable copy and a preview in that platform's shape.
struct VariantPreview: View {
    let index: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var c = model.composer
        let v = c.adapted(c.variants[index])
        let asset = model.asset(c.assetID)
        let spec = PlatformRegistry.spec(v.platform)
        VStack(alignment: .leading, spacing: Space.md) {
            Group {
                switch v.platform {
                case "pinterest":
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Thumbnail(path: asset?.storedPath, maxPixel: 500).frame(width: 236, height: 356).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Text("Save").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).padding(.horizontal, Space.md).frame(height: 28)
                                    .background(Color(hex: 0xE60023), in: Capsule()).padding(Space.sm)
                            }
                        Text(v.title.isEmpty ? "Pin title" : v.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(v.text).font(DS.small).foregroundStyle(DS.text2).lineLimit(3)
                    }
                    .frame(width: 236)
                default:
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            PlatformBadge(platform: v.platform, size: 32)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.workspace?.name ?? "Your page").font(DS.bodyMedium)
                                Text(v.platform == "x" ? "@handle · now" : "Just now").font(DS.caption).foregroundStyle(DS.text2)
                            }
                        }
                        Text(v.text).font(DS.body).fixedSize(horizontal: false, vertical: true)
                        Thumbnail(path: asset?.storedPath, maxPixel: 600)
                            .frame(height: v.platform == "facebook" ? 220 : 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))

            HStack {
                SectionLabel("\(spec?.name ?? v.platform) version")
                if c.variants[index].overridden {
                    Button("Reset to canonical") { c.variants[index].overridden = false }.buttonStyle(LinkButtonStyle())
                }
            }
            if v.platform == "pinterest" {
                TextField("Pin title", text: Binding(get: { v.title }, set: { c.variants[index].title = $0; c.variants[index].text = v.text; c.variants[index].overridden = true })).fieldStyle()
            }
            TextField("Text", text: Binding(get: { v.text }, set: { c.variants[index].text = $0; c.variants[index].title = v.title; c.variants[index].overridden = true }), axis: .vertical)
                .lineLimit(3...10).fieldStyle()
            let key = v.platform == "pinterest" ? "description" : (spec?.text.keys.first ?? "")
            if let rule = spec?.text[key] {
                Text("\(v.text.count) / \(rule.max)").font(DS.caption).foregroundStyle(v.text.count > rule.max ? DS.red : DS.text3)
            }
            ForEach(c.issues(c.variants[index], model: model), id: \.self) { IssueRow(issue: $0) }
        }
    }
}

struct ComposerInspector: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Campaign.name) private var campaigns: [Campaign]

    var body: some View {
        @Bindable var c = model.composer
        let enabled = c.variants.filter(\.enabled)
        let blocked = enabled.filter { v in c.issues(v, model: model).contains { $0.level == .error } }
        VStack(spacing: 0) {
            PanelHeader(title: "Post") { Text("\(enabled.count) platform\(enabled.count == 1 ? "" : "s")") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.md) {
                    SectionLabel("Post to")
                    ForEach(c.variants.indices, id: \.self) { i in
                        let v = c.variants[i]
                        if v.enabled {
                            let accounts = model.accounts.filter { $0.platform == v.platform }
                            HStack(spacing: Space.md) {
                                PlatformBadge(platform: v.platform, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    if accounts.isEmpty {
                                        Text(PlatformRegistry.spec(v.platform)?.isAvailable == true ? "No account connected" : "\(PlatformRegistry.spec(v.platform)?.name ?? v.platform): drafts only")
                                            .font(DS.body).foregroundStyle(DS.text2)
                                    } else {
                                        Picker("", selection: $c.variants[i].accountID) {
                                            Text("Choose account").tag("")
                                            ForEach(accounts) { a in Text(a.name + (a.isMock ? " (mock)" : "")).tag(a.serverID) }
                                        }
                                        .labelsHidden()
                                        if v.platform == "pinterest" {
                                            Picker("", selection: $c.variants[i].boardID) {
                                                Text("Choose board").tag("")
                                                ForEach(model.boards[v.accountID] ?? []) { b in Text(b.name).tag(b.id) }
                                            }
                                            .labelsHidden()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Schedule")
                    DatePicker("Publish", selection: $c.when).font(DS.body)
                    Picker("Campaign", selection: $c.campaignID) {
                        Text("None").tag(UUID?.none)
                        ForEach(campaigns.filter { $0.workspaceID == model.workspaceID }) { Text($0.name).tag(UUID?.some($0.uuid)) }
                    }
                    .font(DS.body)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Checks")
                    if blocked.isEmpty && !enabled.isEmpty {
                        Label("Every version is ready.", systemImage: "checkmark.circle.fill").font(DS.small).foregroundStyle(DS.green)
                    }
                    ForEach(blocked, id: \.platform) { v in
                        Label("\(PlatformRegistry.spec(v.platform)?.name ?? v.platform) has problems; see its preview.", systemImage: "xmark.octagon.fill")
                            .font(DS.small).foregroundStyle(DS.red)
                    }
                }
                if let m = c.message { Text(m).font(DS.small).foregroundStyle(DS.textBody).card(padding: Space.md) }
            }
            Divider().overlay(DS.stroke)
            VStack(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Button("Save draft") {
                        let made = c.save(model: model, status: .needsReview)
                        c.message = "Saved \(made.count) version\(made.count == 1 ? "" : "s") for review."
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(enabled.isEmpty)
                    Button("Approve and schedule") {
                        let made = c.save(model: model, status: .approved)
                        let ok = made.filter { $0.status == .approved }
                        Task {
                            let r = await model.activate(ok)
                            c.message = "Scheduled \(r.sent) of \(made.count)." + (made.count > ok.count ? " Versions with problems stay in review." : "") + (r.failed.isEmpty ? "" : " " + r.failed.joined(separator: " "))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    .disabled(enabled.isEmpty || blocked.count == enabled.count)
                }
                Button("Publish now") {
                    c.when = .now.addingTimeInterval(5)
                    let made = c.save(model: model, status: .approved).filter { $0.status == .approved }
                    Task {
                        let r = await model.activate(made)
                        c.message = r.sent > 0 ? "Publishing \(r.sent) now. Results appear in the Calendar." : "Nothing could be published: fix the problems first."
                    }
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .disabled(enabled.isEmpty || blocked.count == enabled.count)
            }
            .padding(Space.xl)
        }
    }
}

extension AppModel {
    func campaign(_ id: UUID?) -> Campaign? {
        guard let id else { return nil }
        return (try? context.fetch(FetchDescriptor<Campaign>(predicate: #Predicate { $0.uuid == id })))?.first
    }
}

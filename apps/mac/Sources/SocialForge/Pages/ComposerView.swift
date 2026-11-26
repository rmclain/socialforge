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

    static let supportedPlatforms = ["pinterest", "instagram", "facebook", "threads", "linkedin", "x", "tiktok", "youtube"]

    var contentID: UUID?
    var title = ""
    var body = ""
    var link = ""
    var altText = ""
    var hashtags: [String] = []
    var assetID: UUID?
    var extraAssetIDs: [UUID] = []
    var campaignID: UUID?
    var timeZoneID = TimeZone.current.identifier
    var when = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!)!
    var variants: [Variant] = ComposerModel.supportedPlatforms.map { Variant(platform: $0, enabled: $0 == "pinterest") }
    var previewPlatform = "pinterest"
    var message: String?
    /// Platform-specific disclosures & options (YouTube visibility/madeForKids/Shorts, TikTok privacy/mode).
    var youtubeVisibility = "public"
    var youtubeKind = "video"
    var youtubeMadeForKids = false
    var tiktokMode = "inbox"
    var tiktokPrivacy = "SELF_ONLY"
    var tiktokDisclosePromo = false
    var generatingCopy = false

    var subtitle: String { title.isEmpty ? "New post" : title }

    func resetForWorkspaceSwitch() {
        contentID = nil
        title = ""; body = ""; link = ""; altText = ""
        hashtags = []
        assetID = nil
        extraAssetIDs = []
        campaignID = nil
        variants = Self.supportedPlatforms.map { Variant(platform: $0, enabled: $0 == "pinterest") }
        previewPlatform = "pinterest"
        message = nil
    }

    /// Reopens an existing saved ContentItem and its platform Publications in the Composer.
    func open(contentItem item: ContentItem, model: AppModel) {
        contentID = item.uuid
        title = item.title; body = item.body; link = item.link; altText = item.altText
        hashtags = item.hashtags
        assetID = item.assetID
        extraAssetIDs = item.extraAssetIDs
        campaignID = item.campaignID
        let id = item.uuid
        let pubs = (try? model.context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.contentItemID == id }))) ?? []
        if let firstWhen = pubs.first?.scheduledAt { when = firstWhen }
        if let firstTZ = pubs.first?.timeZoneID { timeZoneID = firstTZ }
        variants = Self.supportedPlatforms.map { p in
            if let existing = pubs.first(where: { $0.platform == p }) {
                return Variant(platform: p, enabled: true, accountID: existing.accountID, boardID: existing.boardID,
                               title: existing.title, text: existing.desc, overridden: true)
            }
            return Variant(platform: p, enabled: false)
        }
        previewPlatform = variants.first(where: \.enabled)?.platform ?? "pinterest"
        message = nil
    }

    /// Short tab names for all 8 platforms.
    static func short(_ p: String) -> String {
        switch p {
        case "pinterest": "Pin"
        case "facebook": "FB"
        case "instagram": "IG"
        case "threads": "Threads"
        case "linkedin": "In"
        case "x": "X"
        case "tiktok": "TikTok"
        case "youtube": "YT"
        default: p.capitalized
        }
    }

    func startNew(model: AppModel, at time: Date? = nil) {
        contentID = nil
        if let time { when = time }
        title = ""; body = ""; link = ""; altText = ""
        hashtags = (model.brandKit?.hashtags ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        assetID = model.mediaSelection.sorted { $0.uuidString < $1.uuidString }.first
        extraAssetIDs = Array(model.mediaSelection.sorted { $0.uuidString < $1.uuidString }.dropFirst())
        if let a = model.asset(assetID) { title = a.title; link = a.productURL; altText = a.altText }
        variants = Self.supportedPlatforms.map { Variant(platform: $0, enabled: $0 == "pinterest") }
        for i in variants.indices {
            let p = variants[i].platform
            if let a = model.accounts.first(where: { $0.platform == p && $0.status == "connected" }) ?? model.accounts.first(where: { $0.platform == p }) {
                variants[i].accountID = a.serverID
                variants[i].boardID = model.boards[a.serverID]?.first?.id ?? ""
            }
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
            out.text = [body, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "x":
            let room = 280 - (link.isEmpty ? 0 : 24) - (tags.isEmpty ? 0 : tags.count + 1)
            let base = body.isEmpty ? title : body
            out.text = [String(base.prefix(max(0, room))), tags, link].filter { !$0.isEmpty }.joined(separator: " ")
        case "linkedin":
            out.text = [title, body, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "youtube":
            out.title = String(title.prefix(100))
            out.text = [body, link, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "instagram", "tiktok":
            let combined = [title.isEmpty || body.contains(title) ? "" : title, body, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
            out.text = String(combined.prefix(2200))
        default:
            let combined = [title.isEmpty || body.contains(title) ? "" : title, body, link, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
            out.text = combined
        }
        return out
    }

    func draft(_ v: Variant, model: AppModel) -> PostDraft {
        let a = adapted(v)
        let asset = model.asset(assetID)
        let isVideo = asset?.kind == "video"
        return PostDraft(
            platform: v.platform, title: a.title.isEmpty ? title : a.title, description: a.text, link: link, altText: altText,
            destinationID: v.platform == "pinterest" ? (v.boardID.isEmpty ? nil : v.boardID) : "none",
            image: asset?.kind == "image" ? asset?.imageFacts : nil,
            isVideo: isVideo,
            hasPublicMediaHost: PublicMediaSettings.config() != nil
        )
    }

    func issues(_ v: Variant, model: AppModel) -> [ValidationIssue] {
        var out = PostValidator.validate(draft(v, model: model))
        let name = PlatformRegistry.spec(v.platform)?.name ?? v.platform.capitalized
        if v.accountID.isEmpty {
            out.append(ValidationIssue(.error, "account", "Connect and select a \(name) account in Connections."))
        } else if let acct = model.accounts.first(where: { $0.serverID == v.accountID }) {
            for c in acct.capabilities where !c.allowed {
                out.append(ValidationIssue(.error, "account", c.reason ?? "Account lacks required permission."))
                break
            }
        }
        let asset = model.asset(assetID)
        if asset == nil && ["pinterest", "instagram", "tiktok", "youtube"].contains(v.platform) {
            out.append(ValidationIssue(.error, "media", "\(name) posts require media."))
        }
        if let asset, asset.kind == "video" {
            out += PostValidator.validateVideo(platform: v.platform, seconds: asset.duration, width: asset.width, height: asset.height,
                                               bytes: asset.bytes, format: asset.format)
        }
        if asset?.kind == "audio" { out.append(ValidationIssue(.error, "media", "Audio can't be posted on its own. Add it to a video in Creative Studio.")) }
        if when < .now { out.append(ValidationIssue(.warning, "schedule", "Scheduled time is in the past.")) }
        return out
    }

    /// Saves the canonical item and one Publication per enabled platform.
    /// Removes local unpublished publications for platforms that were toggled off on re-save.
    @discardableResult
    func save(model: AppModel, status: PublicationStatus) -> [Publication] {
        guard let ws = model.workspaceID else { return [] }
        let item: ContentItem = contentID.flatMap { id in (try? model.context.fetch(FetchDescriptor<ContentItem>(predicate: #Predicate { $0.uuid == id })))?.first }
            ?? { let c = ContentItem(workspaceID: ws); model.context.insert(c); return c }()
        item.title = title; item.body = body; item.link = link; item.altText = altText; item.hashtags = hashtags
        item.assetID = assetID; item.extraAssetIDs = extraAssetIDs; item.campaignID = campaignID; item.updatedAt = .now
        contentID = item.uuid
        let itemID = item.uuid
        let existing = (try? model.context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.contentItemID == itemID }))) ?? []
        let enabledPlatforms = Set(variants.filter(\.enabled).map(\.platform))
        for stale in existing where stale.status.isLocal && !enabledPlatforms.contains(stale.platform) {
            model.context.delete(stale)
        }
        let campaign = model.campaign(campaignID)
        let variantsMap = model.variantsByAsset()
        var out: [Publication] = []
        for v in variants where v.enabled {
            let a = adapted(v)
            let p = existing.first { $0.platform == v.platform && $0.status.isLocal }
                ?? { let n = Publication(workspaceID: ws, scheduledAt: when, timeZoneID: timeZoneID); model.context.insert(n); return n }()
            p.contentItemID = item.uuid
            p.platform = v.platform
            p.assetID = assetID
            p.extraAssetIDs = extraAssetIDs
            p.variantID = assetID.flatMap { id in (variantsMap[id] ?? []).first { $0.presetID.hasPrefix(v.platform) }?.uuid }
            p.accountID = v.accountID
            p.accountName = model.accounts.first { $0.serverID == v.accountID }?.name ?? ""
            p.boardID = v.boardID
            p.boardName = model.boards[v.accountID]?.first { $0.id == v.boardID }?.name ?? ""
            p.title = ["pinterest", "youtube"].contains(v.platform) ? (a.title.isEmpty ? title : a.title) : title
            p.desc = a.text
            if let campaign, !link.isEmpty {
                let src = campaign.perPlatformUTMSource ? v.platform : campaign.utmSource
                p.link = UTM.apply(to: link, source: src, medium: campaign.utmMedium, campaign: campaign.utmCampaign)
            } else {
                p.link = link
            }
            p.altText = altText
            p.scheduledAt = when
            p.timeZoneID = timeZoneID
            p.campaignID = campaignID
            p.runName = "Composer"
            var meta = p.metadata
            if v.platform == "youtube" {
                meta["youtube_visibility"] = youtubeVisibility
                meta["youtube_kind"] = youtubeKind
                meta["youtube_made_for_kids"] = youtubeMadeForKids ? "true" : "false"
            } else if v.platform == "tiktok" {
                meta["tiktok_mode"] = tiktokMode
                meta["tiktok_privacy"] = tiktokPrivacy
                meta["tiktok_promo"] = tiktokDisclosePromo ? "true" : "false"
            }
            p.metadata = meta
            let blocked = issues(v, model: model).contains { $0.level == .error }
            p.status = status == .approved && blocked ? .needsReview : status
            out.append(p)
        }
        try? model.context.save()
        return out
    }

    @MainActor
    func generateCopyWithAI(model: AppModel) async {
        guard let provider = model.textProvider else {
            message = "Configure an AI text provider in Connections or Settings to generate copy."
            return
        }
        generatingCopy = true
        defer { generatingCopy = false }
        let asset = model.asset(assetID)
        let req = CopyRequest(
            platform: previewPlatform,
            productName: title.nonEmpty ?? asset?.title ?? "",
            filename: asset?.filename ?? "",
            link: link,
            existingTitle: title,
            existingDescription: body,
            brand: model.brandKit?.voiceForAI
        )
        do {
            let (copy, usage) = try await PostCopyGenerator.generate(req, provider: provider)
            if title.isEmpty { title = copy.title }
            body = copy.description
            if altText.isEmpty { altText = copy.altText }
            if !copy.hashtags.isEmpty { hashtags = Array(Set(hashtags + copy.hashtags)).sorted() }
            model.recordAI(kind: "text", prompt: "Composer copy (\(previewPlatform))", usage: usage, ok: true)
            message = "Generated copy with \(model.textProviderID.displayName). Review and customize per platform."
        } catch {
            message = error.localizedDescription
            model.recordAI(kind: "text", prompt: "Composer copy", usage: nil, ok: false, detail: error.localizedDescription)
        }
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var showMediaPicker = false

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
                                    Text("Drop media").font(DS.small).foregroundStyle(DS.text2)
                                }
                            }
                        }
                        .frame(width: 120, height: 160)
                        .background(DS.fillStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(dropTargeted ? DS.accentFill : DS.stroke, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: c.assetID == nil ? [5, 4] : [])))
                        .dropDestination(for: URL.self) { urls, _ in
                            Task {
                                let imported = await model.importMedia(urls)
                                if let first = imported.first {
                                    if c.assetID == nil { c.assetID = first.uuid }
                                    else { c.extraAssetIDs.append(first.uuid) }
                                    for more in imported.dropFirst() { c.extraAssetIDs.append(more.uuid) }
                                }
                            }
                            return true
                        } isTargeted: { dropTargeted = $0 }
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(spacing: Space.sm) {
                                Button("Choose from Library…") { showMediaPicker = true }.buttonStyle(SecondaryButtonStyle())
                                if !model.mediaSelection.isEmpty {
                                    Button("Use Selection (\(model.mediaSelection.count))") {
                                        let ids = Array(model.mediaSelection)
                                        c.assetID = ids.first
                                        c.extraAssetIDs = Array(ids.dropFirst())
                                    }.buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            Button("Design in Creative Studio") {
                                model.studio.openNew(model: model, photoPath: model.asset(c.assetID)?.storedPath)
                                model.page = .studio
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            if c.assetID != nil {
                                Button("Remove primary media") {
                                    c.assetID = c.extraAssetIDs.isEmpty ? nil : c.extraAssetIDs.removeFirst()
                                }.buttonStyle(.plain).foregroundStyle(DS.text2).font(DS.small)
                            }
                        }
                    }
                    if !c.extraAssetIDs.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Carousel / Multi-media (\(c.extraAssetIDs.count + (c.assetID == nil ? 0 : 1)) items)").font(DS.caption).foregroundStyle(DS.text2)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.sm) {
                                    ForEach(c.extraAssetIDs, id: \.self) { id in
                                        ZStack(alignment: .topTrailing) {
                                            Thumbnail(path: model.asset(id)?.storedPath, maxPixel: 140)
                                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                                            Button { c.extraAssetIDs.removeAll { $0 == id } } label: {
                                                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .buttonStyle(.plain).padding(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("Title", text: $c.title).font(DS.display(26)).textFieldStyle(.plain)
                        Button {
                            Task { await c.generateCopyWithAI(model: model) }
                        } label: {
                            Label(c.generatingCopy ? "Writing…" : "AI Copy", systemImage: "sparkles")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(c.generatingCopy || model.textProvider == nil)
                        .help(model.textProvider == nil ? "Configure an AI text provider in Connections" : "Draft title, caption, hashtags, and alt text with your brand voice")
                    }
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
                    FlowLayout(spacing: Space.sm) {
                        ForEach(c.variants.indices, id: \.self) { i in
                            let v = c.variants[i]
                            Button {
                                c.variants[i].enabled.toggle()
                                if c.variants[i].enabled {
                                    c.previewPlatform = v.platform
                                } else if c.previewPlatform == v.platform {
                                    c.previewPlatform = c.variants.first(where: \.enabled)?.platform ?? v.platform
                                }
                            } label: {
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
                    let enabledPlatforms = c.variants.filter(\.enabled).map(\.platform)
                    if !enabledPlatforms.isEmpty {
                        PillPicker(options: enabledPlatforms, selection: $c.previewPlatform) { ComposerModel.short($0) }
                    }
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
        .sheet(isPresented: $showMediaPicker) {
            ComposerMediaPickerSheet(primaryID: $c.assetID, extraIDs: $c.extraAssetIDs)
        }
    }
}

private struct ComposerMediaPickerSheet: View {
    @Binding var primaryID: UUID?
    @Binding var extraIDs: [UUID]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MediaAsset.importedAt, order: .reverse) private var allAssets: [MediaAsset]
    @State private var query = ""

    private var mine: [MediaAsset] {
        allAssets.filter {
            $0.workspaceID == model.workspaceID && $0.kind != "audio"
                && (query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Choose Media").font(DS.display(22))
                Spacer()
                TextField("Search library", text: $query).fieldStyle().frame(width: 220)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: Space.md)], spacing: Space.md) {
                    ForEach(mine) { a in
                        let isPrimary = primaryID == a.uuid
                        let isExtra = extraIDs.contains(a.uuid)
                        Button {
                            if isPrimary {
                                primaryID = extraIDs.isEmpty ? nil : extraIDs.removeFirst()
                            } else if isExtra {
                                extraIDs.removeAll { $0 == a.uuid }
                            } else if primaryID == nil {
                                primaryID = a.uuid
                            } else {
                                extraIDs.append(a.uuid)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Thumbnail(path: a.storedPath, maxPixel: 240)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isPrimary ? DS.accentFill : (isExtra ? DS.green : .clear), lineWidth: 2))
                                    .overlay(alignment: .topTrailing) {
                                        if isPrimary {
                                            Text("1").font(.caption2.bold()).foregroundStyle(.white)
                                                .frame(width: 20, height: 20).background(DS.accentFill, in: Circle()).padding(4)
                                        } else if let idx = extraIDs.firstIndex(of: a.uuid) {
                                            Text("\(idx + 2)").font(.caption2.bold()).foregroundStyle(.white)
                                                .frame(width: 20, height: 20).background(DS.green, in: Circle()).padding(4)
                                        }
                                    }
                                Text(a.filename).font(DS.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 640, height: 480)
        .background(DS.panel)
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
    @State private var confirmPublishNow = false

    var body: some View {
        @Bindable var c = model.composer
        let enabled = c.variants.filter(\.enabled)
        let blocked = enabled.filter { v in c.issues(v, model: model).contains { $0.level == .error } }
        let ready = enabled.filter { v in !c.issues(v, model: model).contains { $0.level == .error } }
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
                                VStack(alignment: .leading, spacing: 2) {
                                    if accounts.isEmpty {
                                        HStack {
                                            Text("No \(PlatformRegistry.spec(v.platform)?.name ?? v.platform) account").font(DS.body).foregroundStyle(DS.text2)
                                            Button("Connect") { model.page = .accounts }.buttonStyle(LinkButtonStyle())
                                        }
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
                if enabled.contains(where: { $0.platform == "youtube" }) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("YouTube options")
                        Picker("Type", selection: $c.youtubeKind) {
                            Text("Video").tag("video")
                            Text("Short (vertical)").tag("short")
                        }
                        Picker("Visibility", selection: $c.youtubeVisibility) {
                            Text("Public").tag("public")
                            Text("Unlisted").tag("unlisted")
                            Text("Private").tag("private")
                        }
                        Toggle("Made for kids", isOn: $c.youtubeMadeForKids).toggleStyle(SFToggleStyle()).font(DS.body)
                    }
                }
                if enabled.contains(where: { $0.platform == "tiktok" }) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("TikTok options")
                        Picker("Upload mode", selection: $c.tiktokMode) {
                            Text("Inbox Draft (recommended)").tag("inbox")
                            Text("Direct Post").tag("direct")
                        }
                        Picker("Privacy", selection: $c.tiktokPrivacy) {
                            Text("Only Me").tag("SELF_ONLY")
                            Text("Friends").tag("MUTUAL_FOLLOW_FRIENDS")
                            Text("Public").tag("PUBLIC_TO_EVERYONE")
                        }
                        Toggle("Contains promotional content", isOn: $c.tiktokDisclosePromo).toggleStyle(SFToggleStyle()).font(DS.body)
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Schedule")
                    DatePicker("Publish", selection: $c.when).font(DS.body)
                    Picker("Time zone", selection: $c.timeZoneID) {
                        ForEach(BulkPipelinePanel.zones, id: \.self) { Text($0).tag($0) }
                    }
                    .font(DS.body)
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
                    } else if !ready.isEmpty {
                        Label("\(ready.count) of \(enabled.count) platforms ready to schedule independently.", systemImage: "checkmark.circle").font(DS.small).foregroundStyle(DS.amber)
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
                        let made = c.save(model: model, status: .draft)
                        c.message = "Saved \(made.count) draft\(made.count == 1 ? "" : "s")."
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(enabled.isEmpty)
                    Button("Send to review") {
                        let made = c.save(model: model, status: .needsReview)
                        c.message = "Saved \(made.count) version\(made.count == 1 ? "" : "s") in Needs Review."
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(enabled.isEmpty)
                }
                Button("Approve and schedule (\(ready.count))") {
                    let made = c.save(model: model, status: .approved)
                    let ok = made.filter { $0.status == .approved }
                    Task {
                        let r = await model.activate(ok)
                        c.message = "Scheduled \(r.sent) of \(made.count)." + (made.count > ok.count ? " Versions with problems stay in review." : "") + (r.failed.isEmpty ? "" : " " + r.failed.joined(separator: " "))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(ready.isEmpty)
                Button("Publish now…") { confirmPublishNow = true }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(ready.isEmpty)
            }
            .padding(Space.xl)
        }
        .confirmationDialog("Publish now to \(ready.count) account\(ready.count == 1 ? "" : "s")?", isPresented: $confirmPublishNow, titleVisibility: .visible) {
            Button("Publish Now", role: .destructive) {
                c.when = .now.addingTimeInterval(5)
                let made = c.save(model: model, status: .approved).filter { $0.status == .approved }
                Task {
                    let r = await model.activate(made)
                    c.message = r.sent > 0 ? "Publishing \(r.sent) now. Track status in Calendar & Queue." : "Nothing could be published: fix the problems first."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let names = ready.map { v in
                let acct = model.accounts.first { $0.serverID == v.accountID }?.name ?? v.platform.capitalized
                let plat = PlatformRegistry.spec(v.platform)?.name ?? v.platform
                return "\(acct) (\(plat))"
            }.joined(separator: ", ")
            Text("This will immediately publish to: \(names).")
        }
    }
}

extension AppModel {
    func campaign(_ id: UUID?) -> Campaign? {
        guard let id else { return nil }
        return (try? context.fetch(FetchDescriptor<Campaign>(predicate: #Predicate { $0.uuid == id })))?.first
    }
}

import Foundation
import Observation
import SwiftData
import SocialForgeKit

/// The Bulk Publisher's working state: which images, which CSV, how they
/// match, where they go, and when. "Create posts" turns it into Publication
/// rows (Needs Review), which survive a restart.
@Observable
final class BulkSession {
    var assetIDs: [UUID] = []
    var csvName: String?
    var table: CSVTable?
    var csvError: String?
    var mapping = ColumnMapping()
    var strategy: MatchStrategy = .filename
    var report: MatchReport?

    var accountID: String?
    /// Multi-account selection for bulk runs across any connected platform.
    var selectedAccountIDs: Set<String> = []
    var boardID: String?
    var campaignID: UUID?
    var presetID: String? = ExportPreset.builtIn[0].id
    /// Use the CSV's links and copy (the design's "Product links from CSV").
    var useCSV = true

    var rule = ScheduleRule(timeZoneID: TimeZone.current.identifier,
                            start: LocalDay(Calendar.current.date(byAdding: .day, value: 1, to: .now)!, in: .current),
                            times: [LocalTime(9)])
    var runName = "Bulk run"

    /// Saved bulk preset recipe for repeatable agency/creator batch workflows.
    struct Recipe: Codable, Equatable, Identifiable {
        var id: String = UUID().uuidString
        var name: String
        var rule: ScheduleRule
        var presetID: String?
        var useCSV: Bool
    }

    private static let recipesKey = "bulk.recipes.v1"

    static func savedRecipes() -> [Recipe] {
        guard let data = UserDefaults.standard.data(forKey: recipesKey),
              let list = try? JSONDecoder().decode([Recipe].self, from: data) else { return [] }
        return list
    }

    func saveRecipe(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var all = Self.savedRecipes().filter { $0.name != clean }
        all.insert(Recipe(name: clean, rule: rule, presetID: presetID, useCSV: useCSV), at: 0)
        if let data = try? JSONEncoder().encode(Array(all.prefix(20))) {
            UserDefaults.standard.set(data, forKey: Self.recipesKey)
        }
    }

    func applyRecipe(_ recipe: Recipe) {
        rule = recipe.rule
        presetID = recipe.presetID
        useCSV = recipe.useCSV
        runName = recipe.name
    }

    func resetForWorkspaceSwitch() {
        assetIDs = []
        csvName = nil
        table = nil
        csvError = nil
        report = nil
        accountID = nil
        selectedAccountIDs = []
        boardID = nil
        campaignID = nil
        runName = "Bulk run"
    }

    /// Resolves all target accounts selected for this bulk run (falls back to single `accountID`).
    @MainActor
    func targetAccounts(model: AppModel) -> [SocialAccount] {
        let ids = selectedAccountIDs.isEmpty ? (accountID.map { Set([$0]) } ?? []) : selectedAccountIDs
        return model.accounts.filter { ids.contains($0.serverID) }
    }

    func loadCSV(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
            guard let text else {
                csvError = "Could not decode \(url.lastPathComponent) as text."
                return
            }
            let t = try CSVTable.parse(text)
            table = t
            csvName = url.lastPathComponent
            mapping = ColumnMapping.guess(from: t.header)
            csvError = nil
            runName = url.deletingPathExtension().lastPathComponent
        } catch let e as CSVTable.ParseError {
            csvError = switch e {
            case .empty: "\(url.lastPathComponent) has no rows."
            case .unterminatedQuote(let line): "\(url.lastPathComponent): a quote opened near line \(line) is never closed."
            }
        } catch {
            csvError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func rematch(assets: [MediaAsset]) {
        guard let table else { report = nil; return }
        let candidates = assets.map { MatchCandidate(id: $0.uuid.uuidString, filename: $0.filename) }
        report = MetadataMatcher.match(media: candidates, table: table, mapping: mapping, strategy: strategy)
    }

    /// Makes one Needs Review post per image, in image order, on the rule's
    /// slots. Images without a CSV row still get a post, with empty fields to
    /// fill. Ambiguous images are left out and listed.
    func createPosts(model: AppModel, assets: [MediaAsset], account: SocialAccount?, board: API.Board?) throws -> [Publication] {
        guard let workspaceID = model.workspaceID else { return [] }
        let ambiguous = useCSV ? Set(report?.ambiguous.keys.map { $0 } ?? []) : []
        let usable = assets.filter { !ambiguous.contains($0.uuid.uuidString) }
        let after = existingQueueEnd(model: model, accountID: account?.serverID)
        let slots = try ScheduleBuilder.slots(rule, count: usable.count, after: after)
        let rows = Dictionary((report?.matched ?? []).map { ($0.mediaID, $0) }, uniquingKeysWith: { a, _ in a })
        let variantsMap = model.variantsByAsset()
        var made: [Publication] = []
        let campaign = model.campaign(campaignID)
        for (asset, slot) in zip(usable, slots) {
            let p = Publication(workspaceID: workspaceID, scheduledAt: slot.instant, timeZoneID: rule.timeZoneID)
            p.assetID = asset.uuid
            p.platform = account?.platform ?? "pinterest"
            p.accountID = account?.serverID ?? ""
            p.accountName = account?.name ?? ""
            p.boardID = account?.platform == "pinterest" ? (board?.id ?? "") : ""
            p.boardName = account?.platform == "pinterest" ? (board?.name ?? "") : ""
            p.campaignID = campaignID
            let row = useCSV ? rows[asset.uuid.uuidString] : nil
            p.title = row?.title.nonEmpty ?? asset.title.nonEmpty ?? Self.titleFromFilename(asset.filename)
            p.desc = row?.description.nonEmpty ?? asset.notes
            let rawLink = row?.url.nonEmpty ?? asset.productURL
            if let campaign, !rawLink.isEmpty {
                let src = campaign.perPlatformUTMSource ? p.platform : campaign.utmSource
                p.link = UTM.apply(to: rawLink, source: src, medium: campaign.utmMedium, campaign: campaign.utmCampaign)
            } else {
                p.link = rawLink
            }
            p.altText = row?.altText.nonEmpty ?? asset.altText
            if let presetID, let v = (variantsMap[asset.uuid] ?? []).first(where: { $0.presetID == presetID }) { p.variantID = v.uuid }
            p.runName = runName
            p.status = .needsReview
            model.context.insert(p)
            made.append(p)
        }
        model.saveContext("bulkCreatePosts")
        model.log("Created \(made.count) posts in “\(runName)”", symbol: "square.stack.3d.up", category: "publishing")
        return made
    }

    /// Creates Needs Review posts for one or more selected accounts across any connected platform.
    @MainActor
    func createPostsForSelectedAccounts(model: AppModel, assets: [MediaAsset]) throws -> [Publication] {
        let targets = targetAccounts(model: model)
        if targets.isEmpty {
            return try createPosts(model: model, assets: assets, account: nil, board: nil)
        }
        var all: [Publication] = []
        for acct in targets {
            let board = acct.platform == "pinterest"
                ? (model.boards[acct.serverID]?.first { $0.id == boardID } ?? model.boards[acct.serverID]?.first)
                : nil
            all += try createPosts(model: model, assets: assets, account: acct, board: board)
        }
        return all
    }

    /// The latest post already queued for this account, so new posts go after it.
    func existingQueueEnd(model: AppModel, accountID: String?) -> Date? {
        guard let workspaceID = model.workspaceID, let accountID, !accountID.isEmpty else { return nil }
        let live = ["approved", "scheduled", "needsReview"]
        let pubs = (try? model.context.fetch(FetchDescriptor<Publication>(predicate: #Predicate {
            $0.workspaceID == workspaceID && $0.accountID == accountID
        }))) ?? []
        return pubs.filter { live.contains($0.statusRaw) }.map(\.scheduledAt).max()
    }

    /// Moves posts onto new slots of the rule, keeping media and copy.
    func reschedule(_ pubs: [Publication]) throws {
        let ordered = pubs.sorted { $0.scheduledAt < $1.scheduledAt }
        let slots = try ScheduleBuilder.slots(rule, count: ordered.count)
        for (p, s) in zip(ordered, slots) where p.status.isLocal {
            p.scheduledAt = s.instant
            p.timeZoneID = rule.timeZoneID
            p.updatedAt = .now
        }
    }

    /// "oe-winter_mug-fog.jpg" -> "Oe Winter Mug Fog"
    static func titleFromFilename(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).capitalized
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Validation for one stored post, from the shared registry.
extension Publication {
    @MainActor
    func issues(model: AppModel) -> [ValidationIssue] {
        let asset = model.asset(assetID, in: workspaceID)
        let isVideo = asset?.kind == "video"
        let variant = (!isVideo ? asset.flatMap { a in model.variants(of: a.uuid).first { $0.uuid == variantID } } : nil)
        let hasHost = PublicMediaSettings.config() != nil
        var draft = PostDraft(
            platform: platform, title: title, description: desc, link: link, altText: altText,
            destinationID: boardID.isEmpty ? nil : boardID,
            image: isVideo ? nil : (variant?.imageFacts ?? asset?.imageFacts),
            isVideo: isVideo,
            hasPublicMediaHost: hasHost
        )
        if assetID != nil, asset == nil { draft.image = nil }
        var out = PostValidator.validate(draft)
        if let asset, isVideo {
            out += PostValidator.validateVideo(
                platform: platform, seconds: asset.duration, width: asset.width, height: asset.height,
                bytes: asset.bytes, format: asset.format, requireShortsAspect: platform == "youtube" && metadata["youtube_kind"] == "short"
            )
        }
        if assetID != nil, asset == nil { out.append(ValidationIssue(.error, "image", "The media file is missing from the library.")) }
        else if let asset, !asset.fileExists { out.append(ValidationIssue(.error, "image", "The media file “\(asset.filename)” cannot be found on disk.")) }
        if accountID.isEmpty { out.append(ValidationIssue(.error, "account", "Choose an account.")) }
        if let acct = model.accounts.first(where: { $0.serverID == accountID }) {
            for c in acct.capabilities where !c.allowed { out.append(ValidationIssue(.error, "account", c.reason ?? "Not allowed.")) }
        }
        if status.isLocal, scheduledAt < .now { out.append(ValidationIssue(.error, "schedule", "The time is in the past.")) }
        return out
    }

    @MainActor
    func hasErrors(model: AppModel) -> Bool { issues(model: model).contains { $0.level == .error } }
}

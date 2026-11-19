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
    var boardID: String?
    var presetID: String? = ExportPreset.builtIn[0].id
    /// Use the CSV's links and copy (the design's "Product links from CSV").
    var useCSV = true

    var rule = ScheduleRule(timeZoneID: TimeZone.current.identifier,
                            start: LocalDay(Calendar.current.date(byAdding: .day, value: 1, to: .now)!, in: .current),
                            times: [LocalTime(9)])
    var runName = "Bulk run"

    func loadCSV(_ url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
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
        let ambiguous = Set(report?.ambiguous.keys.map { $0 } ?? [])
        let usable = assets.filter { !ambiguous.contains($0.uuid.uuidString) }
        let after = existingQueueEnd(model: model, accountID: account?.serverID)
        let slots = try ScheduleBuilder.slots(rule, count: usable.count, after: after)
        let rows = Dictionary((report?.matched ?? []).map { ($0.mediaID, $0) }, uniquingKeysWith: { a, _ in a })
        var made: [Publication] = []
        for (asset, slot) in zip(usable, slots) {
            let p = Publication(workspaceID: workspaceID, scheduledAt: slot.instant, timeZoneID: rule.timeZoneID)
            p.assetID = asset.uuid
            p.platform = account?.platform ?? "pinterest"
            p.accountID = account?.serverID ?? ""
            p.accountName = account?.name ?? ""
            p.boardID = board?.id ?? ""
            p.boardName = board?.name ?? ""
            let row = useCSV ? rows[asset.uuid.uuidString] : nil
            p.title = row?.title.nonEmpty ?? asset.title.nonEmpty ?? Self.titleFromFilename(asset.filename)
            p.desc = row?.description.nonEmpty ?? asset.notes
            p.link = row?.url.nonEmpty ?? asset.productURL
            p.altText = row?.altText.nonEmpty ?? asset.altText
            if let presetID, let v = model.variants(of: asset.uuid).first(where: { $0.presetID == presetID }) { p.variantID = v.uuid }
            p.runName = runName
            p.status = .needsReview
            model.context.insert(p)
            made.append(p)
        }
        try? model.context.save()
        model.log("Created \(made.count) posts in “\(runName)”", symbol: "square.stack.3d.up")
        return made
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
        let asset = model.asset(assetID)
        let variant = asset.flatMap { a in model.variants(of: a.uuid).first { $0.uuid == variantID } }
        var draft = PostDraft(platform: platform, title: title, description: desc, link: link, altText: altText,
                              destinationID: boardID.isEmpty ? nil : boardID,
                              image: variant?.imageFacts ?? asset?.imageFacts)
        if assetID != nil, asset == nil { draft.image = nil }
        var out = PostValidator.validate(draft)
        if assetID != nil, asset == nil { out.append(ValidationIssue(.error, "image", "The image is missing from the library.")) }
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

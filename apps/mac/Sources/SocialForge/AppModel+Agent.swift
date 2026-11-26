import Foundation
import SwiftData
import SocialForgeKit

/// Re-entrancy lock so periodic polling ticks never process the same Agent Inbox file twice concurrently.
private enum AgentInboxGate {
    @MainActor static var isProcessing = false
}

/// Applies what agents queued through `SocialForge --mcp` (see AgentMCP.swift).
extension AppModel {
    var agentInbox: AgentInbox { AgentInbox(root: Store.inboxURL) }

    /// Applies every waiting request, oldest first. Returns how many it handled.
    @discardableResult
    func processAgentInbox() async -> Int {
        guard !AgentInboxGate.isProcessing else { return 0 }
        AgentInboxGate.isProcessing = true
        defer { AgentInboxGate.isProcessing = false }
        let inbox = agentInbox
        let waiting = inbox.pending()
        for request in waiting {
            let result = await applyAgentRequest(request)
            try? inbox.finish(result)
        }
        if !waiting.isEmpty { inbox.prune() }
        return waiting.count
    }

    func applyAgentRequest(_ r: AgentRequest) async -> AgentResult {
        if let problem = AgentTools.problem(tool: r.tool, args: r.args) { return AgentResult(request: r, ok: false, message: problem) }
        switch r.tool {
        case "import_media": return await agentImport(r)
        case "create_posts": return await agentCreatePosts(r)
        case "create_campaign_draft": return agentCreateCampaign(r)
        case "update_media": return agentUpdateMedia(r)
        default: return AgentResult(request: r, ok: false, message: "SocialForge does not know \(r.tool).")
        }
    }

    private func agentBrand(_ r: AgentRequest) -> Workspace? {
        AgentLibrary.workspace(r.args["brand"]?.stringValue, context, current: workspaceID)
    }

    /// Imported files, plus the ones already in the brand's library (matched by content), in path order.
    private func agentMedia(_ urls: [URL], into ws: UUID) async -> [MediaAsset] {
        let made = await importMedia(urls, into: ws)
        let inBrand = (try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == ws }))) ?? []
        var byHash = Dictionary(inBrand.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        for a in made { byHash[a.sha256] = a }
        var out: [MediaAsset] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
                out += made.filter { $0.sourcePath.hasPrefix(prefix) }
            } else if let hash = try? ContentHash.sha256(of: url), let a = byHash[hash], !out.contains(where: { $0.uuid == a.uuid }) {
                out.append(a)
            }
        }
        return out
    }

    /// Resolves each file path to its MediaAsset in `ws` (handling shared/duplicate files across posts safely).
    private func agentMediaByPath(_ urls: [URL], into ws: UUID) async -> [String: MediaAsset] {
        let uniqueURLs = Array(Dictionary(urls.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }).values)
        _ = await importMedia(uniqueURLs, into: ws)
        let inBrand = (try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == ws }))) ?? []
        let byHash = Dictionary(inBrand.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: MediaAsset] = [:]
        for url in uniqueURLs {
            if let hash = try? ContentHash.sha256(of: url), let a = byHash[hash] {
                out[url.path] = a
            }
        }
        return out
    }

    private func agentImport(_ r: AgentRequest) async -> AgentResult {
        guard let ws = agentBrand(r) else { return AgentResult(request: r, ok: false, message: "That brand no longer exists.") }
        let urls = (r.args["paths"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(fileURLWithPath: $0) }
        let media = await agentMedia(urls, into: ws.uuid)
        guard !media.isEmpty else { return AgentResult(request: r, ok: false, message: "Nothing was imported: no image, video, or audio files found.") }
        let collection = r.args["collection"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let tags = (r.args["tags"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        for a in media {
            if !collection.isEmpty { a.collection = collection }
            for t in tags where !a.tags.contains(t) { a.tags.append(t) }
        }
        try? context.save()
        logAgent("\(r.client) added \(media.count) \(media.count == 1 ? "file" : "files") to \(ws.name)", in: ws.uuid)
        return AgentResult(request: r, ok: true, message: "\(media.count) media in \(ws.name)'s library.", createdIDs: media.map(\.uuid.uuidString))
    }

    private func agentCreatePosts(_ r: AgentRequest) async -> AgentResult {
        guard let ws = agentBrand(r) else { return AgentResult(request: r, ok: false, message: "That brand no longer exists.") }
        let wsID = ws.uuid
        let reqID = r.id.uuidString
        // Crash-recovery idempotency: if this request was already persisted before a crash, never create duplicate posts.
        let existingForRequest = (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate {
            $0.workspaceID == wsID && $0.agentRequestID == reqID
        }))) ?? []
        if !existingForRequest.isEmpty {
            return AgentResult(request: r, ok: true,
                               message: "\(existingForRequest.count) post\(existingForRequest.count == 1 ? "" : "s") already created for this request in Needs Review for \(ws.name).",
                               createdIDs: existingForRequest.map(\.uuid.uuidString))
        }

        let accounts = (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate { $0.workspaceID == wsID }))) ?? []
        let specs = (r.args["posts"]?.arrayValue ?? []).compactMap(\.objectValue)

        // Check every post before making any, so a request is all or nothing.
        var planned: [(spec: [String: JSONValue], account: SocialAccount, media: MediaAsset?, file: URL?, when: Date, zone: String)] = []
        for (i, p) in specs.enumerated() {
            let ref = p["account_id"]?.stringValue ?? ""
            guard let account = accounts.first(where: { $0.serverID == ref }) ?? accounts.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) else {
                return AgentResult(request: r, ok: false, message: "Post \(i + 1): no account \(ref) in \(ws.name). Nothing was created.")
            }
            var media: MediaAsset?
            if let raw = p["media_id"]?.stringValue, !raw.isEmpty {
                guard let a = asset(UUID(uuidString: raw)), a.workspaceID == wsID else {
                    return AgentResult(request: r, ok: false, message: "Post \(i + 1): no media \(raw) in \(ws.name). Nothing was created.")
                }
                media = a
            }
            let zone = p["time_zone"]?.stringValue.flatMap { TimeZone(identifier: $0) } ?? .current
            guard let when = AgentTools.date(p["scheduled_at"]?.stringValue ?? "", timeZone: zone) else {
                return AgentResult(request: r, ok: false, message: "Post \(i + 1): bad scheduled_at. Nothing was created.")
            }
            let file = media == nil ? p["file"]?.stringValue.map { URL(fileURLWithPath: $0) } : nil
            planned.append((p, account, media, file, when, zone.identifier))
        }

        let files = planned.compactMap(\.file)
        let byPath = files.isEmpty ? [:] : await agentMediaByPath(files, into: wsID)
        let missingFiles = files.filter { byPath[$0.path] == nil }
        if !missingFiles.isEmpty {
            return AgentResult(request: r, ok: false,
                               message: "Could not import \(missingFiles.count) file(s), so no posts were created.",
                               createdIDs: Array(Set(byPath.values.map(\.uuid.uuidString))))
        }

        var made: [Publication] = []
        for plan in planned {
            let s = plan.spec
            let media = plan.media ?? plan.file.flatMap { byPath[$0.path] }
            let p = Publication(workspaceID: wsID, scheduledAt: plan.when, timeZoneID: plan.zone)
            p.assetID = media?.uuid
            p.platform = plan.account.platform
            p.accountID = plan.account.serverID
            p.accountName = plan.account.name
            p.boardID = s["board_id"]?.stringValue ?? ""
            p.title = s["title"]?.stringValue ?? media?.title.nonEmpty ?? ""
            p.desc = s["description"]?.stringValue ?? ""
            p.link = s["link"]?.stringValue ?? media?.productURL ?? ""
            p.altText = s["alt_text"]?.stringValue ?? media?.altText ?? ""
            if let cid = s["campaign_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                p.campaignID = cid
            }
            p.runName = "From \(r.client)"
            p.agentRequestID = reqID
            // Agents never approve: the person does, in the review queue.
            p.status = .needsReview
            context.insert(p)
            made.append(p)
        }
        try? context.save()
        logAgent("\(r.client) added \(made.count) \(made.count == 1 ? "post" : "posts") to review", in: wsID)
        return AgentResult(request: r, ok: true, message: "\(made.count) \(made.count == 1 ? "post" : "posts") in Needs Review for \(ws.name).",
                           createdIDs: made.map(\.uuid.uuidString))
    }

    private func agentCreateCampaign(_ r: AgentRequest) -> AgentResult {
        guard let ws = agentBrand(r) else { return AgentResult(request: r, ok: false, message: "That brand no longer exists.") }
        let name = r.args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return AgentResult(request: r, ok: false, message: "Campaign name is required.") }
        let start = r.args["start_date"]?.stringValue.flatMap { AgentTools.date($0, timeZone: .current) } ?? .now
        let end = r.args["end_date"]?.stringValue.flatMap { AgentTools.date($0, timeZone: .current) }
            ?? Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start.addingTimeInterval(14 * 86_400)
        let c = Campaign(workspaceID: ws.uuid, name: name)
        c.startDate = start
        c.endDate = max(start, end)
        c.goal = r.args["goal"]?.stringValue ?? ""
        if let src = r.args["utm_source"]?.stringValue, !src.isEmpty { c.utmSource = src }
        if let med = r.args["utm_medium"]?.stringValue, !med.isEmpty { c.utmMedium = med }
        if let cmp = r.args["utm_campaign"]?.stringValue, !cmp.isEmpty { c.utmCampaign = cmp }
        context.insert(c)
        try? context.save()
        logAgent("\(r.client) created draft campaign \"\(c.name)\"", in: ws.uuid)
        return AgentResult(request: r, ok: true, message: "Created campaign \"\(c.name)\" in \(ws.name).", createdIDs: [c.uuid.uuidString])
    }

    private func agentUpdateMedia(_ r: AgentRequest) -> AgentResult {
        guard let a = asset(r.args["media_id"]?.stringValue.flatMap(UUID.init(uuidString:))) else {
            return AgentResult(request: r, ok: false, message: "No media with that id.")
        }
        // Enforce brand scope whenever brand was supplied or pinned.
        if let brandRef = r.args["brand"]?.stringValue, !brandRef.isEmpty {
            guard let ws = AgentLibrary.workspace(brandRef, context, current: workspaceID), a.workspaceID == ws.uuid else {
                return AgentResult(request: r, ok: false, message: "Media item does not belong to that brand.")
            }
        }
        if let v = r.args["title"]?.stringValue { a.title = v }
        if let v = r.args["alt_text"]?.stringValue { a.altText = v }
        if let v = r.args["product_url"]?.stringValue { a.productURL = v }
        if let v = r.args["collection"]?.stringValue { setCollection(v, for: [a]) }
        if let v = r.args["tags"]?.arrayValue { a.tags = v.compactMap(\.stringValue).filter { !$0.isEmpty } }
        try? context.save()
        logAgent("\(r.client) updated \(a.filename)", in: a.workspaceID)
        return AgentResult(request: r, ok: true, message: "Updated \(a.filename).", createdIDs: [a.uuid.uuidString])
    }

    private func logAgent(_ text: String, in ws: UUID) {
        context.insert(ActivityEntry(workspaceID: ws, text: text, symbol: "tray.and.arrow.down", category: "agent"))
        try? context.save()
    }
}

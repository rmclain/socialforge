import AppKit
import SwiftData
import SocialForgeKit

/// `SocialForge --mcp`: an MCP server on stdin and stdout for Claude Code, Codex, and other agents.
///
/// Reads (brands, accounts, media, posts) open the library read-only. Changes never touch the
/// library from here: they go to the Agent Inbox, and the open app applies them
/// (`AppModel.processAgentInbox`), so agent posts always land in Needs Review for the person to approve.
enum AgentMCP {
    static var requested: Bool { CommandLine.arguments.contains("--mcp") }

    static let instructions = """
    SocialForge is a Mac app that schedules social media posts. Use list_brands, list_accounts, list_media, and \
    list_posts to look around. import_media, create_posts, and update_media are queued: SocialForge applies them \
    while it is open (within a few seconds) or the next time it opens, and every post you make waits in Needs Review \
    until the person approves it. Use get_request_status with the request id to see the result and the new ids.
    """

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var container: ModelContainer? = try? ModelContainer(for: SwiftData.Schema(AppSchema.models),
                                                             configurations: ModelConfiguration(url: Store.url, allowsSave: false))
        let inbox = AgentInbox(root: Store.inboxURL)
        var session = MCPSession(serverName: "socialforge", serverVersion: UpdateSettings.currentVersion,
                                 instructions: instructions, tools: AgentTools.all) { name, args, client in
            if container == nil {
                container = try? ModelContainer(for: SwiftData.Schema(AppSchema.models),
                                                configurations: ModelConfiguration(url: Store.url, allowsSave: false))
            }
            guard let container else { return MCPToolOutcome("SocialForge's library could not be opened. Open SocialForge once, then try again.", isError: true) }
            // A fresh context per call, so each answer sees what the app saved since the last one.
            return handle(name, args: args, client: client, context: ModelContext(container), inbox: inbox)
        }
        while let line = readLine(strippingNewline: true) {
            if line.utf8.count > 2 * 1024 * 1024 {
                let err = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request exceeds 2 MB limit"}}"#
                FileHandle.standardOutput.write(Data((err + "\n").utf8))
                continue
            }
            if let reply = session.handle(line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
        exit(0)
    }

    static func handle(_ name: String, args: [String: JSONValue], client: String, context: ModelContext, inbox: AgentInbox) -> MCPToolOutcome {
        if AgentTools.tool(name)?.queued == true { return enqueue(name, args: args, client: client, context: context, inbox: inbox) }
        switch name {
        case "list_brands":
            let fallback = AgentLibrary.workspace(nil, context)?.uuid
            let all = AgentLibrary.workspaces(context)
            let assets = (try? context.fetch(FetchDescriptor<MediaAsset>())) ?? []
            let accounts = (try? context.fetch(FetchDescriptor<SocialAccount>())) ?? []
            return json(all.map { w in
                ["id": .string(w.uuid.uuidString), "name": .string(w.name),
                 "default": .bool(w.uuid == fallback),
                 "media_count": .number(Double(assets.count { $0.workspaceID == w.uuid })),
                 "account_count": .number(Double(accounts.count { $0.workspaceID == w.uuid }))]
            })
        case "list_accounts":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let accounts = (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.name)]))) ?? []
            return json(accounts.map { a in
                ["id": .string(a.serverID), "platform": .string(a.platform), "name": .string(a.name), "handle": .string(a.handle),
                 "status": .string(a.status), "test_account": .bool(a.isMock)]
            }, empty: "\(ws.name) has no connected accounts yet. The person connects them in SocialForge > Accounts.")
        case "list_media", "search_media":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            var items = (try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))) ?? []
            if let q = args["query"]?.stringValue, !q.isEmpty {
                items = items.filter {
                    $0.filename.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q)
                        || $0.notes.localizedCaseInsensitiveContains(q)
                        || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
                }
            }
            if let c = args["collection"]?.stringValue, !c.isEmpty { items = items.filter { $0.collection.caseInsensitiveCompare(c) == .orderedSame } }
            if let k = args["kind"]?.stringValue, !k.isEmpty { items = items.filter { $0.kind == k } }
            return json(items.prefix(limit(args)).map { a in
                ["id": .string(a.uuid.uuidString), "filename": .string(a.filename), "kind": .string(a.kind), "title": .string(a.title),
                 "alt_text": .string(a.altText), "product_url": .string(a.productURL), "collection": .string(a.collection),
                 "tags": .array(a.tags.map(JSONValue.string)), "width": .number(Double(a.width)), "height": .number(Double(a.height)),
                 "path": .string(a.storedPath), "imported_at": .string(AgentTools.iso(a.importedAt))]
            }, empty: "No media matches in \(ws.name).")
        case "list_campaigns":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let campaigns = (try? context.fetch(FetchDescriptor<Campaign>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.startDate, order: .reverse)]))) ?? []
            let posts = (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == id }))) ?? []
            return json(campaigns.map { c in
                let count = posts.count { $0.campaignID == c.uuid }
                return ["id": .string(c.uuid.uuidString), "name": .string(c.name), "goal": .string(c.goal),
                        "start_date": .string(AgentTools.iso(c.startDate)), "end_date": .string(AgentTools.iso(c.endDate)),
                        "utm_source": .string(c.utmSource), "utm_medium": .string(c.utmMedium), "utm_campaign": .string(c.utmCampaign),
                        "post_count": .number(Double(count))]
            }, empty: "No campaigns in \(ws.name).")
        case "list_templates":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let templates = (try? context.fetch(FetchDescriptor<CreativeTemplate>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.name)]))) ?? []
            return json(templates.map { t in
                let doc = t.document
                return ["id": .string(t.uuid.uuidString), "name": .string(t.name), "category": .string(t.category),
                        "width": .number(Double(doc?.width ?? 0)), "height": .number(Double(doc?.height ?? 0))]
            }, empty: "No templates in \(ws.name).")
        case "list_platforms":
            return json(PlatformRegistry.all.map { spec in
                ["id": .string(spec.id), "name": .string(spec.name), "status": .string(spec.status),
                 "live_verified": .bool(spec.liveVerified),
                 "content_types": .array(spec.contentTypes.map { .string($0.id) })]
            })
        case "list_boards":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let acctID = args["account_id"]?.stringValue ?? ""
            let posts = (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == id }))) ?? []
            let boardIDs = Array(Set(posts.filter { (acctID.isEmpty || $0.accountID == acctID) && !$0.boardID.isEmpty }.map(\.boardID))).sorted()
            return json(boardIDs.map { ["board_id": .string($0)] }, empty: "No boards cached locally for \(ws.name). Open SocialForge to refresh boards from Pinterest.")
        case "inspect_account_capabilities":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let acctRef = args["account_id"]?.stringValue ?? ""
            let accounts = (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate { $0.workspaceID == id }))) ?? []
            let matched = acctRef.isEmpty ? accounts : accounts.filter { $0.serverID == acctRef || $0.name.caseInsensitiveCompare(acctRef) == .orderedSame }
            let hasStorage = PublicMediaSettings.config() != nil
            return json(matched.map { a in
                let caps = a.capabilities
                let missing = Array(Set(caps.flatMap(\.missingScopes))).sorted()
                let supported = caps.filter(\.allowed).map(\.contentType.id)
                var limits: [String] = []
                if a.authMode == "sandbox" { limits.append("Sandbox mode") }
                if !hasStorage && ["instagram", "threads"].contains(a.platform) { limits.append("Requires S3/R2 public media storage") }
                return ["id": .string(a.serverID), "platform": .string(a.platform), "name": .string(a.name),
                        "status": .string(a.connectionStatus.rawValue), "account_type": .string(a.accountType),
                        "auth_mode": .string(a.authMode),
                        "granted_scopes": .array(a.scopes.map(JSONValue.string)),
                        "missing_scopes": .array(missing.map(JSONValue.string)),
                        "supported_content_types": .array(supported.map(JSONValue.string)),
                        "limitations": .array(limits.map(JSONValue.string))]
            }, empty: "No matching account in \(ws.name).")
        case "validate_posts":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let statusFilter = args["status"]?.stringValue
            let posts = ((try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == id }))) ?? []).filter { p in
                if let statusFilter, !statusFilter.isEmpty { return p.statusRaw == statusFilter }
                return p.status == .draft || p.status == .needsReview
            }
            let assets = Dictionary(((try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == id }))) ?? []).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
            let hasStorage = PublicMediaSettings.config() != nil
            return json(posts.prefix(limit(args)).map { p in
                let a = p.assetID.flatMap { assets[$0] }
                let isVideo = a?.kind == "video"
                let draft = PostDraft(
                    platform: p.platform, title: p.title, description: p.desc, link: p.link, altText: p.altText,
                    destinationID: p.boardID.isEmpty ? nil : p.boardID,
                    image: isVideo ? nil : a?.imageFacts,
                    isVideo: isVideo,
                    hasPublicMediaHost: hasStorage
                )
                var issues = PostValidator.validate(draft)
                if let a, isVideo {
                    issues += PostValidator.validateVideo(platform: p.platform, seconds: a.duration, width: a.width, height: a.height, bytes: a.bytes, format: a.format)
                }
                return ["post_id": .string(p.uuid.uuidString), "platform": .string(p.platform), "status": .string(p.statusRaw),
                        "error_count": .number(Double(issues.count { $0.level == .error })),
                        "warning_count": .number(Double(issues.count { $0.level == .warning })),
                        "issues": .array(issues.map { .object(["severity": .string($0.level == .error ? "error" : "warning"), "message": .string($0.message)]) })]
            }, empty: "No posts to validate in \(ws.name).")
        case "inspect_schedule_availability":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            let days = min(90, max(1, Int(args["days"]?.numberValue ?? 14)))
            let now = Date()
            let cal = Calendar.current
            let start = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
            let posts = ((try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == id }))) ?? [])
                .filter { $0.scheduledAt >= start && $0.scheduledAt < end && $0.status != .canceled }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            var counts: [String: Int] = [:]
            for p in posts { counts[fmt.string(from: p.scheduledAt), default: 0] += 1 }
            var rows: [[String: JSONValue]] = []
            for offset in 0..<days {
                if let d = cal.date(byAdding: .day, value: offset, to: start) {
                    let key = fmt.string(from: d)
                    rows.append(["date": .string(key), "scheduled_count": .number(Double(counts[key, default: 0]))])
                }
            }
            return json(rows)
        case "list_posts":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            var posts = (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.scheduledAt)]))) ?? []
            if let s = args["status"]?.stringValue, !s.isEmpty { posts = posts.filter { $0.statusRaw == s } }
            if let f = args["from"]?.stringValue.flatMap({ AgentTools.date($0, timeZone: .current) }) { posts = posts.filter { $0.scheduledAt >= f } }
            if let t = args["to"]?.stringValue.flatMap({ AgentTools.date($0, timeZone: .current) }) { posts = posts.filter { $0.scheduledAt < t } }
            return json(posts.prefix(limit(args)).map { p in
                ["id": .string(p.uuid.uuidString), "platform": .string(p.platform), "account": .string(p.accountName),
                 "account_id": .string(p.accountID), "status": .string(p.statusRaw), "title": .string(p.title),
                 "description": .string(p.desc), "link": .string(p.link), "media_id": p.assetID.map { .string($0.uuidString) } ?? .null,
                 "scheduled_at": .string(AgentTools.iso(p.scheduledAt)), "time_zone": .string(p.timeZoneID),
                 "published_url": p.publishedURL.map(JSONValue.string) ?? .null, "error": p.lastError.map(JSONValue.string) ?? .null]
            }, empty: "No posts match in \(ws.name).")
        case "get_request_status":
            if let raw = args["request_id"]?.stringValue {
                guard let id = UUID(uuidString: raw) else { return MCPToolOutcome("That is not a request id.", isError: true) }
                if let r = inbox.result(id) { return json([describe(r)]) }
                if inbox.isPending(id) { return MCPToolOutcome("Still waiting. " + appState) }
                return MCPToolOutcome("No request with that id (results are kept for a week).", isError: true)
            }
            let waiting = inbox.pendingCount
            let recent = inbox.recent(limit: 10).map(describe)
            return MCPToolOutcome("\(waiting) waiting. \(appState)\n" + (recent.isEmpty ? "No finished requests yet." : encode(.array(recent.map(JSONValue.object)))))
        default:
            return MCPToolOutcome("Unknown tool \(name).", isError: true)
        }
    }

    // MARK: Queued tools

    static func enqueue(_ name: String, args: [String: JSONValue], client: String, context: ModelContext, inbox: AgentInbox) -> MCPToolOutcome {
        if let problem = AgentTools.problem(tool: name, args: args) { return MCPToolOutcome(problem, isError: true) }
        var args = args
        if name != "update_media" {
            // Pin the brand now, so a later switch in the app does not change where this lands.
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            args["brand"] = .string(ws.uuid.uuidString)
        }
        let request = AgentRequest(tool: name, args: args, client: client)
        do { try inbox.enqueue(request) } catch {
            return MCPToolOutcome("Could not queue the request: \(error.localizedDescription)", isError: true)
        }
        let what = name == "create_posts" ? "The posts will wait in Needs Review until the person approves them. " : ""
        return MCPToolOutcome("Queued as request \(request.id.uuidString). \(what)\(appState) Check it with get_request_status.")
    }

    /// Whether the app is open to apply queued requests now.
    static var appState: String {
        let me = getpid()
        let open = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && $0.activationPolicy == .regular }
        return open ? "SocialForge is open and applies it within a few seconds." : "SocialForge is closed; it applies it the next time it opens."
    }

    // MARK: Helpers

    static func describe(_ r: AgentResult) -> [String: JSONValue] {
        ["request_id": .string(r.id.uuidString), "tool": .string(r.tool), "ok": .bool(r.ok), "message": .string(r.message),
         "created_ids": .array(r.createdIDs.map(JSONValue.string)), "finished_at": .string(AgentTools.iso(r.finishedAt))]
    }

    static func limit(_ args: [String: JSONValue]) -> Int {
        min(500, max(1, Int(args["limit"]?.numberValue ?? 50)))
    }

    static func noBrand(_ args: [String: JSONValue]) -> MCPToolOutcome {
        if let b = args["brand"]?.stringValue, !b.isEmpty { return MCPToolOutcome("No brand named \(b). See list_brands.", isError: true) }
        return MCPToolOutcome("SocialForge has no brand yet. Open SocialForge and set one up first.", isError: true)
    }

    static func json(_ rows: [[String: JSONValue]], empty: String = "Nothing found.") -> MCPToolOutcome {
        rows.isEmpty ? MCPToolOutcome(empty) : MCPToolOutcome(encode(.array(rows.map(JSONValue.object))))
    }

    static func encode(_ value: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// Finding brands for agent requests, shared by the MCP server and the app.
enum AgentLibrary {
    /// The brand open in the app (Store overrides keep their own, in memory).
    static var currentWorkspaceID: UUID? {
        UserDefaults.standard.string(forKey: "workspace.current").flatMap(UUID.init(uuidString:))
    }

    static func workspaces(_ context: ModelContext) -> [Workspace] {
        (try? context.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// A brand by id or name; nil or empty means the one open in the app, else the first.
    static func workspace(_ ref: String?, _ context: ModelContext, current: UUID? = currentWorkspaceID) -> Workspace? {
        let all = workspaces(context)
        let ref = (ref ?? "").trimmingCharacters(in: .whitespaces)
        if ref.isEmpty { return all.first { $0.uuid == current } ?? all.first }
        if let id = UUID(uuidString: ref) { return all.first { $0.uuid == id } }
        return all.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    }
}

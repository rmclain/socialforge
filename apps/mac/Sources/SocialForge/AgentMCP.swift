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
        let container = try? ModelContainer(for: SwiftData.Schema(AppSchema.models),
                                            configurations: ModelConfiguration(url: Store.url, allowsSave: false))
        let inbox = AgentInbox(root: Store.inboxURL)
        var session = MCPSession(serverName: "socialforge", serverVersion: UpdateSettings.currentVersion,
                                 instructions: instructions, tools: AgentTools.all) { name, args, client in
            guard let container else { return MCPToolOutcome("SocialForge's library could not be opened. Open SocialForge once, then try again.", isError: true) }
            // A fresh context per call, so each answer sees what the app saved since the last one.
            return handle(name, args: args, client: client, context: ModelContext(container), inbox: inbox)
        }
        while let line = readLine(strippingNewline: true) {
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
        case "list_media":
            guard let ws = AgentLibrary.workspace(args["brand"]?.stringValue, context) else { return noBrand(args) }
            let id = ws.uuid
            var items = (try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == id }, sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))) ?? []
            if let q = args["query"]?.stringValue, !q.isEmpty {
                items = items.filter { $0.filename.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) } }
            }
            if let c = args["collection"]?.stringValue, !c.isEmpty { items = items.filter { $0.collection.caseInsensitiveCompare(c) == .orderedSame } }
            if let k = args["kind"]?.stringValue, !k.isEmpty { items = items.filter { $0.kind == k } }
            return json(items.prefix(limit(args)).map { a in
                ["id": .string(a.uuid.uuidString), "filename": .string(a.filename), "kind": .string(a.kind), "title": .string(a.title),
                 "alt_text": .string(a.altText), "product_url": .string(a.productURL), "collection": .string(a.collection),
                 "tags": .array(a.tags.map(JSONValue.string)), "width": .number(Double(a.width)), "height": .number(Double(a.height)),
                 "path": .string(a.storedPath), "imported_at": .string(AgentTools.iso(a.importedAt))]
            }, empty: "No media matches in \(ws.name).")
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

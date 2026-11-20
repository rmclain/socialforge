import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Agents over MCP")
struct AgentMCPTests {
    private func session(calls: Box = Box()) -> MCPSession {
        MCPSession(serverName: "socialforge", serverVersion: "1.0", instructions: "Hi", tools: AgentTools.all) { name, args, client in
            calls.value.append("\(client):\(name):\(args["brand"]?.stringValue ?? "")")
            return MCPToolOutcome("ok \(name)")
        }
    }

    final class Box: @unchecked Sendable { var value: [String] = [] }

    private func object(_ line: String?) throws -> [String: JSONValue] {
        let data = try #require(line?.data(using: .utf8))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    @Test func initializeNamesTheServerAndRemembersTheClient() throws {
        var s = session()
        let reply = try object(s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"claude-code","version":"2"}}}"#))
        let result = try #require(reply["result"]?.objectValue)
        #expect(reply["id"] == .number(1))
        #expect(result["protocolVersion"] == .string("2025-03-26"))
        #expect(result["serverInfo"]?.objectValue?["name"] == .string("socialforge"))
        #expect(result["capabilities"]?.objectValue?["tools"] != nil)
        #expect(s.clientName == "Claude Code")
    }

    @Test func unknownProtocolVersionGetsTheNewest() throws {
        var s = session()
        let reply = try object(s.handle(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(reply["id"] == .string("a"))
        #expect(reply["result"]?.objectValue?["protocolVersion"] == .string(MCPSession.protocolVersions[0]))
    }

    @Test func notificationsGetNoAnswer() {
        var s = session()
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(s.handle("   ") == nil)
    }

    @Test func listsEveryToolWithASchema() throws {
        var s = session()
        let tools = try #require(try object(s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))["result"]?.objectValue?["tools"]?.arrayValue)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(Set(names) == ["list_brands", "list_accounts", "list_media", "list_posts", "import_media", "create_posts", "update_media", "get_request_status"])
        #expect(tools.allSatisfy { $0.objectValue?["inputSchema"]?.objectValue?["type"] == .string("object") })
    }

    @Test func toolsCallPassesArgumentsAndClient() throws {
        let calls = Box()
        var s = session(calls: calls)
        _ = s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-mcp-client"}}}"#)
        let reply = try object(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_media","arguments":{"brand":"Oak"}}}"#))
        let content = reply["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue
        #expect(content?["text"] == .string("ok list_media"))
        #expect(reply["result"]?.objectValue?["isError"] == .bool(false))
        #expect(calls.value == ["Codex:list_media:Oak"])
    }

    @Test func badInputGetsJSONRPCErrors() throws {
        var s = session()
        #expect(try object(s.handle("not json"))["error"]?.objectValue?["code"] == .number(-32700))
        #expect(try object(s.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_everything"}}"#))["error"]?.objectValue?["code"] == .number(-32602))
        #expect(try object(s.handle(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#))["error"]?.objectValue?["code"] == .number(-32601))
        #expect(try object(s.handle(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#))["result"] == .object([:]))
    }

    @Test func onlyChangesAreQueued() {
        #expect(Set(AgentTools.all.filter(\.queued).map(\.name)) == ["import_media", "create_posts", "update_media"])
        #expect(!AgentTools.all.contains { $0.name.contains("approve") || $0.name.contains("publish") })
    }

    // MARK: Request checks

    @Test func createPostsChecksEveryPost() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = AgentTools.iso(now.addingTimeInterval(86_400))
        let good: JSONValue = .object(["account_id": .string("acc"), "media_id": .string(UUID().uuidString), "scheduled_at": .string(later)])
        #expect(AgentTools.problem(tool: "create_posts", args: ["posts": .array([good])], now: now) == nil)
        #expect(AgentTools.problem(tool: "create_posts", args: [:], now: now) != nil)
        let noMedia: JSONValue = .object(["account_id": .string("acc"), "scheduled_at": .string(later)])
        #expect(AgentTools.problem(tool: "create_posts", args: ["posts": .array([good, noMedia])], now: now)?.hasPrefix("Post 2") == true)
        let past: JSONValue = .object(["account_id": .string("acc"), "media_id": .string(UUID().uuidString), "scheduled_at": .string(AgentTools.iso(now.addingTimeInterval(-3600)))])
        #expect(AgentTools.problem(tool: "create_posts", args: ["posts": .array([past])], now: now)?.contains("past") == true)
        let missingFile: JSONValue = .object(["account_id": .string("acc"), "file": .string("/nope/x.jpg"), "scheduled_at": .string(later)])
        #expect(AgentTools.problem(tool: "create_posts", args: ["posts": .array([missingFile])], now: now)?.contains("not found") == true)
        let tooMany = JSONValue.array(Array(repeating: good, count: AgentTools.maxPosts + 1))
        #expect(AgentTools.problem(tool: "create_posts", args: ["posts": tooMany], now: now) != nil)
    }

    @Test func importAndUpdateChecks() {
        #expect(AgentTools.problem(tool: "import_media", args: ["paths": .array([.string("/tmp")])]) == nil)
        #expect(AgentTools.problem(tool: "import_media", args: ["paths": .array([.string("relative.jpg")])]) != nil)
        #expect(AgentTools.problem(tool: "update_media", args: ["media_id": .string(UUID().uuidString)]) != nil)
        #expect(AgentTools.problem(tool: "update_media", args: ["media_id": .string(UUID().uuidString), "title": .string("Mug")]) == nil)
    }

    @Test(arguments: [
        ("2026-12-01T09:00:00-05:00", 1_796_133_600.0),
        ("2026-12-01T14:00:00Z", 1_796_133_600.0),
        ("2026-12-01T14:00:00.000Z", 1_796_133_600.0),
        ("2026-12-01T09:00", 1_796_133_600.0),
        ("2026-12-01 09:00", 1_796_133_600.0),
    ])
    func readsDates(text: String, expected: Double) throws {
        let ny = try #require(TimeZone(identifier: "America/New_York"))
        #expect(AgentTools.date(text, timeZone: ny)?.timeIntervalSince1970 == expected)
    }

    @Test func clientNames() {
        #expect(MCPSession.displayName("claude-code") == "Claude Code")
        #expect(MCPSession.displayName("codex-mcp-client") == "Codex")
        #expect(MCPSession.displayName("my_agent") == "My Agent")
    }

    // MARK: Inbox

    @Test func inboxQueuesAndFinishes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = AgentInbox(root: root)
        let first = AgentRequest(tool: "import_media", args: ["paths": .array([.string("/tmp/a.jpg")])], client: "Codex", createdAt: .now.addingTimeInterval(-10))
        let second = AgentRequest(tool: "update_media", args: [:], client: "Claude Code")
        try inbox.enqueue(second)
        try inbox.enqueue(first)
        #expect(inbox.pending().map(\.id) == [first.id, second.id])
        let read = try #require(inbox.pending().first)
        #expect(read.tool == first.tool && read.args == first.args && read.client == "Codex")
        #expect(abs(read.createdAt.timeIntervalSince(first.createdAt)) < 0.001)
        #expect(inbox.pendingCount == 2)

        try inbox.finish(AgentResult(request: first, ok: true, message: "1 media", createdIDs: ["x"]))
        #expect(!inbox.isPending(first.id) && inbox.isPending(second.id))
        #expect(inbox.result(first.id)?.createdIDs == ["x"])
        #expect(inbox.recent().map(\.id) == [first.id])

        try inbox.finish(AgentResult(request: second, ok: false, message: "old", finishedAt: .now.addingTimeInterval(-8 * 86_400)))
        inbox.prune()
        #expect(inbox.result(second.id) == nil && inbox.result(first.id) != nil)
    }

    @Test func inboxDropsUnreadableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = AgentInbox(root: root)
        try FileManager.default.createDirectory(at: inbox.pendingDir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: inbox.pendingDir.appending(path: "junk.json"))
        #expect(inbox.pending().isEmpty && inbox.pendingCount == 0)
    }
}

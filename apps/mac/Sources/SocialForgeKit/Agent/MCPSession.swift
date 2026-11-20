import Foundation

/// What a tool call returns: text for the agent, and whether it failed.
public struct MCPToolOutcome: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

/// The Model Context Protocol over stdio: one JSON-RPC message per line in, one per line out.
/// It answers initialize, ping, tools/list, and tools/call; the tools themselves come from `call`.
public struct MCPSession {
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let serverName: String
    public let serverVersion: String
    public let instructions: String
    public let tools: [AgentTool]
    /// Runs one tool: name, arguments, and the client's display name.
    public let call: (String, [String: JSONValue], String) -> MCPToolOutcome
    /// The client's display name once it has said hello ("Claude Code", "Codex").
    public private(set) var clientName = "An agent"

    public init(serverName: String, serverVersion: String, instructions: String, tools: [AgentTool],
                call: @escaping (String, [String: JSONValue], String) -> MCPToolOutcome) {
        self.serverName = serverName; self.serverVersion = serverVersion; self.instructions = instructions
        self.tools = tools; self.call = call
    }

    /// Handles one line and returns the line to send back, or nil for notifications.
    public mutating func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return Self.encode(["jsonrpc": .string("2.0"), "id": .null, "error": Self.error(-32700, "Parse error")])
        }
        let method = message["method"]?.stringValue ?? ""
        // A notification has no id and gets no answer.
        guard let id = message["id"] else { return nil }
        let params = message["params"]?.objectValue ?? [:]
        let reply: [String: JSONValue]
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?.objectValue?["name"]?.stringValue { clientName = Self.displayName(name) }
            let asked = params["protocolVersion"]?.stringValue ?? ""
            reply = ["result": .object([
                "protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
                "instructions": .string(instructions),
            ])]
        case "ping":
            reply = ["result": .object([:])]
        case "tools/list":
            reply = ["result": .object(["tools": .array(tools.map { t in
                .object(["name": .string(t.name), "description": .string(t.description), "inputSchema": t.inputSchema])
            })])]
        case "tools/call":
            guard let name = params["name"]?.stringValue, tools.contains(where: { $0.name == name }) else {
                reply = ["error": Self.error(-32602, "Unknown tool: \(params["name"]?.stringValue ?? "none")")]
                break
            }
            let outcome = call(name, params["arguments"]?.objectValue ?? [:], clientName)
            reply = ["result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]),
                "isError": .bool(outcome.isError),
            ])]
        default:
            reply = ["error": Self.error(-32601, "Method not found: \(method)")]
        }
        return Self.encode(reply.merging(["jsonrpc": .string("2.0"), "id": id]) { a, _ in a })
    }

    /// "claude-code" → "Claude Code", "codex-mcp-client" → "Codex".
    public static func displayName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("claude-code") || lower == "claude code" { return "Claude Code" }
        if lower.hasPrefix("claude") { return "Claude" }
        if lower.contains("codex") { return "Codex" }
        if lower.contains("cursor") { return "Cursor" }
        let words = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let clean = words.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "An agent" : clean.prefix(40).capitalized
    }

    static func error(_ code: Int, _ message: String) -> JSONValue {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    static func encode(_ object: [String: JSONValue]) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(JSONValue.object(object)), let s = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return s
    }
}

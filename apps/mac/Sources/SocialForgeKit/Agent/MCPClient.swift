import Foundation

/// Transport for a user-configured external MCP server (e.g., ArtCraft or custom creative tool server).
public enum OutboundMCPTransport: String, Codable, Sendable, CaseIterable {
    case stdio
    case http
}

/// Configuration for one external MCP server that SocialForge can talk to as a controlled MCP client.
public struct OutboundMCPServer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var transport: OutboundMCPTransport
    /// Executable path for stdio transport (e.g. `/usr/local/bin/artcraft-mcp`).
    public var command: String
    /// Arguments passed to the stdio process.
    public var arguments: [String]
    /// Endpoint URL for HTTP JSON-RPC transport (must be HTTPS unless localhost/LAN).
    public var endpointURL: String
    /// Optional tool allow-list. When non-empty, only listed tools can be invoked.
    public var allowedTools: [String]
    /// Optional workspace-root path restriction for file paths passed to the server.
    public var restrictedRootPath: String
    /// Require explicit user confirmation before invoking tools on this server.
    public var requireApproval: Bool
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, transport: OutboundMCPTransport = .stdio,
                command: String = "", arguments: [String] = [], endpointURL: String = "",
                allowedTools: [String] = [], restrictedRootPath: String = "",
                requireApproval: Bool = true, enabled: Bool = true) {
        self.id = id; self.name = name; self.transport = transport
        self.command = command; self.arguments = arguments; self.endpointURL = endpointURL
        self.allowedTools = allowedTools; self.restrictedRootPath = restrictedRootPath
        self.requireApproval = requireApproval; self.enabled = enabled
    }
}

/// Tool advertised by an external MCP server.
public struct OutboundMCPTool: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue = .object([:])) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

/// Result returned from an external MCP tool invocation.
/// Always tagged as untrusted so external servers can never bypass SocialForge's review/approval gates.
public struct OutboundMCPToolResult: Sendable, Equatable {
    public var serverName: String
    public var toolName: String
    public var text: String
    public var isError: Bool
    public var outputFilePaths: [String]
    public var untrusted: Bool = true

    public init(serverName: String, toolName: String, text: String, isError: Bool = false, outputFilePaths: [String] = []) {
        self.serverName = serverName; self.toolName = toolName; self.text = text
        self.isError = isError; self.outputFilePaths = outputFilePaths
    }
}

public enum OutboundMCPError: Error, LocalizedError, Equatable {
    case disabled
    case invalidConfiguration(String)
    case toolNotAllowed(String)
    case pathOutsideWorkspace(String)
    case transport(String)
    case protocolError(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .disabled: "This external MCP server is disabled."
        case .invalidConfiguration(let why): "External MCP configuration error: \(why)"
        case .toolNotAllowed(let name): "Tool \"\(name)\" is not in the allowed tools list for this server."
        case .pathOutsideWorkspace(let path): "Path \"\(path)\" is outside the allowed workspace folder."
        case .transport(let why): "External MCP transport error: \(why)"
        case .protocolError(let why): "External MCP server error: \(why)"
        case .timedOut: "The external MCP server timed out."
        }
    }
}

/// Controlled MCP client for discovering and invoking creative tools on user-configured external servers.
public struct OutboundMCPClient: Sendable {
    public let server: OutboundMCPServer
    public let bearerToken: String?
    public let session: URLSession
    public let timeoutSeconds: TimeInterval

    public init(server: OutboundMCPServer, bearerToken: String? = nil, session: URLSession = .shared, timeoutSeconds: TimeInterval = 30) {
        self.server = server
        self.bearerToken = bearerToken
        self.session = session
        self.timeoutSeconds = timeoutSeconds
    }

    public func validateConfiguration() throws(OutboundMCPError) {
        guard server.enabled else { throw .disabled }
        switch server.transport {
        case .stdio:
            let cmd = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, cmd.hasPrefix("/") else {
                throw .invalidConfiguration("Enter an absolute executable path for stdio MCP servers.")
            }
            guard FileManager.default.isExecutableFile(atPath: cmd) else {
                throw .invalidConfiguration("Executable not found or not runnable: \(cmd)")
            }
        case .http:
            if let problem = aiEndpointTransportProblem(server.endpointURL) {
                throw .invalidConfiguration(problem)
            }
        }
    }

    /// Initializes the server and lists advertised tools.
    public func discoverTools() async throws -> (serverInfo: String, tools: [OutboundMCPTool]) {
        try validateConfiguration()
        let initReq = makeRPC(id: 1, method: "initialize", params: [
            "protocolVersion": .string(MCPSession.protocolVersions[0]),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("SocialForge"), "version": .string("1.0")]),
        ])
        let listReq = makeRPC(id: 2, method: "tools/list", params: [:])
        let responses = try await exchange([initReq, listReq])
        guard responses.count >= 2 else { throw OutboundMCPError.protocolError("Incomplete initialize / tools/list response.") }
        let infoObj = responses[0]["result"]?.objectValue?["serverInfo"]?.objectValue
        let name = infoObj?["name"]?.stringValue ?? server.name
        let version = infoObj?["version"]?.stringValue ?? ""
        let serverInfo = version.isEmpty ? name : "\(name) \(version)"
        if let err = responses[1]["error"]?.objectValue?["message"]?.stringValue {
            throw OutboundMCPError.protocolError(DiagnosticRedactor.sanitize(err))
        }
        let rawTools = responses[1]["result"]?.objectValue?["tools"]?.arrayValue ?? []
        let tools = rawTools.compactMap { item -> OutboundMCPTool? in
            guard let o = item.objectValue, let n = o["name"]?.stringValue else { return nil }
            return OutboundMCPTool(name: n, description: o["description"]?.stringValue ?? "", inputSchema: o["inputSchema"] ?? .object([:]))
        }
        return (serverInfo, tools)
    }

    /// Invokes an explicitly allowed tool after validating path restrictions.
    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> OutboundMCPToolResult {
        try validateConfiguration()
        if !server.allowedTools.isEmpty && !server.allowedTools.contains(name) {
            throw OutboundMCPError.toolNotAllowed(name)
        }
        try validatePathRestrictions(arguments)
        let initReq = makeRPC(id: 1, method: "initialize", params: [
            "protocolVersion": .string(MCPSession.protocolVersions[0]),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("SocialForge"), "version": .string("1.0")]),
        ])
        let callReq = makeRPC(id: 2, method: "tools/call", params: [
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let responses = try await exchange([initReq, callReq])
        guard let reply = responses.last else { throw OutboundMCPError.protocolError("No reply to tools/call.") }
        if let err = reply["error"]?.objectValue?["message"]?.stringValue {
            throw OutboundMCPError.protocolError(DiagnosticRedactor.sanitize(err))
        }
        let result = reply["result"]?.objectValue ?? [:]
        let isError: Bool = {
            if case .bool(let b) = result["isError"] { return b }
            return false
        }()
        let content = result["content"]?.arrayValue ?? []
        let texts = content.compactMap { $0.objectValue?["text"]?.stringValue }
        let combined = DiagnosticRedactor.sanitize(texts.joined(separator: "\n"))
        let paths = Self.extractExistingPaths(from: combined, restrictedRoot: server.restrictedRootPath)
        return OutboundMCPToolResult(serverName: server.name, toolName: name, text: combined, isError: isError, outputFilePaths: paths)
    }

    private func validatePathRestrictions(_ arguments: [String: JSONValue]) throws(OutboundMCPError) {
        let root = server.restrictedRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return }
        let normalizedRoot = (root as NSString).standardizingPath
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        func check(_ value: JSONValue) throws(OutboundMCPError) {
            switch value {
            case .string(let s):
                if s.hasPrefix("/") {
                    let clean = (s as NSString).standardizingPath
                    if clean != normalizedRoot && !clean.hasPrefix(prefix) {
                        throw .pathOutsideWorkspace(s)
                    }
                }
            case .array(let items):
                for item in items { try check(item) }
            case .object(let dict):
                for v in dict.values { try check(v) }
            default:
                break
            }
        }
        for v in arguments.values { try check(v) }
    }

    static func extractExistingPaths(from text: String, restrictedRoot: String) -> [String] {
        let root = restrictedRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let normRoot = root.isEmpty ? "" : ((root as NSString).standardizingPath + "/")
        let pattern = #"(/[^\s"'<>|]+\.(?:png|jpe?g|webp|gif|mp4|mov|m4v|mp3|wav|m4a|flac))"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for match in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = (ns.substring(with: match.range(at: 1)) as NSString).standardizingPath
            if !normRoot.isEmpty && !path.hasPrefix(normRoot) { continue }
            if FileManager.default.fileExists(atPath: path), !out.contains(path) { out.append(path) }
        }
        return out
    }

    private func makeRPC(id: Int, method: String, params: [String: JSONValue]) -> [String: JSONValue] {
        ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)]
    }

    private func exchange(_ requests: [[String: JSONValue]]) async throws -> [[String: JSONValue]] {
        switch server.transport {
        case .http:
            return try await exchangeHTTP(requests)
        case .stdio:
            return try await exchangeStdio(requests)
        }
    }

    private func exchangeHTTP(_ requests: [[String: JSONValue]]) async throws -> [[String: JSONValue]] {
        guard let url = URL(string: server.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OutboundMCPError.invalidConfiguration("Invalid endpoint URL.")
        }
        let encoder = JSONEncoder()
        var replies: [[String: JSONValue]] = []
        for rpc in requests {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeoutSeconds
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let bearerToken, !bearerToken.isEmpty {
                req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try encoder.encode(JSONValue.object(rpc))
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OutboundMCPError.transport("No HTTP response.") }
            guard (200..<300).contains(http.statusCode) else {
                let body = DiagnosticRedactor.sanitize(String(decoding: data.prefix(300), as: UTF8.self))
                throw OutboundMCPError.transport("HTTP \(http.statusCode): \(body)")
            }
            guard let obj = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
                throw OutboundMCPError.protocolError("Non-JSON response from MCP server.")
            }
            replies.append(obj)
        }
        return replies
    }

    private func exchangeStdio(_ requests: [[String: JSONValue]]) async throws -> [[String: JSONValue]] {
        let encoder = JSONEncoder()
        var payload = Data()
        for rpc in requests {
            payload.append(try encoder.encode(JSONValue.object(rpc)))
            payload.append(0x0A)
        }
        let command = server.command
        let args = server.arguments
        let timeout = timeoutSeconds
        let inputData = payload
        return try await withThrowingTaskGroup(of: [[String: JSONValue]].self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: command)
                    proc.arguments = args
                    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                    proc.standardInput = inPipe
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe
                    do { try proc.run() } catch {
                        throw OutboundMCPError.transport(error.localizedDescription)
                    }
                    inPipe.fileHandleForWriting.write(inputData)
                    try? inPipe.fileHandleForWriting.close()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    let text = String(decoding: outData, as: UTF8.self)
                    var parsed: [[String: JSONValue]] = []
                    for line in text.split(whereSeparator: \.isNewline) {
                        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !s.isEmpty, let obj = (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)))?.objectValue else { continue }
                        parsed.append(obj)
                    }
                    if parsed.isEmpty {
                        let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile().prefix(300), as: UTF8.self)
                        throw OutboundMCPError.transport(errText.isEmpty ? "Process exited (\(proc.terminationStatus)) with no JSON-RPC output." : DiagnosticRedactor.sanitize(errText))
                    }
                    return parsed
                }.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OutboundMCPError.timedOut
            }
            guard let first = try await group.next() else { throw OutboundMCPError.timedOut }
            group.cancelAll()
            return first
        }
    }
}

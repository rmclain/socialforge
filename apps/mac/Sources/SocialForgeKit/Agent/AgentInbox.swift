import Foundation

/// A change an agent asked for through `SocialForge --mcp`, waiting for the app to apply it.
public struct AgentRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tool: String
    public var args: [String: JSONValue]
    /// Who asked, from the MCP client's name: "Claude Code", "Codex".
    public var client: String
    public var createdAt: Date

    public init(id: UUID = UUID(), tool: String, args: [String: JSONValue], client: String, createdAt: Date = .now) {
        self.id = id; self.tool = tool; self.args = args; self.client = client; self.createdAt = createdAt
    }
}

/// What the app did with a request.
public struct AgentResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var tool: String
    public var client: String
    public var ok: Bool
    public var message: String
    /// Ids of what it made: media ids for import_media, post ids for create_posts.
    public var createdIDs: [String]
    public var finishedAt: Date

    public init(request: AgentRequest, ok: Bool, message: String, createdIDs: [String] = [], finishedAt: Date = .now) {
        id = request.id; tool = request.tool; client = request.client
        self.ok = ok; self.message = message; self.createdIDs = createdIDs; self.finishedAt = finishedAt
    }
}

/// A folder of JSON files: `Pending/<id>.json` until the app applies a request, then `Done/<id>.json`.
/// The MCP process only writes here; the app is the only writer of the library, so the two never race.
public struct AgentInbox: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    var pendingDir: URL { root.appending(path: "Pending", directoryHint: .isDirectory) }
    var doneDir: URL { root.appending(path: "Done", directoryHint: .isDirectory) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Fractions of a second keep requests made in the same second in order.
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return d
    }()

    /// Writes the request in one step (temp file, then rename), so the app never reads half a file.
    public func enqueue(_ request: AgentRequest) throws {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(request)
        let tmp = pendingDir.appending(path: ".\(request.id.uuidString).tmp")
        try data.write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: pendingDir.appending(path: "\(request.id.uuidString).json"))
    }

    /// Waiting requests, oldest first. A file that does not read as a request is dropped.
    public func pending() -> [AgentRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? []
        var out: [AgentRequest] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let r = try? Self.decoder.decode(AgentRequest.self, from: data) {
                out.append(r)
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public var pendingCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    /// Records the result and takes the request out of Pending.
    public func finish(_ result: AgentResult) throws {
        try FileManager.default.createDirectory(at: doneDir, withIntermediateDirectories: true)
        try Self.encoder.encode(result).write(to: doneDir.appending(path: "\(result.id.uuidString).json"), options: .atomic)
        try? FileManager.default.removeItem(at: pendingDir.appending(path: "\(result.id.uuidString).json"))
    }

    public func isPending(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: pendingDir.appending(path: "\(id.uuidString).json").path)
    }

    public func result(_ id: UUID) -> AgentResult? {
        guard let data = try? Data(contentsOf: doneDir.appending(path: "\(id.uuidString).json")) else { return nil }
        return try? Self.decoder.decode(AgentResult.self, from: data)
    }

    /// The latest results, newest first.
    public func recent(limit: Int = 10) -> [AgentResult] {
        let files = (try? FileManager.default.contentsOfDirectory(at: doneDir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in (try? Data(contentsOf: f)).flatMap { try? Self.decoder.decode(AgentResult.self, from: $0) } }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(limit).map { $0 }
    }

    /// Forgets results older than `age` (a week by default).
    public func prune(olderThan age: TimeInterval = 7 * 86_400, now: Date = .now) {
        for r in recent(limit: .max) where now.timeIntervalSince(r.finishedAt) > age {
            try? FileManager.default.removeItem(at: doneDir.appending(path: "\(r.id.uuidString).json"))
        }
    }
}

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
    public var quarantineDir: URL { root.appending(path: "Quarantine", directoryHint: .isDirectory) }

    private static func ensurePrivateDir(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func restrictFile(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

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
        try Self.ensurePrivateDir(root)
        try Self.ensurePrivateDir(pendingDir)
        let data = try Self.encoder.encode(request)
        let tmp = pendingDir.appending(path: ".\(request.id.uuidString).tmp")
        try data.write(to: tmp)
        Self.restrictFile(tmp)
        let finalURL = pendingDir.appending(path: "\(request.id.uuidString).json")
        try FileManager.default.moveItem(at: tmp, to: finalURL)
        Self.restrictFile(finalURL)
    }

    /// Waiting requests, oldest first. Unreadable files are quarantined (never silently dropped);
    /// requests already in Done/ (e.g. crash between write and remove) are skipped and cleaned up.
    public func pending() -> [AgentRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [AgentRequest] = []
        let now = Date()
        for f in files {
            if f.pathExtension == "tmp" {
                if let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   now.timeIntervalSince(mtime) > 300 {
                    try? FileManager.default.removeItem(at: f)
                }
                continue
            }
            guard f.pathExtension == "json" else { continue }
            if let data = try? Data(contentsOf: f), let r = try? Self.decoder.decode(AgentRequest.self, from: data) {
                // Idempotency guard: if Done/<id>.json already exists, clean up the duplicate Pending file.
                if result(r.id) != nil {
                    try? FileManager.default.removeItem(at: f)
                    continue
                }
                out.append(r)
            } else {
                quarantine(f)
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    private func quarantine(_ file: URL) {
        try? Self.ensurePrivateDir(quarantineDir)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = quarantineDir.appending(path: "\(stamp)-\(file.lastPathComponent)")
        if (try? FileManager.default.moveItem(at: file, to: dest)) == nil {
            try? FileManager.default.removeItem(at: file)
        } else {
            Self.restrictFile(dest)
        }
    }

    public var pendingCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    /// Records the result and takes the request out of Pending.
    public func finish(_ result: AgentResult) throws {
        try Self.ensurePrivateDir(root)
        try Self.ensurePrivateDir(doneDir)
        let dest = doneDir.appending(path: "\(result.id.uuidString).json")
        try Self.encoder.encode(result).write(to: dest, options: .atomic)
        Self.restrictFile(dest)
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
        let files = ((try? FileManager.default.contentsOfDirectory(at: doneDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
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

import Foundation

/// The publishing service's API, as the app sees it. Mirrors services/api/src/routes.
public enum API {
    public struct Health: Codable, Sendable, Equatable { public let status: String; public let db: String? }
    public struct Version: Codable, Sendable, Equatable { public let name: String; public let version: String; public let commit: String? }
    public struct Capabilities: Codable, Sendable, Equatable {
        public let apiVersion: Int
        public let platforms: [String]
        public let features: [String]
        public let maxUploadBytes: Int?
        public init(apiVersion: Int = 1, platforms: [String], features: [String] = [], maxUploadBytes: Int? = nil) {
            self.apiVersion = apiVersion; self.platforms = platforms; self.features = features; self.maxUploadBytes = maxUploadBytes
        }
    }

    public struct Account: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let platform: String
        public let name: String
        public let handle: String?
        /// connected, expired, revoked, error
        public let status: String
        public let scopes: [String]
        public let tokenExpiresAt: Date?
        public let lastPublishedAt: Date?
        /// True for the development mock provider. Never shown as a real account.
        public let isMock: Bool
    }
    public struct Accounts: Codable, Sendable { public let accounts: [Account] }

    public struct Board: Codable, Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let privacy: String?
        public init(id: String, name: String, privacy: String?) { self.id = id; self.name = name; self.privacy = privacy }
    }
    public struct Boards: Codable, Sendable { public let boards: [Board] }

    public struct Connect: Codable, Sendable { public let authorizeUrl: String }

    public struct MediaUpload: Codable, Sendable { public let mediaId: String; public let sha256: String }

    public struct NewPublication: Codable, Sendable, Equatable {
        public let clientId: String
        public let idempotencyKey: String
        public let accountId: String
        public let platform: String
        public let scheduledAt: Date
        public let timeZone: String
        public let mediaId: String?
        public let payload: Payload
        public init(clientId: String, idempotencyKey: String, accountId: String, platform: String, scheduledAt: Date,
                    timeZone: String, mediaId: String?, payload: Payload) {
            self.clientId = clientId; self.idempotencyKey = idempotencyKey; self.accountId = accountId; self.platform = platform
            self.scheduledAt = scheduledAt; self.timeZone = timeZone; self.mediaId = mediaId; self.payload = payload
        }
    }
    public struct Payload: Codable, Sendable, Equatable {
        public let title: String
        public let description: String
        public let link: String
        public let altText: String
        public let boardId: String?
        public init(title: String, description: String, link: String, altText: String, boardId: String?) {
            self.title = title; self.description = description; self.link = link; self.altText = altText; self.boardId = boardId
        }
    }
    public struct CreatePublications: Codable, Sendable { public let publications: [NewPublication] }

    public struct Publication: Codable, Sendable, Equatable {
        public let id: String
        public let clientId: String
        /// scheduled, publishing, published, failed, canceled
        public let status: String
        public let scheduledAt: Date
        public let publishedUrl: String?
        public let providerPostId: String?
        public let lastError: String?
        public let attempts: Int
        public let updatedAt: Date
    }
    public struct Publications: Codable, Sendable { public let publications: [Publication]; public let serverTime: Date? }

    public struct ErrorBody: Codable, Sendable { public let error: String?; public let message: String? }
}

public struct BackendClient: Sendable {
    public enum ClientError: Error, Equatable, LocalizedError {
        case notConfigured
        case unreachable(String)
        case http(Int, String)
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "Set the publishing service address in Settings."
            case .unreachable(let why): "Could not reach the publishing service: \(why)"
            case .http(let code, let msg): "The publishing service answered \(code): \(msg)"
            case .decoding(let why): "Unexpected answer from the publishing service: \(why)"
            }
        }
    }

    public let baseURL: URL
    public let token: String?
    let session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = ISO8601.parse(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601.format(date))
        }
        return e
    }()

    public func health() async throws(ClientError) -> API.Health { try await get("health", auth: false) }
    public func version() async throws(ClientError) -> API.Version { try await get("version", auth: false) }
    public func capabilities() async throws(ClientError) -> API.Capabilities { try await get("v1/capabilities", auth: false) }
    public func accounts() async throws(ClientError) -> [API.Account] { try await (get("v1/accounts") as API.Accounts).accounts }
    public func boards(account: String) async throws(ClientError) -> [API.Board] {
        try await (get("v1/accounts/\(Self.encodeSegment(account))/boards") as API.Boards).boards
    }
    public func connect(platform: String) async throws(ClientError) -> URL {
        let r: API.Connect = try await send("POST", "v1/accounts/\(Self.encodeSegment(platform))/connect", body: Data("{}".utf8))
        guard let url = URL(string: r.authorizeUrl) else { throw .decoding("authorizeUrl") }
        return url
    }

    /// Uploads media by content hash. Uploading the same bytes twice returns the same id.
    public func upload(file: URL, sha256: String, contentType: String) async throws(ClientError) -> API.MediaUpload {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw .unreachable(error.localizedDescription) }
        return try await send("PUT", "v1/media/\(Self.encodeSegment(sha256))", body: data, contentType: contentType)
    }

    public func create(_ pubs: [API.NewPublication]) async throws(ClientError) -> [API.Publication] {
        let body: Data
        do { body = try Self.encoder.encode(API.CreatePublications(publications: pubs)) } catch { throw .decoding(error.localizedDescription) }
        return try await (send("POST", "v1/publications", body: body) as API.Publications).publications
    }

    public func publications(updatedSince: Date?) async throws(ClientError) -> API.Publications {
        var path = "v1/publications"
        if let updatedSince { path += "?updatedSince=" + (ISO8601.format(updatedSince).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        return try await get(path)
    }

    public func cancel(publication id: String) async throws(ClientError) -> API.Publication {
        try await send("POST", "v1/publications/\(Self.encodeSegment(id))/cancel", body: Data("{}".utf8))
    }

    // MARK: - Plumbing

    static func encodeSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&#"))) ?? s
    }

    func request(_ method: String, _ path: String, auth: Bool) throws(ClientError) -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL.appending(path: ""))?.absoluteURL else {
            throw .unreachable("Invalid service URL path: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth, let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func get<T: Decodable>(_ path: String, auth: Bool = true) async throws(ClientError) -> T {
        try await perform(try request("GET", path, auth: auth))
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: Data, contentType: String = "application/json") async throws(ClientError) -> T {
        var req = try request(method, path, auth: true)
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await perform(req)
    }

    func perform<T: Decodable>(_ req: URLRequest) async throws(ClientError) -> T {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw .unreachable(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw .unreachable("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? Self.decoder.decode(API.ErrorBody.self, from: data)
            throw .http(http.statusCode, body?.message ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw .decoding(String(describing: error)) }
    }
}

public enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    public static func parse(_ s: String) -> Date? {
        lock.withLock { withFraction.date(from: s) ?? plain.date(from: s) }
    }
    public static func format(_ d: Date) -> String { lock.withLock { withFraction.string(from: d) } }
}

// MARK: - Sync

/// Local publication state the app keeps, merged with what the server says.
public struct LocalPublicationState: Sendable, Equatable {
    public var clientId: String
    public var serverId: String?
    public var status: String
    public var publishedUrl: String?
    public var lastError: String?
    public var attempts: Int
    public init(clientId: String, serverId: String?, status: String, publishedUrl: String? = nil, lastError: String? = nil, attempts: Int = 0) {
        self.clientId = clientId; self.serverId = serverId; self.status = status
        self.publishedUrl = publishedUrl; self.lastError = lastError; self.attempts = attempts
    }
}

public enum SyncMerge {
    /// Applies server rows to local rows by clientId. Never creates local rows
    /// for unknown server rows (they belong to another Mac's library) and never
    /// moves a final state (published, canceled) back.
    public static func merge(local: [LocalPublicationState], server: [API.Publication]) -> (updated: [LocalPublicationState], changed: Int) {
        let byClient = Dictionary(server.map { ($0.clientId, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        var changed = 0
        let out = local.map { row -> LocalPublicationState in
            guard let s = byClient[row.clientId] else { return row }
            if ["published", "canceled"].contains(row.status) && row.status != s.status && s.status != "published" { return row }
            var next = row
            next.serverId = s.id
            next.status = s.status == "queued" ? "scheduled" : s.status
            next.publishedUrl = s.publishedUrl ?? row.publishedUrl
            next.lastError = s.lastError
            next.attempts = s.attempts
            if next != row { changed += 1 }
            return next
        }
        return (out, changed)
    }
}

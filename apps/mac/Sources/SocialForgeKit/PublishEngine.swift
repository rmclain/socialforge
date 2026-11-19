import Foundation

// On-Mac publishing. The app runs this while open; the launch agent runs it
// while the app is closed. A platform is one `PublishTarget`.

public struct PublishFailure: Error, Sendable, Equatable {
    /// retryable: try later (5xx, 429, network down before sending)
    /// uncertain: the request may have reached the platform; look before posting again
    /// auth: token invalid or revoked; mark the account and stop
    /// permanent: the platform rejected the content; stop
    public enum Kind: String, Sendable { case retryable, uncertain, auth, permanent }
    public let kind: Kind
    public let message: String
    public let httpStatus: Int?
    public let requestID: String?
    public init(_ kind: Kind, _ message: String, httpStatus: Int? = nil, requestID: String? = nil) {
        self.kind = kind; self.message = message; self.httpStatus = httpStatus; self.requestID = requestID
    }

    public static func kind(forStatus status: Int) -> Kind {
        switch status {
        case 401, 403: .auth
        case 408, 429, 500...: .retryable
        default: .permanent
        }
    }
}

public struct PublishInput: Sendable {
    public var idempotencyKey: String
    public var accountID: String
    public var accessToken: String?
    public var title: String
    public var description: String
    public var link: String
    public var altText: String
    public var boardID: String
    public var image: Data?
    public var contentType: String
    public init(idempotencyKey: String, accountID: String, accessToken: String?, title: String, description: String, link: String,
                altText: String, boardID: String, image: Data?, contentType: String) {
        self.idempotencyKey = idempotencyKey; self.accountID = accountID; self.accessToken = accessToken; self.title = title
        self.description = description; self.link = link; self.altText = altText; self.boardID = boardID
        self.image = image; self.contentType = contentType
    }
}

public struct PublishOutcome: Sendable, Equatable {
    public let providerPostID: String
    public let url: String?
    public let requestID: String?
    public init(providerPostID: String, url: String?, requestID: String?) {
        self.providerPostID = providerPostID; self.url = url; self.requestID = requestID
    }
}

public protocol PublishTarget: Sendable {
    func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome
    /// A post an earlier, uncertain attempt may have created. Nil when there is none.
    func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome?
    func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board]
}

public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 60, maxDelay: TimeInterval = 3600) {
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }

    /// 1 min, 2 min, 4 min, 8 min... capped.
    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
    }
}

/// What one attempt did, for the attempt history and the post's new state.
public struct AttemptResult: Sendable, Equatable {
    public enum Next: Sendable, Equatable {
        case published(PublishOutcome)
        case retry(at: Date)
        case failed(message: String, expireAccount: Bool)
    }
    /// success, reconciled, retryable, uncertain, auth, permanent
    public let outcome: String
    public let next: Next
    public let httpStatus: Int?
    public let requestID: String?
    public let error: String?
    public init(outcome: String, next: Next, httpStatus: Int?, requestID: String?, error: String?) {
        self.outcome = outcome; self.next = next; self.httpStatus = httpStatus; self.requestID = requestID; self.error = error
    }
}

public enum PublishEngine {
    /// Runs attempt number `attempt` (1-based). After an uncertain attempt it
    /// first asks the platform whether the post exists, so a timeout never
    /// becomes a double post.
    public static func attempt(_ input: PublishInput, target: some PublishTarget, attempt: Int, hadUncertain: Bool,
                               firstTriedAt: Date, policy: RetryPolicy, now: Date = .now) async -> AttemptResult {
        do {
            if hadUncertain, let found = try await target.findExisting(input, since: firstTriedAt) {
                return AttemptResult(outcome: "reconciled", next: .published(found), httpStatus: nil, requestID: found.requestID, error: nil)
            }
            let out = try await target.publish(input)
            return AttemptResult(outcome: "success", next: .published(out), httpStatus: nil, requestID: out.requestID, error: nil)
        } catch {
            let next: AttemptResult.Next
            switch error.kind {
            case .auth: next = .failed(message: "\(error.message). Reconnect the account in Social Accounts.", expireAccount: true)
            case .permanent: next = .failed(message: error.message, expireAccount: false)
            case .retryable, .uncertain:
                next = attempt >= policy.maxAttempts
                    ? .failed(message: "\(error.message); gave up after \(attempt) attempts.", expireAccount: false)
                    : .retry(at: now.addingTimeInterval(policy.delay(afterAttempt: attempt)))
            }
            return AttemptResult(outcome: error.kind.rawValue, next: next, httpStatus: error.httpStatus, requestID: error.requestID, error: error.message)
        }
    }
}

// MARK: - Mock target

/// A development stand-in for Pinterest that keeps its "Pins" in a JSON file,
/// so the app and the launch agent see the same posts and reconciliation can
/// be tested honestly. Accounts that use it are labeled as mock in the app.
public actor MockPinterestTarget: PublishTarget {
    public struct Post: Codable, Sendable, Equatable {
        public let id: String
        public let accountID: String
        public let boardID: String
        public let title: String
        public let link: String
        public let idempotencyKey: String
        public let createdAt: Date
    }
    public enum Step: Sendable { case ok, retryable, auth, permanent, uncertainAfterCreate }

    public static let boards = [API.Board(id: "board_winter", name: "Winter Home Edit", privacy: "PUBLIC"),
                                API.Board(id: "board_kitchen", name: "Kitchen & Table", privacy: "PUBLIC")]

    let file: URL
    var script: [Step] = []

    public init(file: URL) { self.file = file }

    public func setScript(_ steps: [Step]) { script = steps }

    public func posts() -> [Post] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Post].self, from: data)) ?? []
    }

    private func save(_ posts: [Post]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(posts).write(to: file, options: .atomic)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        let step = script.isEmpty ? .ok : script.removeFirst()
        switch step {
        case .retryable: throw PublishFailure(.retryable, "Mock Pinterest answered 503 Service Unavailable", httpStatus: 503)
        case .auth: throw PublishFailure(.auth, "Mock Pinterest answered 401: Authentication failed", httpStatus: 401)
        case .permanent: throw PublishFailure(.permanent, "Mock Pinterest answered 400: Invalid board_id", httpStatus: 400)
        case .ok, .uncertainAfterCreate: break
        }
        guard input.image != nil else { throw PublishFailure(.permanent, "A Pin needs an image.", httpStatus: 400) }
        guard Self.boards.contains(where: { $0.id == input.boardID }) else {
            throw PublishFailure(.permanent, "Mock Pinterest answered 404: board \(input.boardID) not found", httpStatus: 404)
        }
        let post = Post(id: UUID().uuidString.lowercased(), accountID: input.accountID, boardID: input.boardID, title: input.title,
                        link: input.link, idempotencyKey: input.idempotencyKey, createdAt: .now)
        do { try save(posts() + [post]) } catch { throw PublishFailure(.retryable, "Mock store not writable: \(error.localizedDescription)") }
        if step == .uncertainAfterCreate { throw PublishFailure(.uncertain, "Mock Pinterest timed out after receiving the request") }
        return PublishOutcome(providerPostID: post.id, url: "https://mock.pinterest.local/pin/\(post.id)/", requestID: "mock-\(posts().count)")
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        guard let hit = posts().last(where: { $0.idempotencyKey == input.idempotencyKey && $0.createdAt >= since.addingTimeInterval(-60) }) else { return nil }
        return PublishOutcome(providerPostID: hit.id, url: "https://mock.pinterest.local/pin/\(hit.id)/", requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] { Self.boards }
}

// MARK: - Pinterest

/// Pinterest API v5. LIVE STATUS: UNVERIFIED (built from the documented
/// shapes; no real Pin created yet). Trial apps use https://api-sandbox.pinterest.com.
public struct PinterestTarget: PublishTarget {
    public static let scopes = ["user_accounts:read", "boards:read", "pins:read", "pins:write"]
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://api.pinterest.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    func call(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) async throws(PublishFailure) -> (Data, String?) {
        guard let token, !token.isEmpty else { throw PublishFailure(.auth, "No access token") }
        var req = URLRequest(url: URL(string: "/v5" + path, relativeTo: apiBase)!.absoluteURL)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            if method == "POST" && timedOut { throw PublishFailure(.uncertain, "Pinterest did not answer in time") }
            throw PublishFailure(.retryable, "Could not reach Pinterest: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let requestID = http?.value(forHTTPHeaderField: "x-request-id")
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            let status = http?.statusCode ?? 0
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw PublishFailure(PublishFailure.kind(forStatus: status), "Pinterest answered \(status)" + (msg.map { ": \($0)" } ?? ""),
                                 httpStatus: status, requestID: requestID)
        }
        return (data, requestID)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let image = input.image else { throw PublishFailure(.permanent, "A Pin needs an image.") }
        var body: [String: Any] = [
            "board_id": input.boardID,
            // No idempotency header exists; the private note carries our key for reconciliation.
            "note": "sf:\(input.idempotencyKey)",
            "media_source": ["source_type": "image_base64", "content_type": input.contentType == "image/png" ? "image/png" : "image/jpeg",
                             "data": image.base64EncodedString()],
        ]
        if !input.title.isEmpty { body["title"] = input.title }
        if !input.description.isEmpty { body["description"] = input.description }
        if !input.link.isEmpty { body["link"] = input.link }
        if !input.altText.isEmpty { body["alt_text"] = input.altText }
        let (data, requestID) = try await call("POST", "/pins", token: input.accessToken, body: body)
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw PublishFailure(.uncertain, "Pinterest answered without a Pin id")
        }
        return PublishOutcome(providerPostID: id, url: "https://www.pinterest.com/pin/\(id)/", requestID: requestID)
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        let (data, _) = try await call("GET", "/boards/\(input.boardID)/pins?page_size=50", token: input.accessToken)
        let items = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        guard let hit = items.first(where: { $0["note"] as? String == "sf:\(input.idempotencyKey)" }), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: "https://www.pinterest.com/pin/\(id)/", requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        var out: [API.Board] = []
        var bookmark: String?
        repeat {
            let q = "/boards?page_size=100" + (bookmark.map { "&bookmark=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" } ?? "")
            let (data, _) = try await call("GET", q, token: accessToken)
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            for b in (obj["items"] as? [[String: Any]]) ?? [] {
                if let id = b["id"] as? String, let name = b["name"] as? String { out.append(API.Board(id: id, name: name, privacy: b["privacy"] as? String)) }
            }
            bookmark = obj["bookmark"] as? String
        } while bookmark != nil && out.count < 1000
        return out
    }

    // MARK: OAuth (your own Pinterest app's id and secret, kept in the Keychain)

    public static func authorizeURL(clientID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://www.pinterest.com/oauth/")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: ",")),
                        .init(name: "state", value: state)]
        return c.url!
    }

    public struct Tokens: Sendable { public let access: String; public let refresh: String?; public let expiresIn: Int?; public let scopes: [String] }

    public func exchange(code: String, redirectURI: String, clientID: String, clientSecret: String) async throws(PublishFailure) -> Tokens {
        var req = URLRequest(url: apiBase.appending(path: "v5/oauth/token"))
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code), .init(name: "redirect_uri", value: redirectURI)]
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw PublishFailure(.retryable, error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "Pinterest token exchange failed (\(status))", httpStatus: status)
        }
        return Tokens(access: access, refresh: obj["refresh_token"] as? String, expiresIn: obj["expires_in"] as? Int,
                      scopes: ((obj["scope"] as? String) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
    }

    public func userAccount(accessToken: String) async throws(PublishFailure) -> (id: String, name: String, username: String) {
        let (data, _) = try await call("GET", "/user_account", token: accessToken)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let username = obj["username"] as? String ?? "pinterest"
        return ((obj["id"] as? String) ?? username, (obj["business_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username, username)
    }
}

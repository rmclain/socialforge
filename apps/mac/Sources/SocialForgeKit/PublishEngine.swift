import Foundation

// On-Mac publishing. The app runs this while open; the launch agent runs it
// while the app is closed. A platform is one `PublishTarget`.

public struct PublishFailure: Error, Sendable, Equatable {
    /// retryable: try later (5xx, network down before sending)
    /// rateLimited: provider rate limit / quota hit (respect retryAfter)
    /// uncertain: the request may have reached the platform; reconcile or mark Outcome Unknown before posting again
    /// auth: token invalid, expired, or revoked; mark the account for reauthentication and stop
    /// permission: valid token but missing scope, app review, or policy restriction (does NOT expire the account)
    /// permanent: the platform rejected the content; stop
    public enum Kind: String, Sendable, Equatable {
        case retryable, rateLimited, uncertain, auth, permission, permanent
    }
    public let kind: Kind
    public let message: String
    public let httpStatus: Int?
    public let requestID: String?
    public let retryAfter: TimeInterval?

    public init(_ kind: Kind, _ message: String, httpStatus: Int? = nil, requestID: String? = nil, retryAfter: TimeInterval? = nil) {
        self.kind = kind; self.message = message; self.httpStatus = httpStatus
        self.requestID = requestID; self.retryAfter = retryAfter
    }

    public static func kind(forStatus status: Int) -> Kind {
        switch status {
        case 401: .auth
        case 403: .permission
        case 429: .rateLimited
        case 408, 500...: .retryable
        default: .permanent
        }
    }

    /// Parses an HTTP `Retry-After` header (either integer seconds or IMF-fixdate).
    public static func parseRetryAfter(_ header: String?, now: Date = .now) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds > 0 { return min(seconds, 86_400) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = df.date(from: raw) {
            let delta = date.timeIntervalSince(now)
            return delta > 0 ? min(delta, 86_400) : nil
        }
        return nil
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
    public var boardSectionID: String?
    public var image: Data?
    public var contentType: String
    /// The media file on disk (Meta, LinkedIn, X, TikTok, YouTube upload from it; Pinterest uses `image` or video `mediaFile`).
    public var mediaFile: URL?
    /// Additional media files for carousels or multi-photo posts.
    public var extraMediaFiles: [URL] = []
    public var isVideo: Bool = false
    /// Optional provider-specific disclosure / visibility metadata (e.g. YouTube visibility/madeForKids, TikTok privacy/disclosures).
    public var metadata: [String: String] = [:]
    /// Persisted container/upload ID from a previous interrupted attempt so processing can resume.
    public var existingContainerID: String?

    /// The post's text as Instagram, Facebook, Threads, LinkedIn, and X show it.
    public var caption: String {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : d
    }

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
    public let containerID: String?

    public init(providerPostID: String, url: String?, requestID: String?, containerID: String? = nil) {
        self.providerPostID = providerPostID; self.url = url; self.requestID = requestID; self.containerID = containerID
    }
}

public protocol PublishTarget: Sendable {
    func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome
    /// A post an earlier, uncertain attempt may have created. Nil when there is none or when evidence is ambiguous.
    func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome?
    func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board]
    /// Whether `findExisting` uses a deterministic idempotency token (e.g. Pinterest note / mock key)
    /// versus heuristic matching. When false and reconciliation finds nothing after an uncertain attempt,
    /// `PublishEngine` moves to `.outcomeUnknown` instead of blindly posting a potential duplicate.
    var supportsDeterministicReconciliation: Bool { get }
}

public extension PublishTarget {
    var supportsDeterministicReconciliation: Bool { false }
}

public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Fractional jitter range (e.g. 0.0 for deterministic tests, 0.2 for ±20% jitter in production).
    public var jitterFraction: Double

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 60, maxDelay: TimeInterval = 3600, jitterFraction: Double = 0.0) {
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay; self.jitterFraction = jitterFraction
    }

    /// 1 min, 2 min, 4 min, 8 min... capped, respecting Retry-After and optional jitter.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let base = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        let chosen = retryAfter.map { max($0, base) } ?? base
        guard jitterFraction > 0 else { return chosen }
        let delta = chosen * jitterFraction
        return max(1, chosen + Double.random(in: -delta...delta))
    }
}

/// What one attempt did, for the attempt history and the post's new state.
public struct AttemptResult: Sendable, Equatable {
    public enum Next: Sendable, Equatable {
        case published(PublishOutcome)
        case retry(at: Date)
        case outcomeUnknown(message: String)
        case actionRequired(message: String)
        case failed(message: String, expireAccount: Bool)
    }
    /// success, reconciled, retryable, rateLimited, uncertain, auth, permission, permanent
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
    /// becomes a double post. If the platform does not support deterministic
    /// reconciliation and no clear match is found, it stops in `.outcomeUnknown`
    /// rather than risking a duplicate real-world post.
    public static func attempt(_ input: PublishInput, target: some PublishTarget, attempt: Int, hadUncertain: Bool,
                               firstTriedAt: Date, policy: RetryPolicy, now: Date = .now) async -> AttemptResult {
        do {
            if hadUncertain {
                if let found = try await target.findExisting(input, since: firstTriedAt) {
                    return AttemptResult(outcome: "reconciled", next: .published(found), httpStatus: nil, requestID: found.requestID, error: nil)
                }
                if !target.supportsDeterministicReconciliation {
                    let msg = "A previous publishing attempt timed out or lost connection, and SocialForge could not confirm whether the post went live. Check the platform before retrying to avoid a duplicate post."
                    return AttemptResult(outcome: "uncertain", next: .outcomeUnknown(message: msg), httpStatus: nil, requestID: nil, error: msg)
                }
            }
            let out = try await target.publish(input)
            return AttemptResult(outcome: "success", next: .published(out), httpStatus: nil, requestID: out.requestID, error: nil)
        } catch {
            let next: AttemptResult.Next
            switch error.kind {
            case .auth:
                next = .failed(message: "\(error.message). Reconnect the account in Connections.", expireAccount: true)
            case .permission:
                next = .actionRequired(message: "\(error.message). Check account permissions or provider approval in Connections.")
            case .permanent:
                next = .failed(message: error.message, expireAccount: false)
            case .uncertain:
                if target.supportsDeterministicReconciliation {
                    next = attempt >= policy.maxAttempts
                        ? .outcomeUnknown(message: "\(error.message); could not confirm outcome after \(attempt) attempts. Check the platform before retrying.")
                        : .retry(at: now.addingTimeInterval(policy.delay(afterAttempt: attempt, retryAfter: error.retryAfter)))
                } else {
                    next = .outcomeUnknown(message: "\(error.message). Check the platform before retrying so you do not create a duplicate post.")
                }
            case .retryable, .rateLimited:
                next = attempt >= policy.maxAttempts
                    ? .failed(message: "\(error.message); gave up after \(attempt) attempts.", expireAccount: false)
                    : .retry(at: now.addingTimeInterval(policy.delay(afterAttempt: attempt, retryAfter: error.retryAfter)))
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
    public nonisolated var supportsDeterministicReconciliation: Bool { true }

    public struct Post: Codable, Sendable, Equatable {
        public let id: String
        public let accountID: String
        public let boardID: String
        public let title: String
        public let link: String
        public let idempotencyKey: String
        public let createdAt: Date
    }
    public enum Step: Sendable, Equatable { case ok, retryable, rateLimited(TimeInterval?), auth, permission, permanent, uncertainAfterCreate }

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
        case .rateLimited(let after): throw PublishFailure(.rateLimited, "Mock Pinterest answered 429 Too Many Requests", httpStatus: 429, retryAfter: after)
        case .auth: throw PublishFailure(.auth, "Mock Pinterest answered 401: Authentication failed", httpStatus: 401)
        case .permission: throw PublishFailure(.permission, "Mock Pinterest answered 403: Missing pins:write scope", httpStatus: 403)
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
    public nonisolated var supportsDeterministicReconciliation: Bool { true }
    public static let scopes = ["user_accounts:read", "boards:read", "pins:read", "pins:write"]
    public let apiBase: URL
    public let isSandbox: Bool
    let session: URLSession
    let pollEvery: Duration
    let maxPolls: Int

    public init(apiBase: URL = URL(string: "https://api.pinterest.com")!, session: URLSession = .shared,
                pollEvery: Duration = .seconds(3), maxPolls: Int = 60) {
        self.apiBase = apiBase
        self.isSandbox = apiBase.host?.lowercased().contains("sandbox") == true
        self.session = session
        self.pollEvery = pollEvery
        self.maxPolls = maxPolls
    }

    static func encodeSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&#"))) ?? s
    }

    func makeURL(_ path: String, query: [URLQueryItem] = []) throws(PublishFailure) -> URL {
        guard var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            throw PublishFailure(.permanent, "Invalid Pinterest API base URL.")
        }
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        comps.percentEncodedPath = "/v5" + cleanPath
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw PublishFailure(.permanent, "Could not build Pinterest request URL.") }
        return url
    }

    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String?, body: [String: Any]? = nil) async throws(PublishFailure) -> (Data, String?) {
        guard let token, !token.isEmpty else { throw PublishFailure(.auth, "No access token") }
        var req = URLRequest(url: try makeURL(path, query: query))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            let code = (error as? URLError)?.code
            let maybeSent = code == .timedOut || code == .networkConnectionLost || code == .badServerResponse
            if method == "POST" && maybeSent {
                throw PublishFailure(.uncertain, "Pinterest connection ended before confirmation (\(error.localizedDescription))")
            }
            throw PublishFailure(.retryable, "Could not reach Pinterest: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let requestID = http?.value(forHTTPHeaderField: "x-request-id")
        guard let status = http?.statusCode, (200..<300).contains(status) else {
            let status = http?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let msg = obj?["message"] as? String
            let retryAfter = PublishFailure.parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
            if method == "POST" && (status == 502 || status == 504) {
                throw PublishFailure(.uncertain, "Pinterest gateway timeout (\(status)); verifying whether Pin was created.", httpStatus: status, requestID: requestID)
            }
            var detail = "Pinterest answered \(status)" + (msg.map { ": \($0)" } ?? "")
            if status == 403 && !isSandbox {
                detail += " (Trial Pinterest apps can only publish to Sandbox until Standard access is approved.)"
            }
            throw PublishFailure(PublishFailure.kind(forStatus: status), detail, httpStatus: status, requestID: requestID, retryAfter: retryAfter)
        }
        return (data, requestID)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        if input.isVideo {
            return try await publishVideo(input)
        }
        guard let image = input.image else { throw PublishFailure(.permanent, "A Pin needs an image.") }
        let allowedBase64Type: String
        switch input.contentType.lowercased() {
        case "image/png": allowedBase64Type = "image/png"
        case "image/jpeg", "image/jpg": allowedBase64Type = "image/jpeg"
        default:
            throw PublishFailure(.permanent, "Pinterest image upload requires JPEG or PNG (received \(input.contentType)). Export a JPEG or PNG variant first.")
        }
        var body: [String: Any] = [
            "board_id": input.boardID,
            // No idempotency header exists; the private note carries our key for reconciliation.
            "note": "sf:\(input.idempotencyKey)",
            "media_source": ["source_type": "image_base64", "content_type": allowedBase64Type,
                             "data": image.base64EncodedString()],
        ]
        if let section = input.boardSectionID, !section.isEmpty { body["board_section_id"] = section }
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

    /// Video Pin publishing: register /v5/media, upload multipart to upload_url, wait for processing, create Pin.
    private func publishVideo(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let file = input.mediaFile else { throw PublishFailure(.permanent, "A video Pin needs a video file.") }
        let videoBytes: Data
        do { videoBytes = try Data(contentsOf: file) } catch {
            throw PublishFailure(.permanent, "Could not read video file: \(error.localizedDescription)")
        }
        let mediaID: String
        if let existing = input.existingContainerID, !existing.isEmpty {
            mediaID = existing
        } else {
            let (regData, _) = try await call("POST", "/media", token: input.accessToken, body: ["media_type": "video"])
            let reg = (try? JSONSerialization.jsonObject(with: regData) as? [String: Any]) ?? [:]
            guard let id = reg["media_id"] as? String,
                  let uploadURLStr = reg["upload_url"] as? String,
                  let uploadURL = URL(string: uploadURLStr) else {
                throw PublishFailure(.retryable, "Pinterest did not return a video upload session.")
            }
            let params = (reg["upload_parameters"] as? [String: String]) ?? [:]
            let boundary = "SocialForge-\(UUID().uuidString)"
            var form = Data()
            for (k, v) in params.sorted(by: { $0.key < $1.key }) {
                form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
            }
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(input.contentType)\r\n\r\n".utf8))
            form.append(videoBytes)
            form.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var uploadReq = URLRequest(url: uploadURL)
            uploadReq.httpMethod = "POST"
            uploadReq.timeoutInterval = 600
            uploadReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            uploadReq.httpBody = form
            do {
                let (_, resp) = try await session.data(for: uploadReq)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw PublishFailure(PublishFailure.kind(forStatus: code), "Pinterest video upload returned HTTP \(code)", httpStatus: code)
                }
            } catch let failure as PublishFailure {
                throw failure
            } catch {
                throw PublishFailure(.retryable, "Pinterest video upload failed: \(error.localizedDescription)")
            }
            mediaID = id
        }
        // Wait for media processing
        for _ in 0..<maxPolls {
            let (statusData, _) = try await call("GET", "/media/\(Self.encodeSegment(mediaID))", token: input.accessToken)
            let obj = (try? JSONSerialization.jsonObject(with: statusData) as? [String: Any]) ?? [:]
            switch obj["status"] as? String ?? "" {
            case "succeeded":
                var body: [String: Any] = [
                    "board_id": input.boardID,
                    "note": "sf:\(input.idempotencyKey)",
                    "media_source": ["source_type": "video_id", "media_id": mediaID, "cover_image_key_frame_time": 1],
                ]
                if let section = input.boardSectionID, !section.isEmpty { body["board_section_id"] = section }
                if !input.title.isEmpty { body["title"] = input.title }
                if !input.description.isEmpty { body["description"] = input.description }
                if !input.link.isEmpty { body["link"] = input.link }
                if !input.altText.isEmpty { body["alt_text"] = input.altText }
                let (data, requestID) = try await call("POST", "/pins", token: input.accessToken, body: body)
                guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
                    throw PublishFailure(.uncertain, "Pinterest answered without a Pin id")
                }
                return PublishOutcome(providerPostID: id, url: "https://www.pinterest.com/pin/\(id)/", requestID: requestID, containerID: mediaID)
            case "failed":
                throw PublishFailure(.permanent, "Pinterest failed to process the video.")
            default:
                try? await Task.sleep(for: pollEvery)
            }
        }
        throw PublishFailure(.retryable, "Pinterest is still processing the video; trying again later")
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        let boardSeg = Self.encodeSegment(input.boardID)
        var bookmark: String?
        for _ in 0..<5 {
            var q = [URLQueryItem(name: "page_size", value: "50")]
            if let bookmark { q.append(URLQueryItem(name: "bookmark", value: bookmark)) }
            let (data, _) = try await call("GET", "/boards/\(boardSeg)/pins", query: q, token: input.accessToken)
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let items = (obj["items"] as? [[String: Any]]) ?? []
            if let hit = items.first(where: { $0["note"] as? String == "sf:\(input.idempotencyKey)" }), let id = hit["id"] as? String {
                return PublishOutcome(providerPostID: id, url: "https://www.pinterest.com/pin/\(id)/", requestID: nil)
            }
            bookmark = obj["bookmark"] as? String
            if bookmark == nil { break }
        }
        return nil
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        var out: [API.Board] = []
        var bookmark: String?
        repeat {
            var q = [URLQueryItem(name: "page_size", value: "100")]
            if let bookmark { q.append(URLQueryItem(name: "bookmark", value: bookmark)) }
            let (data, _) = try await call("GET", "/boards", query: q, token: accessToken)
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            for b in (obj["items"] as? [[String: Any]]) ?? [] {
                if let id = b["id"] as? String, let name = b["name"] as? String { out.append(API.Board(id: id, name: name, privacy: b["privacy"] as? String)) }
            }
            bookmark = obj["bookmark"] as? String
        } while bookmark != nil && out.count < 1000
        return out
    }

    /// Discovers sections within a board (paginated).
    public func boardSections(boardID: String, accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        var out: [API.Board] = []
        var bookmark: String?
        let seg = Self.encodeSegment(boardID)
        repeat {
            var q = [URLQueryItem(name: "page_size", value: "100")]
            if let bookmark { q.append(URLQueryItem(name: "bookmark", value: bookmark)) }
            let (data, _) = try await call("GET", "/boards/\(seg)/sections", query: q, token: accessToken)
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            for s in (obj["items"] as? [[String: Any]]) ?? [] {
                if let id = s["id"] as? String, let name = s["name"] as? String {
                    out.append(API.Board(id: id, name: name, privacy: nil))
                }
            }
            bookmark = obj["bookmark"] as? String
        } while bookmark != nil && out.count < 500
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

    public struct Tokens: Sendable, Equatable {
        public let access: String
        public let refresh: String?
        public let expiresIn: Int?
        public let refreshExpiresIn: Int?
        public let scopes: [String]
    }

    public func exchange(code: String, redirectURI: String, clientID: String, clientSecret: String) async throws(PublishFailure) -> Tokens {
        try await tokenRequest(items: [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
        ], clientID: clientID, clientSecret: clientSecret)
    }

    /// Exchanges a Pinterest refresh token for a fresh access token (preserving rotated refresh tokens).
    public func refreshToken(_ refreshToken: String, clientID: String, clientSecret: String) async throws(PublishFailure) -> Tokens {
        try await tokenRequest(items: [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
        ], clientID: clientID, clientSecret: clientSecret)
    }

    private func tokenRequest(items: [URLQueryItem], clientID: String, clientSecret: String) async throws(PublishFailure) -> Tokens {
        var req = URLRequest(url: apiBase.appending(path: "v5/oauth/token"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = items
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw PublishFailure(.retryable, error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw PublishFailure(status == 400 || status == 401 ? .auth : PublishFailure.kind(forStatus: status),
                                 "Pinterest token request failed (\(status))" + (msg.map { ": \($0)" } ?? ""), httpStatus: status)
        }
        return Tokens(
            access: access,
            refresh: obj["refresh_token"] as? String,
            expiresIn: obj["expires_in"] as? Int,
            refreshExpiresIn: obj["refresh_token_expires_in"] as? Int,
            scopes: ((obj["scope"] as? String) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        )
    }

    public func userAccount(accessToken: String) async throws(PublishFailure) -> (id: String, name: String, username: String) {
        let (data, _) = try await call("GET", "/user_account", token: accessToken)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let username = obj["username"] as? String ?? "pinterest"
        return ((obj["id"] as? String) ?? username, (obj["business_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username, username)
    }
}

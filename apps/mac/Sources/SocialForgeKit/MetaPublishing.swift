import Foundation

// Publishing to Facebook Pages, Instagram (professional accounts), and Threads
// with your own Meta app. LIVE STATUS: UNVERIFIED. Built from Meta's documented
// request shapes (Graph API v25.0, Threads API v1.0); no real post made yet.
//
// - Facebook Page photos and Reels, and Instagram Reels, upload from this Mac.
// - Instagram photos and Threads images and videos are fetched by Meta from a
//   public URL, so they need public media storage (PublicMedia.swift).

public enum Meta {
    public static let graphVersion = "v25.0"
    public static let threadsVersion = "v1.0"
    /// Facebook Login permissions for Pages and Instagram professional accounts.
    public static let facebookScopes = ["pages_show_list", "pages_read_engagement", "pages_manage_posts",
                                        "instagram_basic", "instagram_content_publish", "business_management"]
    public static let threadsScopes = ["threads_basic", "threads_content_publish"]
    /// Meta's page for desktop sign-in; register it as a redirect URI and paste back where the browser lands.
    public static let desktopRedirect = "https://www.facebook.com/connect/login_success.html"

    /// A Graph or Threads API error, in words a person can act on.
    public static func failure(status: Int, body: Data, service: String, requestID: String? = nil) -> PublishFailure {
        let err = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let code = err?["code"] as? Int ?? 0
        let sub = err?["error_subcode"] as? Int ?? 0
        let msg = (err?["error_user_msg"] as? String) ?? (err?["message"] as? String) ?? "\(service) answered \(status)"
        let trace = requestID ?? err?["fbtrace_id"] as? String
        switch code {
        case 190, 102:
            return PublishFailure(.auth, "The \(service) sign-in expired or was revoked (\(msg))", httpStatus: status, requestID: trace)
        case 10, 200...299:
            return PublishFailure(.auth, "Missing permission for \(service): \(msg)", httpStatus: status, requestID: trace)
        case 4, 17, 32, 613, 80001...80014:
            return PublishFailure(.retryable, "\(service) is limiting requests; trying again later (\(msg))", httpStatus: status, requestID: trace)
        case 9 where sub == 2207042:
            return PublishFailure(.retryable, "Instagram's 24-hour publishing limit is reached; trying again later", httpStatus: status, requestID: trace)
        case 1, 2:
            return PublishFailure(.retryable, "\(service) had a temporary problem (\(msg))", httpStatus: status, requestID: trace)
        case 368:
            return PublishFailure(.permanent, "\(service) has temporarily blocked posting from this account: \(msg)", httpStatus: status, requestID: trace)
        default:
            if err == nil { return PublishFailure(PublishFailure.kind(forStatus: status), msg, httpStatus: status, requestID: trace) }
            return PublishFailure(status >= 500 ? .retryable : .permanent, "\(service): \(msg)", httpStatus: status, requestID: trace)
        }
    }
}

/// Requests to graph.facebook.com, rupload.facebook.com, and graph.threads.net.
public struct MetaHTTP: Sendable {
    public let service: String
    let session: URLSession

    public init(service: String, session: URLSession = .shared) { self.service = service; self.session = session }

    static func form(_ params: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" is a space in form bodies; keep it literal.
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    static func url(_ base: URL, _ path: String, query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// Sends and returns the JSON object. A POST that times out is uncertain: it may have been carried out.
    public func json(_ req: URLRequest) async throws(PublishFailure) -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            if let file = req.value(forHTTPHeaderField: "X-SF-Upload-File") {
                var r = req
                r.setValue(nil, forHTTPHeaderField: "X-SF-Upload-File")
                (data, response) = try await session.upload(for: r, fromFile: URL(fileURLWithPath: file))
            } else {
                (data, response) = try await session.data(for: req)
            }
        } catch {
            if req.httpMethod == "POST", (error as? URLError)?.code == .timedOut {
                throw PublishFailure(.uncertain, "\(service) did not answer in time")
            }
            throw PublishFailure(.retryable, "Could not reach \(service): \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let trace = http?.value(forHTTPHeaderField: "x-fb-trace-id")
        guard (200..<300).contains(status) else { throw Meta.failure(status: status, body: data, service: service, requestID: trace) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func get(_ base: URL, _ path: String, token: String, query: [String: String] = [:]) async throws(PublishFailure) -> [String: Any] {
        var q = query
        q["access_token"] = token
        var req = URLRequest(url: Self.url(base, path, query: q))
        req.timeoutInterval = 30
        return try await json(req)
    }

    public func post(_ base: URL, _ path: String, token: String?, params: [String: String]) async throws(PublishFailure) -> [String: Any] {
        var p = params
        if let token { p["access_token"] = token }
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(p)
        return try await json(req)
    }

    /// The bytes of a local file to a rupload address (Instagram Reels and Facebook Reels).
    public func rupload(_ url: URL, token: String, file: URL) async throws(PublishFailure) -> [String: Any] {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw PublishFailure(.permanent, "The video file is missing or empty.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "offset")
        req.setValue(String(size), forHTTPHeaderField: "file_size")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(file.path, forHTTPHeaderField: "X-SF-Upload-File")
        do { return try await json(req) } catch {
            // Uploading bytes is not posting: a timeout here is safe to retry.
            throw error.kind == .uncertain ? PublishFailure(.retryable, error.message) : error
        }
    }
}

/// Posts that look like ours, for reconciling after an uncertain attempt.
enum MetaReconcile {
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        // Graph uses "2026-11-19T12:00:00+0000".
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return g.date(from: s)
    }

    /// The first item whose text equals `caption`, made after `since` (two minutes of clock slack).
    static func match(_ items: [[String: Any]], textKey: String, timeKey: String, caption: String, since: Date) -> [String: Any]? {
        let want = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.first { item in
            let text = (item[textKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let made = date(item[timeKey] as? String) ?? .distantPast
            return text == want && made >= since.addingTimeInterval(-120)
        }
    }
}

// MARK: - Facebook Pages

/// `input.boardID` is the Page id; the token is the Page access token.
public struct FacebookPageTarget: PublishTarget {
    public let graph: URL
    public let rupload: URL
    let http: MetaHTTP

    public init(graph: URL = URL(string: "https://graph.facebook.com/\(Meta.graphVersion)")!,
                rupload: URL = URL(string: "https://rupload.facebook.com")!, session: URLSession = .shared) {
        self.graph = graph; self.rupload = rupload; http = MetaHTTP(service: "Facebook", session: session)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No Page access token") }
        let page = input.boardID
        if input.isVideo {
            guard let file = input.mediaFile else { throw PublishFailure(.permanent, "The video file is missing.") }
            // Reels: start, upload the bytes, finish with PUBLISHED.
            let start = try await http.post(graph, "\(page)/video_reels", token: token, params: ["upload_phase": "start"])
            guard let videoID = start["video_id"] as? String else { throw PublishFailure(.retryable, "Facebook did not start the upload") }
            let uploadURL = (start["upload_url"] as? String).flatMap(URL.init(string:)) ?? rupload.appending(path: "video-upload/\(Meta.graphVersion)/\(videoID)")
            _ = try await http.rupload(uploadURL, token: token, file: file)
            var params = ["upload_phase": "finish", "video_id": videoID, "video_state": "PUBLISHED"]
            if !input.caption.isEmpty { params["description"] = input.caption }
            let done = try await http.post(graph, "\(page)/video_reels", token: token, params: params)
            guard done["success"] as? Bool ?? true else { throw PublishFailure(.uncertain, "Facebook did not confirm the Reel") }
            return PublishOutcome(providerPostID: videoID, url: "https://www.facebook.com/reel/\(videoID)", requestID: nil)
        }
        if let file = input.mediaFile, let image = input.image ?? (try? Data(contentsOf: file)) {
            // A photo, uploaded from this Mac as multipart.
            let boundary = "SocialForge-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("access_token", token)
            field("published", "true")
            if !input.caption.isEmpty { field("message", input.caption) }
            if !input.altText.isEmpty { field("alt_text_custom", input.altText) }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"source\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(input.contentType)\r\n\r\n".utf8))
            body.append(image)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: graph.appending(path: "\(page)/photos"))
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let out = try await http.json(req)
            guard let id = (out["post_id"] as? String) ?? (out["id"] as? String) else { throw PublishFailure(.uncertain, "Facebook answered without a post id") }
            return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/\(id)", requestID: nil)
        }
        guard !input.caption.isEmpty else { throw PublishFailure(.permanent, "The post has no text and no image.") }
        var params = ["message": input.caption]
        if !input.link.isEmpty, !input.caption.contains(input.link) { params["link"] = input.link }
        let out = try await http.post(graph, "\(page)/feed", token: token, params: params)
        guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Facebook answered without a post id") }
        return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/\(id)", requestID: nil)
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        guard let token = input.accessToken else { return nil }
        if input.isVideo {
            let out = try await http.get(graph, "\(input.boardID)/video_reels", token: token, query: ["fields": "id,description,created_time", "limit": "25"])
            guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "description", timeKey: "created_time",
                                                caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
            return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/reel/\(id)", requestID: nil)
        }
        let out = try await http.get(graph, "\(input.boardID)/published_posts", token: token,
                                     query: ["fields": "id,message,created_time,permalink_url", "limit": "25"])
        guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "message", timeKey: "created_time",
                                            caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: hit["permalink_url"] as? String ?? "https://www.facebook.com/\(id)", requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "page", name: "Page feed and Reels", privacy: "PUBLIC")]
    }
}

// MARK: - Instagram

/// `input.boardID` is the Instagram professional account id; the token is the Facebook user token.
public struct InstagramTarget: PublishTarget {
    public let graph: URL
    public let rupload: URL
    let http: MetaHTTP
    let media: (any PublicMediaHost)?
    let pollEvery: Duration
    let maxPolls: Int

    public init(graph: URL = URL(string: "https://graph.facebook.com/\(Meta.graphVersion)")!,
                rupload: URL = URL(string: "https://rupload.facebook.com")!, media: (any PublicMediaHost)?,
                session: URLSession = .shared, pollEvery: Duration = .seconds(5), maxPolls: Int = 60) {
        self.graph = graph; self.rupload = rupload; self.media = media
        http = MetaHTTP(service: "Instagram", session: session); self.pollEvery = pollEvery; self.maxPolls = maxPolls
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No Instagram access token") }
        let ig = input.boardID
        var params: [String: String] = [:]
        if !input.caption.isEmpty { params["caption"] = input.caption }
        var hosted: PublicMedia?
        let container: String
        if input.isVideo {
            guard let file = input.mediaFile else { throw PublishFailure(.permanent, "The video file is missing.") }
            params["media_type"] = "REELS"
            params["upload_type"] = "resumable"
            let made = try await http.post(graph, "\(ig)/media", token: token, params: params)
            guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Instagram did not create the Reel container") }
            let uploadURL = (made["uri"] as? String).flatMap(URL.init(string:)) ?? rupload.appending(path: "ig-api-upload/\(Meta.graphVersion)/\(id)")
            _ = try await http.rupload(uploadURL, token: token, file: file)
            container = id
        } else {
            guard let file = input.mediaFile else { throw PublishFailure(.permanent, "Instagram posts need a photo or a video.") }
            guard let media else {
                throw PublishFailure(.permanent, "Instagram fetches photos from a public address. Set up public media storage in Settings › Publishing, or post a video (Reel), which uploads from this Mac.")
            }
            hosted = try await media.put(file: file, contentType: input.contentType)
            params["image_url"] = hosted!.url.absoluteString
            if !input.altText.isEmpty { params["alt_text"] = input.altText }
            let made = try await http.post(graph, "\(ig)/media", token: token, params: params)
            guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Instagram did not create the photo container") }
            container = id
        }
        do throws(PublishFailure) {
            try await waitUntilFinished(container, token: token)
            let out = try await http.post(graph, "\(ig)/media_publish", token: token, params: ["creation_id": container])
            guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Instagram answered without a media id") }
            let link = (try? await http.get(graph, id, token: token, query: ["fields": "permalink"]))?["permalink"] as? String
            if let hosted, let media { await media.delete(key: hosted.key) }
            return PublishOutcome(providerPostID: id, url: link, requestID: nil)
        } catch {
            if error.kind != .uncertain, let hosted, let media { await media.delete(key: hosted.key) }
            throw error
        }
    }

    /// Containers must reach FINISHED before media_publish. ERROR and EXPIRED stop.
    func waitUntilFinished(_ container: String, token: String) async throws(PublishFailure) {
        for _ in 0..<maxPolls {
            let s = try await http.get(graph, container, token: token, query: ["fields": "status_code,status"])
            switch s["status_code"] as? String ?? "" {
            case "FINISHED", "PUBLISHED": return
            case "ERROR": throw PublishFailure(.permanent, "Instagram could not process the media: \(s["status"] as? String ?? "unknown error")")
            case "EXPIRED": throw PublishFailure(.retryable, "The Instagram container expired before publishing")
            default: try? await Task.sleep(for: pollEvery)
            }
        }
        throw PublishFailure(.retryable, "Instagram is still processing the media; trying again later")
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        guard let token = input.accessToken else { return nil }
        let out = try await http.get(graph, "\(input.boardID)/media", token: token, query: ["fields": "id,caption,permalink,timestamp", "limit": "25"])
        guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "caption", timeKey: "timestamp",
                                            caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: hit["permalink"] as? String, requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "feed", name: "Feed and Reels", privacy: "PUBLIC")]
    }
}

// MARK: - Threads

/// `input.boardID` is the Threads user id; the token is the Threads user token.
public struct ThreadsTarget: PublishTarget {
    public let api: URL
    let http: MetaHTTP
    let media: (any PublicMediaHost)?
    let pollEvery: Duration
    let maxPolls: Int

    public init(api: URL = URL(string: "https://graph.threads.net/\(Meta.threadsVersion)")!, media: (any PublicMediaHost)?,
                session: URLSession = .shared, pollEvery: Duration = .seconds(5), maxPolls: Int = 60) {
        self.api = api; self.media = media; http = MetaHTTP(service: "Threads", session: session)
        self.pollEvery = pollEvery; self.maxPolls = maxPolls
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No Threads access token") }
        let user = input.boardID.isEmpty ? "me" : input.boardID
        var params: [String: String] = [:]
        if !input.caption.isEmpty { params["text"] = input.caption }
        var hosted: PublicMedia?
        if let file = input.mediaFile {
            guard let media else {
                throw PublishFailure(.permanent, "Threads fetches photos and videos from a public address. Set up public media storage in Settings › Publishing, or post text only.")
            }
            hosted = try await media.put(file: file, contentType: input.isVideo ? "video/mp4" : input.contentType)
            params["media_type"] = input.isVideo ? "VIDEO" : "IMAGE"
            params[input.isVideo ? "video_url" : "image_url"] = hosted!.url.absoluteString
            if !input.altText.isEmpty { params["alt_text"] = input.altText }
        } else {
            guard !input.caption.isEmpty else { throw PublishFailure(.permanent, "The post has no text and no media.") }
            params["media_type"] = "TEXT"
        }
        do throws(PublishFailure) {
            let made = try await http.post(api, "\(user)/threads", token: token, params: params)
            guard let container = made["id"] as? String else { throw PublishFailure(.retryable, "Threads did not create the post container") }
            if hosted != nil { try await waitUntilFinished(container, token: token) }
            let out = try await http.post(api, "\(user)/threads_publish", token: token, params: ["creation_id": container])
            guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Threads answered without a post id") }
            let link = (try? await http.get(api, id, token: token, query: ["fields": "permalink"]))?["permalink"] as? String
            if let hosted, let media { await media.delete(key: hosted.key) }
            return PublishOutcome(providerPostID: id, url: link, requestID: nil)
        } catch {
            if error.kind != .uncertain, let hosted, let media { await media.delete(key: hosted.key) }
            throw error
        }
    }

    func waitUntilFinished(_ container: String, token: String) async throws(PublishFailure) {
        for _ in 0..<maxPolls {
            let s = try await http.get(api, container, token: token, query: ["fields": "status,error_message"])
            switch s["status"] as? String ?? "" {
            case "FINISHED", "PUBLISHED": return
            case "ERROR": throw PublishFailure(.permanent, "Threads could not process the media: \(s["error_message"] as? String ?? "unknown error")")
            case "EXPIRED": throw PublishFailure(.retryable, "The Threads container expired before publishing")
            default: try? await Task.sleep(for: pollEvery)
            }
        }
        throw PublishFailure(.retryable, "Threads is still processing the media; trying again later")
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        guard let token = input.accessToken else { return nil }
        let user = input.boardID.isEmpty ? "me" : input.boardID
        let out = try await http.get(api, "\(user)/threads", token: token, query: ["fields": "id,text,permalink,timestamp", "limit": "25"])
        guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "text", timeKey: "timestamp",
                                            caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: hit["permalink"] as? String, requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "profile", name: "Profile", privacy: "PUBLIC")]
    }
}

// MARK: - Sign-in

/// One Facebook Page the user manages, with its token and linked Instagram professional account.
public struct MetaPage: Sendable, Equatable {
    public let id: String
    public let name: String
    public let token: String
    public let instagramID: String?
    public let instagramUsername: String?
}

public struct MetaToken: Sendable, Equatable {
    public let token: String
    public let expiresIn: Int?
    public let userID: String?
}

public enum OAuthRedirect {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noCode, denied(String), badState
        public var description: String {
            switch self {
            case .noCode: "That address has no sign-in code. Copy the whole address from the browser after you allow access."
            case .denied(let why): "Access was not granted: \(why)"
            case .badState: "That address is from a different sign-in. Start again."
            }
        }
    }

    /// The code from the address the browser landed on (or the bare code itself).
    public static func code(from pasted: String, state: String) throws(ParseError) -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text), comps.scheme != nil else {
            // A bare code. Threads adds "#_" to its codes.
            guard !text.isEmpty, !text.contains(" ") else { throw .noCode }
            return text.hasSuffix("#_") ? String(text.dropLast(2)) : text
        }
        var items = comps.queryItems ?? []
        // Some flows put the answer after "#".
        if let fragment = comps.fragment, let f = URLComponents(string: "?" + fragment)?.queryItems { items += f }
        let value = { (n: String) in items.first { $0.name == n }?.value }
        if let err = value("error_description") ?? value("error_reason") ?? value("error") { throw .denied(err) }
        guard let code = value("code"), !code.isEmpty else { throw .noCode }
        if let s = value("state"), s != state { throw .badState }
        return code.hasSuffix("#_") ? String(code.dropLast(2)) : code
    }
}

public struct MetaAuth: Sendable {
    public let graph: URL
    public let threads: URL
    let http: MetaHTTP

    public init(graph: URL = URL(string: "https://graph.facebook.com/\(Meta.graphVersion)")!,
                threads: URL = URL(string: "https://graph.threads.net")!, session: URLSession = .shared) {
        self.graph = graph; self.threads = threads; http = MetaHTTP(service: "Meta", session: session)
    }

    /// Facebook Login. With a Facebook Login for Business configuration id, the configuration's permissions apply.
    public static func facebookAuthorizeURL(appID: String, redirectURI: String, state: String, configID: String? = nil) -> URL {
        var c = URLComponents(string: "https://www.facebook.com/\(Meta.graphVersion)/dialog/oauth")!
        var q: [URLQueryItem] = [.init(name: "client_id", value: appID), .init(name: "redirect_uri", value: redirectURI),
                                 .init(name: "state", value: state), .init(name: "response_type", value: "code")]
        if let configID, !configID.isEmpty { q.append(.init(name: "config_id", value: configID)) }
        else { q.append(.init(name: "scope", value: Meta.facebookScopes.joined(separator: ","))) }
        c.queryItems = q
        return c.url!
    }

    public static func threadsAuthorizeURL(appID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://threads.net/oauth/authorize")!
        c.queryItems = [.init(name: "client_id", value: appID), .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "scope", value: Meta.threadsScopes.joined(separator: ",")),
                        .init(name: "response_type", value: "code"), .init(name: "state", value: state)]
        return c.url!
    }

    /// Code → short-lived user token → long-lived (about 60 days) user token.
    public func facebookToken(code: String, redirectURI: String, appID: String, secret: String) async throws(PublishFailure) -> MetaToken {
        var req = URLRequest(url: MetaHTTP.url(graph, "oauth/access_token", query: ["client_id": appID, "client_secret": secret,
                                                                                   "redirect_uri": redirectURI, "code": code]))
        req.timeoutInterval = 30
        let short = try await http.json(req)
        guard let s = short["access_token"] as? String else { throw PublishFailure(.permanent, "Facebook did not return a token") }
        var req2 = URLRequest(url: MetaHTTP.url(graph, "oauth/access_token", query: ["grant_type": "fb_exchange_token", "client_id": appID,
                                                                                    "client_secret": secret, "fb_exchange_token": s]))
        req2.timeoutInterval = 30
        let long = try await http.json(req2)
        return MetaToken(token: long["access_token"] as? String ?? s, expiresIn: long["expires_in"] as? Int, userID: nil)
    }

    public func grantedPermissions(_ userToken: String) async throws(PublishFailure) -> [String] {
        let out = try await http.get(graph, "me/permissions", token: userToken)
        return (out["data"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "granted" }.compactMap { $0["permission"] as? String }
    }

    /// Pages the user manages. Page tokens made from a long-lived user token do not expire.
    public func pages(_ userToken: String) async throws(PublishFailure) -> [MetaPage] {
        let out = try await http.get(graph, "me/accounts", token: userToken,
                                     query: ["fields": "id,name,access_token,instagram_business_account{id,username}", "limit": "100"])
        return (out["data"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String, let token = p["access_token"] as? String else { return nil }
            let ig = p["instagram_business_account"] as? [String: Any]
            return MetaPage(id: id, name: p["name"] as? String ?? "Page", token: token,
                            instagramID: ig?["id"] as? String, instagramUsername: ig?["username"] as? String)
        }
    }

    /// Code → short-lived Threads token → long-lived (60 days) token.
    public func threadsToken(code: String, redirectURI: String, appID: String, secret: String) async throws(PublishFailure) -> MetaToken {
        let short = try await http.post(threads, "oauth/access_token", token: nil,
                                        params: ["client_id": appID, "client_secret": secret, "grant_type": "authorization_code",
                                                 "redirect_uri": redirectURI, "code": code])
        guard let s = short["access_token"] as? String else { throw PublishFailure(.permanent, "Threads did not return a token") }
        let userID = (short["user_id"] as? String) ?? (short["user_id"] as? Int).map(String.init)
        var req = URLRequest(url: MetaHTTP.url(threads, "access_token", query: ["grant_type": "th_exchange_token", "client_secret": secret, "access_token": s]))
        req.timeoutInterval = 30
        let long = try await http.json(req)
        return MetaToken(token: long["access_token"] as? String ?? s, expiresIn: long["expires_in"] as? Int, userID: userID)
    }

    /// A long-lived Threads token refreshed for another 60 days (it must be at least a day old and unexpired).
    public func refreshThreadsToken(_ token: String) async throws(PublishFailure) -> MetaToken {
        var req = URLRequest(url: MetaHTTP.url(threads, "refresh_access_token", query: ["grant_type": "th_refresh_token", "access_token": token]))
        req.timeoutInterval = 30
        let out = try await http.json(req)
        guard let t = out["access_token"] as? String else { throw PublishFailure(.auth, "Threads did not refresh the token") }
        return MetaToken(token: t, expiresIn: out["expires_in"] as? Int, userID: nil)
    }

    public func threadsProfile(_ token: String) async throws(PublishFailure) -> (id: String, username: String) {
        let out = try await http.get(threads.appending(path: Meta.threadsVersion), "me", token: token, query: ["fields": "id,username"])
        let id = out["id"] as? String ?? "me"
        return (id, out["username"] as? String ?? "threads")
    }
}

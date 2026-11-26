import Foundation

// Publishing to Facebook Pages, Instagram (professional accounts via Facebook Login or
// Instagram Business Login), and Threads with your own Meta app.
// LIVE STATUS: UNVERIFIED. Built from Meta's documented request shapes (Graph API v25.0,
// Instagram Graph API, Threads API v1.0); no real post made yet.
//
// - Facebook Page photos, multi-photos, and Reels, and Instagram Reels, upload from this Mac.
// - Instagram photos/carousels and Threads images/videos/carousels are fetched by Meta from a
//   public URL, so they need public media storage (PublicMedia.swift).

public enum Meta {
    public static let graphVersion = "v25.0"
    public static let threadsVersion = "v1.0"
    /// Facebook Login permissions for Pages and Instagram professional accounts.
    public static let facebookScopes = ["pages_show_list", "pages_read_engagement", "pages_manage_posts",
                                        "instagram_basic", "instagram_content_publish", "business_management"]
    /// Direct Instagram Business Login permissions (does not require a linked Facebook Page).
    public static let instagramLoginScopes = ["instagram_business_basic", "instagram_business_content_publish"]
    public static let threadsScopes = ["threads_basic", "threads_content_publish"]
    /// Meta's page for desktop sign-in; register it as a redirect URI and paste back where the browser lands.
    public static let desktopRedirect = "https://www.facebook.com/connect/login_success.html"

    /// A Graph or Threads API error, in words a person can act on.
    public static func failure(status: Int, body: Data, service: String, requestID: String? = nil, retryAfter: TimeInterval? = nil) -> PublishFailure {
        let err = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let code = err?["code"] as? Int ?? 0
        let sub = err?["error_subcode"] as? Int ?? 0
        let msg = (err?["error_user_msg"] as? String) ?? (err?["message"] as? String) ?? "\(service) answered \(status)"
        let trace = requestID ?? err?["fbtrace_id"] as? String
        switch code {
        case 190, 102:
            return PublishFailure(.auth, "The \(service) sign-in expired or was revoked (\(msg))", httpStatus: status, requestID: trace)
        case 10, 200...299:
            return PublishFailure(.permission, "Missing permission for \(service): \(msg)", httpStatus: status, requestID: trace)
        case 4, 17, 32, 613, 80001...80014:
            return PublishFailure(.rateLimited, "\(service) is limiting requests; trying again later (\(msg))", httpStatus: status, requestID: trace, retryAfter: retryAfter)
        case 9 where sub == 2207042:
            // Instagram 24-hour publishing limit: defer rather than burning retries in 30 minutes.
            return PublishFailure(.rateLimited, "Instagram's 24-hour publishing limit is reached; trying again later", httpStatus: status, requestID: trace, retryAfter: retryAfter ?? 3600)
        case 1, 2:
            return PublishFailure(.retryable, "\(service) had a temporary problem (\(msg))", httpStatus: status, requestID: trace, retryAfter: retryAfter)
        case 368:
            return PublishFailure(.permanent, "\(service) has temporarily blocked posting from this account: \(msg)", httpStatus: status, requestID: trace)
        default:
            if err == nil { return PublishFailure(PublishFailure.kind(forStatus: status), msg, httpStatus: status, requestID: trace, retryAfter: retryAfter) }
            return PublishFailure(status >= 500 ? .retryable : .permanent, "\(service): \(msg)", httpStatus: status, requestID: trace, retryAfter: retryAfter)
        }
    }
}

/// Requests to graph.facebook.com, graph.instagram.com, rupload.facebook.com, and graph.threads.net.
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

    static func url(_ base: URL, _ path: String, query: [String: String] = [:]) throws(PublishFailure) -> URL {
        guard var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw PublishFailure(.permanent, "Could not construct \(path) URL.")
        }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let built = c.url else { throw PublishFailure(.permanent, "Could not construct \(path) URL.") }
        return built
    }

    /// Sends and returns the JSON object. A POST whose outcome may have reached the server is uncertain.
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
            let code = (error as? URLError)?.code
            let maybeSent = code == .timedOut || code == .networkConnectionLost || code == .badServerResponse
            if req.httpMethod == "POST" && maybeSent {
                throw PublishFailure(.uncertain, "\(service) did not answer in time")
            }
            throw PublishFailure(.retryable, "Could not reach \(service): \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let trace = http?.value(forHTTPHeaderField: "x-fb-trace-id")
        let retryAfter = PublishFailure.parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
        if req.httpMethod == "POST" && (status == 502 || status == 504) {
            throw PublishFailure(.uncertain, "\(service) gateway timeout (\(status))", httpStatus: status, requestID: trace)
        }
        guard (200..<300).contains(status) else {
            throw Meta.failure(status: status, body: data, service: service, requestID: trace, retryAfter: retryAfter)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Uses Authorization: Bearer header instead of putting tokens in URL query strings.
    public func get(_ base: URL, _ path: String, token: String, query: [String: String] = [:]) async throws(PublishFailure) -> [String: Any] {
        var req = URLRequest(url: try Self.url(base, path, query: query))
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await json(req)
    }

    public func getAbsolute(_ url: URL, token: String) async throws(PublishFailure) -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await json(req)
    }

    public func post(_ base: URL, _ path: String, token: String?, params: [String: String]) async throws(PublishFailure) -> [String: Any] {
        var p = params
        if let token { p["access_token"] = token }
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
    private static let lock = NSLock()
    private static let graphDateFormatter: DateFormatter = {
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return g
    }()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = ISO8601.parse(s) { return d }
        return lock.withLock { graphDateFormatter.date(from: s) }
    }

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Matches a unique recent post with the same normalized non-empty caption made after `since`.
    /// Never matches empty captions, and returns nil if multiple matching posts exist (ambiguous).
    static func match(_ items: [[String: Any]], textKey: String, timeKey: String, caption: String, since: Date) -> [String: Any]? {
        let want = normalize(caption)
        guard !want.isEmpty else { return nil }
        let cutoff = since.addingTimeInterval(-120)
        let matches = items.filter { item in
            let text = normalize(item[textKey] as? String ?? "")
            let made = date(item[timeKey] as? String) ?? .distantPast
            return text == want && made >= cutoff
        }
        guard matches.count == 1 else { return nil }
        return matches.first
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
            let videoID: String
            if let existing = input.existingContainerID, !existing.isEmpty {
                videoID = existing
            } else {
                let start = try await http.post(graph, "\(page)/video_reels", token: token, params: ["upload_phase": "start"])
                guard let id = start["video_id"] as? String else { throw PublishFailure(.retryable, "Facebook did not start the upload") }
                let uploadURL = (start["upload_url"] as? String).flatMap(URL.init(string:)) ?? rupload.appending(path: "video-upload/\(Meta.graphVersion)/\(id)")
                _ = try await http.rupload(uploadURL, token: token, file: file)
                videoID = id
            }
            var params = ["upload_phase": "finish", "video_id": videoID, "video_state": "PUBLISHED"]
            if !input.caption.isEmpty { params["description"] = input.caption }
            let done = try await http.post(graph, "\(page)/video_reels", token: token, params: params)
            guard done["success"] as? Bool == true else {
                throw PublishFailure(.uncertain, "Facebook did not confirm the Reel publication.")
            }
            return PublishOutcome(providerPostID: videoID, url: "https://www.facebook.com/reel/\(videoID)", requestID: nil, containerID: videoID)
        }
        // Multi-photo post (unpublished photo uploads attached to a single Page feed post).
        if let firstFile = input.mediaFile, !input.extraMediaFiles.isEmpty {
            let allFiles = [firstFile] + input.extraMediaFiles
            var attached: [String] = []
            for file in allFiles {
                let bytes: Data
                do { bytes = try Data(contentsOf: file) } catch {
                    throw PublishFailure(.permanent, "Could not read photo file \(file.lastPathComponent): \(error.localizedDescription)")
                }
                let uploaded = try await uploadPhoto(page: page, token: token, file: file, bytes: bytes,
                                                     contentType: input.contentType, caption: "", altText: "", published: false)
                guard let photoID = uploaded["id"] as? String else {
                    throw PublishFailure(.retryable, "Facebook did not return a photo id for \(file.lastPathComponent)")
                }
                attached.append(photoID)
            }
            var params: [String: String] = [:]
            if !input.caption.isEmpty { params["message"] = input.caption }
            for (idx, pid) in attached.enumerated() {
                params["attached_media[\(idx)]"] = "{\"media_fbid\":\"\(pid)\"}"
            }
            let out = try await http.post(graph, "\(page)/feed", token: token, params: params)
            guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Facebook answered without a post id") }
            return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/\(id)", requestID: nil)
        }
        if let file = input.mediaFile {
            let image: Data
            if let provided = input.image {
                image = provided
            } else {
                do { image = try Data(contentsOf: file) } catch {
                    // Never silently downgrade a broken image post to text-only.
                    throw PublishFailure(.permanent, "Could not read photo file \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let out = try await uploadPhoto(page: page, token: token, file: file, bytes: image,
                                            contentType: input.contentType, caption: input.caption,
                                            altText: input.altText, published: true)
            guard let id = (out["post_id"] as? String) ?? (out["id"] as? String) else {
                throw PublishFailure(.uncertain, "Facebook answered without a post id")
            }
            return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/\(id)", requestID: nil)
        }
        guard !input.caption.isEmpty else { throw PublishFailure(.permanent, "The post has no text and no image.") }
        var params = ["message": input.caption]
        if !input.link.isEmpty, !input.caption.contains(input.link) { params["link"] = input.link }
        let out = try await http.post(graph, "\(page)/feed", token: token, params: params)
        guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Facebook answered without a post id") }
        return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/\(id)", requestID: nil)
    }

    private func uploadPhoto(page: String, token: String, file: URL, bytes: Data, contentType: String,
                             caption: String, altText: String, published: Bool) async throws(PublishFailure) -> [String: Any] {
        let boundary = "SocialForge-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("access_token", token)
        field("published", published ? "true" : "false")
        if !caption.isEmpty { field("message", caption) }
        if !altText.isEmpty { field("alt_text_custom", altText) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"source\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: graph.appending(path: "\(page)/photos"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await http.json(req)
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        guard let token = input.accessToken else { return nil }
        if input.isVideo {
            let out = try await http.get(graph, "\(input.boardID)/video_reels", token: token, query: ["fields": "id,description,created_time", "limit": "50"])
            guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "description", timeKey: "created_time",
                                                caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
            return PublishOutcome(providerPostID: id, url: "https://www.facebook.com/reel/\(id)", requestID: nil)
        }
        let out = try await http.get(graph, "\(input.boardID)/published_posts", token: token,
                                     query: ["fields": "id,message,created_time,permalink_url", "limit": "50"])
        guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "message", timeKey: "created_time",
                                            caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: hit["permalink_url"] as? String ?? "https://www.facebook.com/\(id)", requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "page", name: "Page feed and Reels", privacy: "PUBLIC")]
    }
}

// MARK: - Instagram

/// `input.boardID` is the Instagram professional account id; works with both Facebook-linked Graph API
/// (`graph.facebook.com/v25.0`) and direct Instagram Business Login (`graph.instagram.com/v25.0`).
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

    /// Queries the account's 24-hour publishing limit usage.
    public func publishingLimit(accountID: String, token: String) async throws(PublishFailure) -> (used: Int, total: Int) {
        let out = try await http.get(graph, "\(accountID)/content_publishing_limit", token: token, query: ["fields": "quota_usage,config"])
        let row = (out["data"] as? [[String: Any]])?.first
        let used = row?["quota_usage"] as? Int ?? 0
        let total = (row?["config"] as? [String: Any])?["quota_total"] as? Int ?? 100
        return (used, total)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No Instagram access token") }
        let ig = input.boardID
        var hostedItems: [PublicMedia] = []
        do throws(PublishFailure) {
            let container: String
            if let existing = input.existingContainerID, !existing.isEmpty {
                container = existing
            } else if !input.extraMediaFiles.isEmpty, let firstFile = input.mediaFile {
                // Carousel (2–10 items)
                guard let media else {
                    throw PublishFailure(.permanent, "Instagram carousels require configured public media storage in Connections › Media Storage.")
                }
                let files = Array(([firstFile] + input.extraMediaFiles).prefix(10))
                var childIDs: [String] = []
                for f in files {
                    let isVid = MediaFormats.isVideo(f)
                    let ct = isVid ? MediaFormats.mimeType(for: f) : input.contentType
                    let h = try await media.put(file: f, contentType: ct)
                    hostedItems.append(h)
                    var childParams: [String: String] = ["is_carousel_item": "true"]
                    if isVid {
                        childParams["media_type"] = "VIDEO"
                        childParams["video_url"] = h.url.absoluteString
                    } else {
                        childParams["image_url"] = h.url.absoluteString
                    }
                    let made = try await http.post(graph, "\(ig)/media", token: token, params: childParams)
                    guard let cid = made["id"] as? String else {
                        throw PublishFailure(.retryable, "Instagram did not create a carousel item container")
                    }
                    try await waitUntilFinished(cid, token: token)
                    childIDs.append(cid)
                }
                var carouselParams: [String: String] = [
                    "media_type": "CAROUSEL",
                    "children": childIDs.joined(separator: ","),
                ]
                if !input.caption.isEmpty { carouselParams["caption"] = input.caption }
                let made = try await http.post(graph, "\(ig)/media", token: token, params: carouselParams)
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Instagram did not create the carousel container") }
                container = id
            } else if input.isVideo {
                guard let file = input.mediaFile else { throw PublishFailure(.permanent, "The video file is missing.") }
                var params: [String: String] = ["media_type": "REELS", "upload_type": "resumable"]
                if !input.caption.isEmpty { params["caption"] = input.caption }
                let made = try await http.post(graph, "\(ig)/media", token: token, params: params)
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Instagram did not create the Reel container") }
                let uploadURL = (made["uri"] as? String).flatMap(URL.init(string:)) ?? rupload.appending(path: "ig-api-upload/\(Meta.graphVersion)/\(id)")
                _ = try await http.rupload(uploadURL, token: token, file: file)
                container = id
            } else {
                guard let file = input.mediaFile else { throw PublishFailure(.permanent, "Instagram posts need a photo or a video.") }
                guard let media else {
                    throw PublishFailure(.permanent, "Instagram fetches photos from a public address. Set up public media storage in Connections › Media Storage, or post a video (Reel), which uploads from this Mac.")
                }
                let h = try await media.put(file: file, contentType: input.contentType)
                hostedItems.append(h)
                var params: [String: String] = ["image_url": h.url.absoluteString]
                if !input.caption.isEmpty { params["caption"] = input.caption }
                if !input.altText.isEmpty { params["alt_text"] = input.altText }
                let made = try await http.post(graph, "\(ig)/media", token: token, params: params)
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Instagram did not create the photo container") }
                container = id
            }

            try await waitUntilFinished(container, token: token)
            let out = try await http.post(graph, "\(ig)/media_publish", token: token, params: ["creation_id": container])
            guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Instagram answered without a media id") }
            let link = (try? await http.get(graph, id, token: token, query: ["fields": "permalink"]))?["permalink"] as? String
            if let media {
                for h in hostedItems { await media.delete(key: h.key) }
            }
            return PublishOutcome(providerPostID: id, url: link, requestID: nil, containerID: container)
        } catch {
            // Always clean up temporary hosted objects on deterministic failures (including POST /{ig}/media failures).
            if error.kind != .uncertain, let media {
                for h in hostedItems { await media.delete(key: h.key) }
            }
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
        let out = try await http.get(graph, "\(input.boardID)/media", token: token, query: ["fields": "id,caption,permalink,timestamp", "limit": "50"])
        guard let hit = MetaReconcile.match(out["data"] as? [[String: Any]] ?? [], textKey: "caption", timeKey: "timestamp",
                                            caption: input.caption, since: since), let id = hit["id"] as? String else { return nil }
        return PublishOutcome(providerPostID: id, url: hit["permalink"] as? String, requestID: nil)
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "feed", name: "Feed, Carousels, and Reels", privacy: "PUBLIC")]
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
        var hostedItems: [PublicMedia] = []
        do throws(PublishFailure) {
            let container: String
            if let existing = input.existingContainerID, !existing.isEmpty {
                container = existing
            } else if !input.extraMediaFiles.isEmpty, let firstFile = input.mediaFile {
                guard let media else {
                    throw PublishFailure(.permanent, "Threads carousels require configured public media storage in Connections › Media Storage.")
                }
                let files = Array(([firstFile] + input.extraMediaFiles).prefix(20))
                var childIDs: [String] = []
                for f in files {
                    let isVid = MediaFormats.isVideo(f)
                    let ct = MediaFormats.mimeType(for: f)
                    let h = try await media.put(file: f, contentType: ct)
                    hostedItems.append(h)
                    var cp: [String: String] = ["is_carousel_item": "true", "media_type": isVid ? "VIDEO" : "IMAGE"]
                    cp[isVid ? "video_url" : "image_url"] = h.url.absoluteString
                    let made = try await http.post(api, "\(user)/threads", token: token, params: cp)
                    guard let cid = made["id"] as? String else {
                        throw PublishFailure(.retryable, "Threads did not create a carousel item container")
                    }
                    try await waitUntilFinished(cid, token: token)
                    childIDs.append(cid)
                }
                var params: [String: String] = ["media_type": "CAROUSEL", "children": childIDs.joined(separator: ",")]
                if !input.caption.isEmpty { params["text"] = input.caption }
                let made = try await http.post(api, "\(user)/threads", token: token, params: params)
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Threads did not create the carousel container") }
                container = id
            } else if let file = input.mediaFile {
                guard let media else {
                    throw PublishFailure(.permanent, "Threads fetches photos and videos from a public address. Set up public media storage in Connections › Media Storage, or post text only.")
                }
                let ct = input.contentType.isEmpty ? MediaFormats.mimeType(for: file) : input.contentType
                let h = try await media.put(file: file, contentType: ct)
                hostedItems.append(h)
                var params: [String: String] = ["media_type": input.isVideo ? "VIDEO" : "IMAGE"]
                params[input.isVideo ? "video_url" : "image_url"] = h.url.absoluteString
                if !input.caption.isEmpty { params["text"] = input.caption }
                if !input.altText.isEmpty { params["alt_text"] = input.altText }
                let made = try await http.post(api, "\(user)/threads", token: token, params: params)
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Threads did not create the post container") }
                container = id
            } else {
                guard !input.caption.isEmpty else { throw PublishFailure(.permanent, "The post has no text and no media.") }
                let made = try await http.post(api, "\(user)/threads", token: token, params: ["media_type": "TEXT", "text": input.caption])
                guard let id = made["id"] as? String else { throw PublishFailure(.retryable, "Threads did not create the post container") }
                container = id
            }

            if !hostedItems.isEmpty { try await waitUntilFinished(container, token: token) }
            let out = try await http.post(api, "\(user)/threads_publish", token: token, params: ["creation_id": container])
            guard let id = out["id"] as? String else { throw PublishFailure(.uncertain, "Threads answered without a post id") }
            let link = (try? await http.get(api, id, token: token, query: ["fields": "permalink"]))?["permalink"] as? String
            if let media {
                for h in hostedItems { await media.delete(key: h.key) }
            }
            return PublishOutcome(providerPostID: id, url: link, requestID: nil, containerID: container)
        } catch {
            if error.kind != .uncertain, let media {
                for h in hostedItems { await media.delete(key: h.key) }
            }
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
        let out = try await http.get(api, "\(user)/threads", token: token, query: ["fields": "id,text,permalink,timestamp", "limit": "50"])
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
        case noCode, denied(String), badState, badRedirectURI
        public var description: String {
            switch self {
            case .noCode: "That address has no sign-in code. Copy the full redirect URL from your browser after approving access."
            case .denied(let why): "Access was not granted: \(why)"
            case .badState: "The sign-in state is missing or does not match this session. Start the sign-in flow again."
            case .badRedirectURI: "The pasted address does not match the expected redirect URL for this sign-in session."
            }
        }
    }

    /// Validates a complete OAuth callback URL, requiring a matching `state` parameter
    /// (and optionally matching `expectedRedirectURI` host & path). Rejects bare authorization codes
    /// so session CSRF protection cannot be bypassed.
    public static func code(from pasted: String, state: String, expectedRedirectURI: String? = nil) throws(ParseError) -> String {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty, let comps = URLComponents(string: text), let scheme = comps.scheme, !scheme.isEmpty else {
            throw .badState
        }
        if let expected = expectedRedirectURI, let exp = URLComponents(string: expected) {
            let hostMatches = (comps.host?.lowercased() ?? "") == (exp.host?.lowercased() ?? "")
            let pathMatches = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == exp.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !hostMatches || !pathMatches { throw .badRedirectURI }
        }
        var items = comps.queryItems ?? []
        if let fragment = comps.fragment, !fragment.isEmpty {
            let cleanFrag = fragment.hasPrefix("_") ? "" : fragment
            if !cleanFrag.isEmpty, let f = URLComponents(string: "?" + cleanFrag)?.queryItems { items += f }
        }
        let value = { (n: String) in items.first { $0.name == n }?.value }
        if let err = value("error_description") ?? value("error_reason") ?? value("error") { throw .denied(err) }
        guard let rawCode = value("code"), !rawCode.isEmpty else { throw .noCode }
        guard let returnedState = value("state"), returnedState == state else { throw .badState }
        return rawCode.hasSuffix("#_") ? String(rawCode.dropLast(2)) : rawCode
    }
}

public struct MetaAuth: Sendable {
    public let graph: URL
    public let threads: URL
    public let instagramAuthBase: URL
    public let instagramGraph: URL
    let http: MetaHTTP

    public init(graph: URL = URL(string: "https://graph.facebook.com/\(Meta.graphVersion)")!,
                threads: URL = URL(string: "https://graph.threads.net")!,
                instagramAuthBase: URL = URL(string: "https://api.instagram.com")!,
                instagramGraph: URL = URL(string: "https://graph.instagram.com")!,
                session: URLSession = .shared) {
        self.graph = graph; self.threads = threads
        self.instagramAuthBase = instagramAuthBase; self.instagramGraph = instagramGraph
        http = MetaHTTP(service: "Meta", session: session)
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

    /// Direct Instagram Business Login (does not require a linked Facebook Page).
    public static func instagramLoginAuthorizeURL(appID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://www.instagram.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: appID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Meta.instagramLoginScopes.joined(separator: ",")),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    public static func threadsAuthorizeURL(appID: String, redirectURI: String, state: String) -> URL {
        var c = URLComponents(string: "https://threads.net/oauth/authorize")!
        c.queryItems = [.init(name: "client_id", value: appID), .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "scope", value: Meta.threadsScopes.joined(separator: ",")),
                        .init(name: "response_type", value: "code"), .init(name: "state", value: state)]
        return c.url!
    }

    /// Code → short-lived user token → long-lived (~60 days) user token via POST bodies (never secrets in URL query).
    public func facebookToken(code: String, redirectURI: String, appID: String, secret: String) async throws(PublishFailure) -> MetaToken {
        let short = try await http.post(graph, "oauth/access_token", token: nil, params: [
            "client_id": appID, "client_secret": secret, "redirect_uri": redirectURI, "code": code,
        ])
        guard let s = short["access_token"] as? String else { throw PublishFailure(.permanent, "Facebook did not return a token") }
        let long = try await http.post(graph, "oauth/access_token", token: nil, params: [
            "grant_type": "fb_exchange_token", "client_id": appID, "client_secret": secret, "fb_exchange_token": s,
        ])
        guard let longToken = long["access_token"] as? String else {
            return MetaToken(token: s, expiresIn: short["expires_in"] as? Int ?? 3600, userID: nil)
        }
        return MetaToken(token: longToken, expiresIn: long["expires_in"] as? Int, userID: nil)
    }

    /// Direct Instagram Business Login token exchange: short-lived → long-lived (60 days).
    public func instagramLoginToken(code: String, redirectURI: String, appID: String, secret: String) async throws(PublishFailure) -> MetaToken {
        let short = try await http.post(instagramAuthBase, "oauth/access_token", token: nil, params: [
            "client_id": appID, "client_secret": secret, "grant_type": "authorization_code",
            "redirect_uri": redirectURI, "code": code,
        ])
        guard let s = short["access_token"] as? String else { throw PublishFailure(.permanent, "Instagram did not return a token") }
        let userID = (short["user_id"] as? String) ?? (short["user_id"] as? Int).map(String.init)
        let long = try await http.post(instagramGraph, "access_token", token: s, params: [
            "grant_type": "ig_exchange_token", "client_secret": secret,
        ])
        if let longToken = long["access_token"] as? String {
            return MetaToken(token: longToken, expiresIn: long["expires_in"] as? Int, userID: userID)
        }
        return MetaToken(token: s, expiresIn: short["expires_in"] as? Int ?? 3600, userID: userID)
    }

    /// Refreshes a long-lived Instagram Business Login token for another 60 days.
    public func refreshInstagramLoginToken(_ token: String) async throws(PublishFailure) -> MetaToken {
        let out = try await http.get(instagramGraph, "refresh_access_token", token: token, query: ["grant_type": "ig_refresh_token"])
        guard let t = out["access_token"] as? String else { throw PublishFailure(.auth, "Instagram did not refresh the token") }
        return MetaToken(token: t, expiresIn: out["expires_in"] as? Int, userID: nil)
    }

    public func instagramProfile(_ token: String) async throws(PublishFailure) -> (id: String, username: String, accountType: String?) {
        let out = try await http.get(instagramGraph.appending(path: Meta.graphVersion), "me", token: token,
                                     query: ["fields": "user_id,id,username,account_type"])
        guard let id = (out["user_id"] as? String) ?? (out["id"] as? String), !id.isEmpty else {
            throw PublishFailure(.permanent, "Instagram did not return an account identifier.")
        }
        return (id, out["username"] as? String ?? "instagram", out["account_type"] as? String)
    }

    public func grantedPermissions(_ userToken: String) async throws(PublishFailure) -> [String] {
        let out = try await http.get(graph, "me/permissions", token: userToken)
        return (out["data"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "granted" }.compactMap { $0["permission"] as? String }
    }

    /// Paginated discovery of Pages the user manages (with linked Instagram professional accounts).
    public func pages(_ userToken: String) async throws(PublishFailure) -> [MetaPage] {
        var result: [MetaPage] = []
        var nextURL: URL?
        var pageCount = 0
        repeat {
            let out: [String: Any]
            if let nextURL {
                out = try await http.getAbsolute(nextURL, token: userToken)
            } else {
                out = try await http.get(graph, "me/accounts", token: userToken,
                                         query: ["fields": "id,name,access_token,instagram_business_account{id,username}", "limit": "100"])
            }
            for p in (out["data"] as? [[String: Any]] ?? []) {
                guard let id = p["id"] as? String, let token = p["access_token"] as? String else { continue }
                let ig = p["instagram_business_account"] as? [String: Any]
                result.append(MetaPage(id: id, name: p["name"] as? String ?? "Page", token: token,
                                       instagramID: ig?["id"] as? String, instagramUsername: ig?["username"] as? String))
            }
            let nextStr = (out["paging"] as? [String: Any])?["next"] as? String
            nextURL = nextStr.flatMap(URL.init(string:))
            pageCount += 1
        } while nextURL != nil && pageCount < 20
        return result
    }

    /// Code → short-lived Threads token → long-lived (60 days) token using POST / Bearer auth.
    public func threadsToken(code: String, redirectURI: String, appID: String, secret: String) async throws(PublishFailure) -> MetaToken {
        let short = try await http.post(threads, "oauth/access_token", token: nil, params: [
            "client_id": appID, "client_secret": secret, "grant_type": "authorization_code",
            "redirect_uri": redirectURI, "code": code,
        ])
        guard let s = short["access_token"] as? String else { throw PublishFailure(.permanent, "Threads did not return a token") }
        let userID = (short["user_id"] as? String) ?? (short["user_id"] as? Int).map(String.init)
        let long = try await http.post(threads, "access_token", token: s, params: [
            "grant_type": "th_exchange_token", "client_secret": secret,
        ])
        if let longToken = long["access_token"] as? String {
            return MetaToken(token: longToken, expiresIn: long["expires_in"] as? Int, userID: userID)
        }
        return MetaToken(token: s, expiresIn: short["expires_in"] as? Int ?? 3600, userID: userID)
    }

    /// A long-lived Threads token refreshed for another 60 days (uses Bearer header, not URL query token).
    public func refreshThreadsToken(_ token: String) async throws(PublishFailure) -> MetaToken {
        let out = try await http.get(threads, "refresh_access_token", token: token, query: ["grant_type": "th_refresh_token"])
        guard let t = out["access_token"] as? String else { throw PublishFailure(.auth, "Threads did not refresh the token") }
        return MetaToken(token: t, expiresIn: out["expires_in"] as? Int, userID: nil)
    }

    public func threadsProfile(_ token: String) async throws(PublishFailure) -> (id: String, username: String) {
        let out = try await http.get(threads.appending(path: Meta.threadsVersion), "me", token: token, query: ["fields": "id,username"])
        guard let id = out["id"] as? String, !id.isEmpty else {
            throw PublishFailure(.permanent, "Threads did not return a user identifier.")
        }
        return (id, out["username"] as? String ?? "threads")
    }
}

import Foundation

// Official API publishing & OAuth adapters for LinkedIn, X, TikTok, and YouTube.
// LIVE STATUS: UNVERIFIED (implemented against official 2025/2026 API documentation
// with deterministic unit/HTTP-stub tests; live verification requires user developer apps).

// MARK: - LinkedIn (Posts API, Images API, Videos API)

public struct LinkedInTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let scopes: [String]
}

public struct LinkedInIdentity: Sendable, Equatable {
    public let memberURN: String
    public let name: String
    public let organizations: [API.Board]
}

public struct LinkedInAuth: Sendable {
    public static let memberScopes = ["openid", "profile", "w_member_social"]
    public static let organizationScopes = ["openid", "profile", "w_member_social", "w_organization_social", "rw_organization_admin"]
    public static let apiVersion = "202604"

    public let authBase: URL
    public let apiBase: URL
    let session: URLSession

    public init(authBase: URL = URL(string: "https://www.linkedin.com")!,
                apiBase: URL = URL(string: "https://api.linkedin.com")!,
                session: URLSession = .shared) {
        self.authBase = authBase; self.apiBase = apiBase; self.session = session
    }

    public static func authorizeURL(clientID: String, redirectURI: String, state: String, includeOrganizations: Bool = false) -> URL {
        var c = URLComponents(string: "https://www.linkedin.com/oauth/v2/authorization")!
        let scopes = includeOrganizations ? organizationScopes : memberScopes
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
            .init(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return c.url!
    }

    public func exchange(code: String, redirectURI: String, clientID: String, clientSecret: String) async throws(PublishFailure) -> LinkedInTokens {
        try await tokenCall([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "client_secret": clientSecret,
        ])
    }

    public func refresh(_ refreshToken: String, clientID: String, clientSecret: String) async throws(PublishFailure) -> LinkedInTokens {
        try await tokenCall([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
        ])
    }

    private func tokenCall(_ params: [String: String]) async throws(PublishFailure) -> LinkedInTokens {
        var req = URLRequest(url: authBase.appending(path: "oauth/v2/accessToken"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = MetaHTTP.form(params)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, "Could not reach LinkedIn: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw PublishFailure(status == 400 || status == 401 ? .auth : PublishFailure.kind(forStatus: status),
                                 "LinkedIn token request failed (\(status))" + (msg.map { ": \($0)" } ?? ""), httpStatus: status)
        }
        let scopes = ((obj["scope"] as? String) ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        return LinkedInTokens(accessToken: access, refreshToken: obj["refresh_token"] as? String,
                              expiresIn: obj["expires_in"] as? Int, scopes: scopes)
    }

    public func discoverIdentity(accessToken: String) async throws(PublishFailure) -> LinkedInIdentity {
        var req = URLRequest(url: apiBase.appending(path: "v2/userinfo"))
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, "Could not reach LinkedIn: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String, !sub.isEmpty else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "LinkedIn profile lookup failed (\(status))", httpStatus: status)
        }
        let memberURN = sub.hasPrefix("urn:li:") ? sub : "urn:li:person:\(sub)"
        let name = (obj["name"] as? String) ?? [obj["given_name"] as? String, obj["family_name"] as? String].compactMap { $0 }.joined(separator: " ")
        let orgs = (try? await organizations(accessToken: accessToken)) ?? []
        return LinkedInIdentity(memberURN: memberURN, name: name.isEmpty ? "LinkedIn Member" : name, organizations: orgs)
    }

    public func organizations(accessToken: String) async throws(PublishFailure) -> [API.Board] {
        var comps = URLComponents(url: apiBase.appending(path: "rest/organizationAcls"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "q", value: "roleAssignee"),
            .init(name: "role", value: "ADMINISTRATOR"),
            .init(name: "state", value: "APPROVED"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "Linkedin-Version")
        req.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let elements = (obj["elements"] as? [[String: Any]]) ?? []
        return elements.compactMap { el in
            guard let urn = el["organization"] as? String else { return nil }
            let orgName = (el["organization~"] as? [String: Any])?["localizedName"] as? String ?? urn
            return API.Board(id: urn, name: orgName, privacy: "PUBLIC")
        }
    }
}

public struct LinkedInTarget: PublishTarget {
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://api.linkedin.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    private func restRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String, body: [String: Any]? = nil) async throws(PublishFailure) -> (Data, HTTPURLResponse) {
        guard var comps = URLComponents(url: apiBase.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw PublishFailure(.permanent, "Invalid LinkedIn URL.")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw PublishFailure(.permanent, "Invalid LinkedIn URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(LinkedInAuth.apiVersion, forHTTPHeaderField: "Linkedin-Version")
        req.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            let code = (error as? URLError)?.code
            if method == "POST" && (code == .timedOut || code == .networkConnectionLost) {
                throw PublishFailure(.uncertain, "LinkedIn did not confirm the post before the connection ended.")
            }
            throw PublishFailure(.retryable, "Could not reach LinkedIn: \(error.localizedDescription)")
        }
        guard let http = resp as? HTTPURLResponse else { throw PublishFailure(.retryable, "No HTTP response from LinkedIn") }
        let reqID = http.value(forHTTPHeaderField: "x-li-uuid")
        let retryAfter = PublishFailure.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            if method == "POST" && (http.statusCode == 502 || http.statusCode == 504) {
                throw PublishFailure(.uncertain, "LinkedIn gateway timeout (\(http.statusCode))", httpStatus: http.statusCode, requestID: reqID)
            }
            throw PublishFailure(PublishFailure.kind(forStatus: http.statusCode),
                                 "LinkedIn answered \(http.statusCode)" + (msg.map { ": \($0)" } ?? ""),
                                 httpStatus: http.statusCode, requestID: reqID, retryAfter: retryAfter)
        }
        return (data, http)
    }

    private func uploadImage(ownerURN: String, token: String, bytes: Data, contentType: String) async throws(PublishFailure) -> String {
        let (initData, _) = try await restRequest("POST", "rest/images", query: [.init(name: "action", value: "initializeUpload")], token: token, body: [
            "initializeUploadRequest": ["owner": ownerURN],
        ])
        let val = ((try? JSONSerialization.jsonObject(with: initData) as? [String: Any])?["value"] as? [String: Any]) ?? [:]
        guard let uploadStr = val["uploadUrl"] as? String, let uploadURL = URL(string: uploadStr),
              let imageURN = val["image"] as? String else {
            throw PublishFailure(.retryable, "LinkedIn did not return an image upload URL.")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.timeoutInterval = 120
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.httpBody = bytes
        do {
            let (_, resp) = try await session.data(for: put)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw PublishFailure(PublishFailure.kind(forStatus: code), "LinkedIn image upload returned HTTP \(code)", httpStatus: code)
            }
        } catch let f as PublishFailure { throw f }
        catch { throw PublishFailure(.retryable, "LinkedIn image upload failed: \(error.localizedDescription)") }
        return imageURN
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No LinkedIn access token") }
        let author = input.boardID.hasPrefix("urn:li:") ? input.boardID : "urn:li:person:\(input.boardID)"
        guard !input.caption.isEmpty else { throw PublishFailure(.permanent, "LinkedIn posts require commentary text.") }

        var payload: [String: Any] = [
            "author": author,
            "commentary": input.caption,
            "visibility": input.metadata["visibility"] ?? "PUBLIC",
            "distribution": [
                "feedDistribution": "MAIN_FEED",
                "targetEntities": [],
                "thirdPartyDistributionChannels": [],
            ],
            "lifecycleState": "PUBLISHED",
            "isReshareDisabledByAuthor": false,
        ]

        if let file = input.mediaFile, !input.isVideo {
            let bytes: Data
            if let img = input.image { bytes = img }
            else {
                do { bytes = try Data(contentsOf: file) } catch {
                    throw PublishFailure(.permanent, "Could not read LinkedIn image: \(error.localizedDescription)")
                }
            }
            let imageURN = try await uploadImage(ownerURN: author, token: token, bytes: bytes, contentType: input.contentType)
            var media: [String: Any] = ["id": imageURN]
            if !input.altText.isEmpty { media["altText"] = input.altText }
            payload["content"] = ["media": media]
        } else if !input.link.isEmpty {
            payload["content"] = ["article": [
                "source": input.link,
                "title": input.title.isEmpty ? input.link : input.title,
            ]]
        }

        let (data, http) = try await restRequest("POST", "rest/posts", token: token, body: payload)
        let postURN = http.value(forHTTPHeaderField: "x-restli-id")
            ?? ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String)
        guard let id = postURN, !id.isEmpty else {
            throw PublishFailure(.uncertain, "LinkedIn answered without a post URN.")
        }
        return PublishOutcome(providerPostID: id, url: "https://www.linkedin.com/feed/update/\(id)/",
                              requestID: http.value(forHTTPHeaderField: "x-li-uuid"))
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? {
        // LinkedIn does not provide an idempotency key on Posts; surface Outcome Unknown rather than guessing.
        return nil
    }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        guard let token = accessToken, !token.isEmpty else { return [] }
        let orgs = (try? await LinkedInAuth(apiBase: apiBase, session: session).organizations(accessToken: token)) ?? []
        return [API.Board(id: "member", name: "Personal Profile", privacy: "PUBLIC")] + orgs
    }
}

// MARK: - X (Twitter API v2 + OAuth 2.0 PKCE + v2 Chunked Media Upload)

public struct XTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let scopes: [String]
}

public struct XAuth: Sendable {
    public static let scopes = ["tweet.read", "tweet.write", "users.read", "media.write", "offline.access"]
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://api.x.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    public static func authorizeURL(clientID: String, redirectURI: String, state: String, pkce: PKCEPair) -> URL {
        var c = URLComponents(string: "https://x.com/i/oauth2/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
        ]
        return c.url!
    }

    public func exchange(code: String, redirectURI: String, clientID: String, clientSecret: String?, codeVerifier: String) async throws(PublishFailure) -> XTokens {
        try await tokenCall([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ], clientID: clientID, clientSecret: clientSecret)
    }

    public func refresh(_ refreshToken: String, clientID: String, clientSecret: String?) async throws(PublishFailure) -> XTokens {
        try await tokenCall([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ], clientID: clientID, clientSecret: clientSecret)
    }

    private func tokenCall(_ params: [String: String], clientID: String, clientSecret: String?) async throws(PublishFailure) -> XTokens {
        var req = URLRequest(url: apiBase.appending(path: "2/oauth2/token"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let secret = clientSecret, !secret.isEmpty {
            req.setValue("Basic " + Data("\(clientID):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        req.httpBody = MetaHTTP.form(params)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, "Could not reach X: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw PublishFailure(status == 400 || status == 401 ? .auth : PublishFailure.kind(forStatus: status),
                                 "X token request failed (\(status))" + (msg.map { ": \($0)" } ?? ""), httpStatus: status)
        }
        let scopes = ((obj["scope"] as? String) ?? "").split(separator: " ").map(String.init)
        return XTokens(accessToken: access, refreshToken: obj["refresh_token"] as? String,
                       expiresIn: obj["expires_in"] as? Int, scopes: scopes)
    }

    public func currentUser(accessToken: String) async throws(PublishFailure) -> (id: String, name: String, username: String) {
        var req = URLRequest(url: apiBase.appending(path: "2/users/me"))
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let d = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any],
              let id = d["id"] as? String else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "X profile lookup failed (\(status))", httpStatus: status)
        }
        let username = d["username"] as? String ?? "x"
        return (id, d["name"] as? String ?? username, username)
    }
}

public struct XTarget: PublishTarget {
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://api.x.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    private func rateLimitRetryAfter(_ http: HTTPURLResponse?) -> TimeInterval? {
        if let ra = PublishFailure.parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After")) { return ra }
        if let resetStr = http?.value(forHTTPHeaderField: "x-rate-limit-reset"), let ts = TimeInterval(resetStr) {
            let delta = ts - Date.now.timeIntervalSince1970
            return delta > 0 ? min(delta, 86_400) : nil
        }
        return nil
    }

    private func uploadMedia(token: String, bytes: Data, contentType: String, isVideo: Bool) async throws(PublishFailure) -> String {
        let category = isVideo ? "tweet_video" : "tweet_image"
        let uploadURL = apiBase.appending(path: "2/media/upload")
        // INIT
        var initReq = URLRequest(url: uploadURL)
        initReq.httpMethod = "POST"
        initReq.timeoutInterval = 30
        initReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = MetaHTTP.form([
            "command": "INIT",
            "total_bytes": String(bytes.count),
            "media_type": contentType,
            "media_category": category,
        ])
        let (initData, initResp) = try await perform(initReq, allowUncertain: false)
        let initObj = (try? JSONSerialization.jsonObject(with: initData) as? [String: Any]) ?? [:]
        let mediaID = ((initObj["data"] as? [String: Any])?["id"] as? String) ?? (initObj["media_id_string"] as? String)
        guard let mediaID, !mediaID.isEmpty else {
            throw PublishFailure(.retryable, "X did not return a media_id for upload (HTTP \(initResp.statusCode)).")
        }

        // APPEND (<= 4 MB chunks)
        let chunkSize = 4 * 1024 * 1024
        var offset = 0
        var segment = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunkSize)
            let slice = bytes[offset..<end]
            let boundary = "SocialForge-\(UUID().uuidString)"
            var body = Data()
            func field(_ k: String, _ v: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
            }
            field("command", "APPEND")
            field("media_id", mediaID)
            field("segment_index", String(segment))
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"chunk.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(slice)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var appendReq = URLRequest(url: uploadURL)
            appendReq.httpMethod = "POST"
            appendReq.timeoutInterval = 120
            appendReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            appendReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            appendReq.httpBody = body
            _ = try await perform(appendReq, allowUncertain: false)
            offset = end
            segment += 1
        }

        // FINALIZE
        var finReq = URLRequest(url: uploadURL)
        finReq.httpMethod = "POST"
        finReq.timeoutInterval = 60
        finReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        finReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        finReq.httpBody = MetaHTTP.form(["command": "FINALIZE", "media_id": mediaID])
        _ = try await perform(finReq, allowUncertain: false)
        return mediaID
    }

    private func perform(_ req: URLRequest, allowUncertain: Bool) async throws(PublishFailure) -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            let code = (error as? URLError)?.code
            if allowUncertain && (code == .timedOut || code == .networkConnectionLost) {
                throw PublishFailure(.uncertain, "X did not confirm the post before the connection ended.")
            }
            throw PublishFailure(.retryable, "Could not reach X: \(error.localizedDescription)")
        }
        guard let http = resp as? HTTPURLResponse else { throw PublishFailure(.retryable, "No HTTP response from X") }
        let retryAfter = rateLimitRetryAfter(http)
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (obj?["detail"] as? String) ?? (obj?["title"] as? String)
            if allowUncertain && (http.statusCode == 502 || http.statusCode == 504) {
                throw PublishFailure(.uncertain, "X gateway timeout (\(http.statusCode))", httpStatus: http.statusCode)
            }
            var msg = "X answered \(http.statusCode)" + (detail.map { ": \($0)" } ?? "")
            if http.statusCode == 403 {
                msg += " (Verify your X API tier permits posting/media upload and that tweet.write + media.write scopes are granted.)"
            }
            throw PublishFailure(PublishFailure.kind(forStatus: http.statusCode), msg, httpStatus: http.statusCode, retryAfter: retryAfter)
        }
        return (data, http)
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No X access token") }
        let text = input.caption
        guard !text.isEmpty else { throw PublishFailure(.permanent, "X posts require text.") }
        let weighted = XTextLength.weightedCount(text)
        guard weighted <= 280 else {
            throw PublishFailure(.permanent, "Post text is \(weighted) weighted characters; standard X posts allow 280.")
        }
        var mediaIDs: [String] = []
        if let file = input.mediaFile {
            let bytes: Data
            if let img = input.image, !input.isVideo { bytes = img }
            else {
                do { bytes = try Data(contentsOf: file) } catch {
                    throw PublishFailure(.permanent, "Could not read X media file: \(error.localizedDescription)")
                }
            }
            let mid = try await uploadMedia(token: token, bytes: bytes, contentType: input.contentType, isVideo: input.isVideo)
            mediaIDs.append(mid)
        }
        var body: [String: Any] = ["text": text]
        if !mediaIDs.isEmpty { body["media"] = ["media_ids": mediaIDs] }
        var req = URLRequest(url: apiBase.appending(path: "2/tweets"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await perform(req, allowUncertain: true)
        guard let id = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])?["id"] as? String else {
            throw PublishFailure(.uncertain, "X answered without a post id.")
        }
        return PublishOutcome(providerPostID: id, url: "https://x.com/i/web/status/\(id)", requestID: nil)
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? { nil }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [API.Board(id: "timeline", name: "Timeline", privacy: "PUBLIC")]
    }
}

// MARK: - TikTok (Content Posting API v2: Creator Info + Inbox Upload / Direct Post)

public struct TikTokTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let openID: String
    public let scopes: [String]
}

public struct TikTokCreatorInfo: Sendable, Equatable {
    public let nickname: String
    public let privacyOptions: [String]
    public let maxVideoDurationSeconds: Int
    public let commentDisabled: Bool
    public let duetDisabled: Bool
    public let stitchDisabled: Bool
}

public struct TikTokAuth: Sendable {
    public static let scopes = ["user.info.basic", "video.upload", "video.publish"]
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://open.tiktokapis.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    public static func authorizeURL(clientKey: String, redirectURI: String, state: String, pkce: PKCEPair) -> URL {
        var c = URLComponents(string: "https://www.tiktok.com/v2/auth/authorize/")!
        c.queryItems = [
            .init(name: "client_key", value: clientKey),
            .init(name: "scope", value: scopes.joined(separator: ",")),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
        ]
        return c.url!
    }

    public func exchange(code: String, redirectURI: String, clientKey: String, clientSecret: String, codeVerifier: String) async throws(PublishFailure) -> TikTokTokens {
        try await tokenCall([
            "client_key": clientKey, "client_secret": clientSecret, "code": code,
            "grant_type": "authorization_code", "redirect_uri": redirectURI, "code_verifier": codeVerifier,
        ])
    }

    public func refresh(_ refreshToken: String, clientKey: String, clientSecret: String) async throws(PublishFailure) -> TikTokTokens {
        try await tokenCall([
            "client_key": clientKey, "client_secret": clientSecret,
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ])
    }

    private func tokenCall(_ params: [String: String]) async throws(PublishFailure) -> TikTokTokens {
        var req = URLRequest(url: apiBase.appending(path: "v2/oauth/token/"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = MetaHTTP.form(params)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, "Could not reach TikTok: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw PublishFailure(status == 400 || status == 401 ? .auth : PublishFailure.kind(forStatus: status),
                                 "TikTok token request failed (\(status))" + (msg.map { ": \($0)" } ?? ""), httpStatus: status)
        }
        return TikTokTokens(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresIn: obj["expires_in"] as? Int,
            openID: obj["open_id"] as? String ?? "tiktok",
            scopes: ((obj["scope"] as? String) ?? "").split(separator: ",").map(String.init)
        )
    }

    public func queryCreatorInfo(accessToken: String) async throws(PublishFailure) -> TikTokCreatorInfo {
        var req = URLRequest(url: apiBase.appending(path: "v2/post/publish/creator_info/query/"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "TikTok creator info query failed (\(status))", httpStatus: status)
        }
        return TikTokCreatorInfo(
            nickname: d["creator_nickname"] as? String ?? "TikTok Creator",
            privacyOptions: d["privacy_level_options"] as? [String] ?? ["SELF_ONLY"],
            maxVideoDurationSeconds: d["max_video_post_duration_sec"] as? Int ?? 180,
            commentDisabled: d["comment_disabled"] as? Bool ?? false,
            duetDisabled: d["duet_disabled"] as? Bool ?? false,
            stitchDisabled: d["stitch_disabled"] as? Bool ?? false
        )
    }
}

public struct TikTokTarget: PublishTarget {
    public let apiBase: URL
    let session: URLSession
    let pollEvery: Duration
    let maxPolls: Int

    public init(apiBase: URL = URL(string: "https://open.tiktokapis.com")!, session: URLSession = .shared,
                pollEvery: Duration = .seconds(3), maxPolls: Int = 60) {
        self.apiBase = apiBase; self.session = session; self.pollEvery = pollEvery; self.maxPolls = maxPolls
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No TikTok access token") }
        guard input.isVideo, let file = input.mediaFile else {
            throw PublishFailure(.permanent, "TikTok Content Posting API upload requires a video file (or export for manual upload).")
        }
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            throw PublishFailure(.permanent, "Could not read TikTok video file: \(error.localizedDescription)")
        }

        // Mandatory creator_info query per TikTok Content Posting API guidelines.
        let creator = try await TikTokAuth(apiBase: apiBase, session: session).queryCreatorInfo(accessToken: token)
        let mode = input.metadata["tiktok_mode"] ?? "inbox" // "inbox" (draft in creator inbox) or "direct"
        let requestedPrivacy = input.metadata["privacy_level"] ?? "SELF_ONLY"
        if mode == "direct" && !creator.privacyOptions.contains(requestedPrivacy) {
            throw PublishFailure(.permanent, "Privacy level \(requestedPrivacy) is not permitted for this TikTok creator (allowed: \(creator.privacyOptions.joined(separator: ", "))).")
        }

        let initPath = mode == "direct" ? "v2/post/publish/video/init/" : "v2/post/publish/inbox/video/init/"
        var body: [String: Any] = [
            "source_info": [
                "source": "FILE_UPLOAD",
                "video_size": bytes.count,
                "chunk_size": bytes.count,
                "total_chunk_count": 1,
            ],
        ]
        if mode == "direct" {
            body["post_info"] = [
                "title": String(input.caption.prefix(2200)),
                "privacy_level": requestedPrivacy,
                "disable_duet": input.metadata["disable_duet"] == "true" || creator.duetDisabled,
                "disable_comment": input.metadata["disable_comment"] == "true" || creator.commentDisabled,
                "disable_stitch": input.metadata["disable_stitch"] == "true" || creator.stitchDisabled,
                "brand_content_toggle": input.metadata["brand_content"] == "true",
                "brand_organic_toggle": input.metadata["brand_organic"] == "true",
            ]
        }

        var initReq = URLRequest(url: apiBase.appending(path: initPath))
        initReq.httpMethod = "POST"
        initReq.timeoutInterval = 30
        initReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initReq.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let initData: Data, initResp: URLResponse
        do { (initData, initResp) = try await session.data(for: initReq) } catch {
            throw PublishFailure(.retryable, "Could not reach TikTok: \(error.localizedDescription)")
        }
        let initStatus = (initResp as? HTTPURLResponse)?.statusCode ?? 0
        let initRoot = (try? JSONSerialization.jsonObject(with: initData) as? [String: Any]) ?? [:]
        let errCode = (initRoot["error"] as? [String: Any])?["code"] as? String
        guard (200..<300).contains(initStatus), errCode == nil || errCode == "ok",
              let d = initRoot["data"] as? [String: Any],
              let publishID = d["publish_id"] as? String,
              let uploadURLStr = d["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLStr) else {
            let errMsg = (initRoot["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(initStatus)"
            let kind: PublishFailure.Kind = errCode == "unaudited_client_can_only_post_to_private_accounts" ? .permission : PublishFailure.kind(forStatus: initStatus)
            throw PublishFailure(kind, "TikTok upload init failed: \(errMsg)", httpStatus: initStatus)
        }

        // Upload binary chunk via PUT with Content-Range
        var putReq = URLRequest(url: uploadURL)
        putReq.httpMethod = "PUT"
        putReq.timeoutInterval = 600
        putReq.setValue(input.contentType, forHTTPHeaderField: "Content-Type")
        putReq.setValue("bytes 0-\(max(0, bytes.count - 1))/\(bytes.count)", forHTTPHeaderField: "Content-Range")
        putReq.httpBody = bytes
        do {
            let (_, putResp) = try await session.data(for: putReq)
            let code = (putResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw PublishFailure(PublishFailure.kind(forStatus: code), "TikTok video upload returned HTTP \(code)", httpStatus: code)
            }
        } catch let f as PublishFailure { throw f }
        catch { throw PublishFailure(.retryable, "TikTok video upload failed: \(error.localizedDescription)") }

        // Poll /v2/post/publish/status/fetch/
        for _ in 0..<maxPolls {
            var pollReq = URLRequest(url: apiBase.appending(path: "v2/post/publish/status/fetch/"))
            pollReq.httpMethod = "POST"
            pollReq.timeoutInterval = 30
            pollReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            pollReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            pollReq.httpBody = try? JSONSerialization.data(withJSONObject: ["publish_id": publishID])
            if let (pd, _) = try? await session.data(for: pollReq),
               let obj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
               let statusData = obj["data"] as? [String: Any],
               let state = statusData["status"] as? String {
                switch state {
                case "PUBLISH_COMPLETE", "SEND_TO_USER_INBOX":
                    return PublishOutcome(providerPostID: publishID, url: nil, requestID: nil, containerID: publishID)
                case "FAILED":
                    let reason = statusData["fail_reason"] as? String ?? "TikTok rejected the video."
                    throw PublishFailure(.permanent, "TikTok publishing failed: \(reason)")
                default:
                    try? await Task.sleep(for: pollEvery)
                }
            } else {
                try? await Task.sleep(for: pollEvery)
            }
        }
        throw PublishFailure(.uncertain, "TikTok is still processing upload \(publishID). Check TikTok before retrying.")
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? { nil }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        [
            API.Board(id: "inbox", name: "Creator Inbox Draft (Recommended for unaudited apps)", privacy: "SELF_ONLY"),
            API.Board(id: "direct", name: "Direct Post (Requires audited TikTok app)", privacy: "PUBLIC"),
        ]
    }
}

// MARK: - YouTube (Google OAuth 2.0 PKCE + YouTube Data API v3 Resumable Upload)

public struct YouTubeTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let scopes: [String]
}

public struct YouTubeAuth: Sendable {
    public static let scopes = [
        "https://www.googleapis.com/auth/youtube.upload",
        "https://www.googleapis.com/auth/youtube.readonly",
    ]
    public let tokenURL: URL
    public let apiBase: URL
    let session: URLSession

    public init(tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
                apiBase: URL = URL(string: "https://www.googleapis.com")!,
                session: URLSession = .shared) {
        self.tokenURL = tokenURL; self.apiBase = apiBase; self.session = session
    }

    public static func authorizeURL(clientID: String, redirectURI: String, state: String, pkce: PKCEPair) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
        ]
        return c.url!
    }

    public func exchange(code: String, redirectURI: String, clientID: String, clientSecret: String?, codeVerifier: String) async throws(PublishFailure) -> YouTubeTokens {
        var params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
        ]
        if let secret = clientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return try await tokenCall(params)
    }

    public func refresh(_ refreshToken: String, clientID: String, clientSecret: String?) async throws(PublishFailure) -> YouTubeTokens {
        var params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let secret = clientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return try await tokenCall(params)
    }

    private func tokenCall(_ params: [String: String]) async throws(PublishFailure) -> YouTubeTokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = MetaHTTP.form(params)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, "Could not reach Google OAuth: \(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw PublishFailure(status == 400 || status == 401 ? .auth : PublishFailure.kind(forStatus: status),
                                 "Google token request failed (\(status))" + (msg.map { ": \($0)" } ?? ""), httpStatus: status)
        }
        let scopes = ((obj["scope"] as? String) ?? "").split(separator: " ").map(String.init)
        return YouTubeTokens(accessToken: access, refreshToken: obj["refresh_token"] as? String,
                             expiresIn: obj["expires_in"] as? Int, scopes: scopes)
    }

    public func channels(accessToken: String) async throws(PublishFailure) -> [API.Board] {
        var comps = URLComponents(url: apiBase.appending(path: "youtube/v3/channels"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "part", value: "snippet"), .init(name: "mine", value: "true")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "YouTube channel discovery failed (\(status))", httpStatus: status)
        }
        let items = (obj["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let title = (item["snippet"] as? [String: Any])?["title"] as? String ?? "YouTube Channel"
            return API.Board(id: id, name: title, privacy: "PUBLIC")
        }
    }
}

public struct YouTubeTarget: PublishTarget {
    public let apiBase: URL
    let session: URLSession

    public init(apiBase: URL = URL(string: "https://www.googleapis.com")!, session: URLSession = .shared) {
        self.apiBase = apiBase; self.session = session
    }

    public func publish(_ input: PublishInput) async throws(PublishFailure) -> PublishOutcome {
        guard let token = input.accessToken, !token.isEmpty else { throw PublishFailure(.auth, "No YouTube access token") }
        guard input.isVideo, let file = input.mediaFile else {
            throw PublishFailure(.permanent, "YouTube uploads require a video file.")
        }
        let bytes: Data
        do { bytes = try Data(contentsOf: file) } catch {
            throw PublishFailure(.permanent, "Could not read YouTube video file: \(error.localizedDescription)")
        }

        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PublishFailure(.permanent, "YouTube videos require a title.") }
        let privacy = input.metadata["visibility"] ?? "private"
        let madeForKids = input.metadata["made_for_kids"] == "true"
        var statusDict: [String: Any] = [
            "privacyStatus": privacy,
            "selfDeclaredMadeForKids": madeForKids,
        ]
        if let publishAt = input.metadata["publish_at"], !publishAt.isEmpty {
            statusDict["privacyStatus"] = "private"
            statusDict["publishAt"] = publishAt
        }
        if input.metadata["synthetic_media"] == "true" {
            statusDict["containsSyntheticMedia"] = true
        }
        let metadataPayload: [String: Any] = [
            "snippet": [
                "title": String(title.prefix(100)),
                "description": String(input.description.prefix(5000)),
                "categoryId": input.metadata["category_id"] ?? "22",
            ],
            "status": statusDict,
        ]

        // Step 1: Initiate resumable upload session
        var comps = URLComponents(url: apiBase.appending(path: "upload/youtube/v3/videos"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "uploadType", value: "resumable"), .init(name: "part", value: "snippet,status")]
        var initReq = URLRequest(url: comps.url!)
        initReq.httpMethod = "POST"
        initReq.timeoutInterval = 30
        initReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initReq.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initReq.setValue(input.contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        initReq.setValue(String(bytes.count), forHTTPHeaderField: "X-Upload-Content-Length")
        initReq.httpBody = try? JSONSerialization.data(withJSONObject: metadataPayload)

        let initData: Data, initResp: URLResponse
        do { (initData, initResp) = try await session.data(for: initReq) } catch {
            throw PublishFailure(.retryable, "Could not reach YouTube: \(error.localizedDescription)")
        }
        let initHTTP = initResp as? HTTPURLResponse
        let initStatus = initHTTP?.statusCode ?? 0
        guard (200..<300).contains(initStatus),
              let location = initHTTP?.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else {
            let reason = parseYouTubeError(initData)
            if reason.contains("quotaExceeded") {
                throw PublishFailure(.rateLimited, "YouTube daily API quota exceeded (\(reason)).", httpStatus: initStatus, retryAfter: 3600)
            }
            throw PublishFailure(PublishFailure.kind(forStatus: initStatus), "YouTube upload init failed (\(initStatus)): \(reason)", httpStatus: initStatus)
        }

        // Step 2: Upload video bytes via PUT to resumable session URI
        var putReq = URLRequest(url: uploadURL)
        putReq.httpMethod = "PUT"
        putReq.timeoutInterval = 600
        putReq.setValue(input.contentType, forHTTPHeaderField: "Content-Type")
        putReq.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        putReq.httpBody = bytes
        let putData: Data, putResp: URLResponse
        do { (putData, putResp) = try await session.data(for: putReq) } catch {
            let code = (error as? URLError)?.code
            if code == .timedOut || code == .networkConnectionLost {
                throw PublishFailure(.uncertain, "YouTube connection ended during finalization. Check YouTube Studio before re-uploading.")
            }
            throw PublishFailure(.retryable, "YouTube upload interrupted: \(error.localizedDescription)")
        }
        let putStatus = (putResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(putStatus),
              let obj = try? JSONSerialization.jsonObject(with: putData) as? [String: Any],
              let videoID = obj["id"] as? String else {
            let reason = parseYouTubeError(putData)
            throw PublishFailure(PublishFailure.kind(forStatus: putStatus), "YouTube upload failed (\(putStatus)): \(reason)", httpStatus: putStatus)
        }
        return PublishOutcome(providerPostID: videoID, url: "https://www.youtube.com/watch?v=\(videoID)", requestID: nil, containerID: videoID)
    }

    public func processingStatus(videoID: String, accessToken: String) async throws(PublishFailure) -> String {
        var comps = URLComponents(url: apiBase.appending(path: "youtube/v3/videos"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "part", value: "status,processingDetails"), .init(name: "id", value: videoID)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PublishFailure(.retryable, error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["items"] as? [[String: Any]])?.first else {
            throw PublishFailure(PublishFailure.kind(forStatus: status), "YouTube status lookup failed (\(status))", httpStatus: status)
        }
        return ((first["processingDetails"] as? [String: Any])?["processingStatus"] as? String)
            ?? ((first["status"] as? [String: Any])?["uploadStatus"] as? String)
            ?? "unknown"
    }

    private func parseYouTubeError(_ data: Data) -> String {
        if let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any] {
            let reason = ((err["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            let msg = (err["message"] as? String) ?? ""
            return [reason, msg].filter { !$0.isEmpty }.joined(separator: " — ")
        }
        return "unknown error"
    }

    public func findExisting(_ input: PublishInput, since: Date) async throws(PublishFailure) -> PublishOutcome? { nil }

    public func boards(accessToken: String?) async throws(PublishFailure) -> [API.Board] {
        guard let token = accessToken, !token.isEmpty else { return [] }
        return (try? await YouTubeAuth(apiBase: apiBase, session: session).channels(accessToken: token)) ?? []
    }
}

import Foundation
import Testing
@testable import SocialForgeKit

/// Records what a publish put in public storage, without a network.
final class FakeMediaHost: PublicMediaHost, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var puts: [String] = []
    private(set) var deletes: [String] = []
    func put(file: URL, contentType: String) async throws(PublishFailure) -> PublicMedia {
        lock.withLock { puts.append(file.lastPathComponent) }
        return PublicMedia(url: URL(string: "https://media.example.com/sf/\(file.lastPathComponent)")!, key: "sf/\(file.lastPathComponent)")
    }
    func delete(key: String) async { lock.withLock { deletes.append(key) } }
}

private func form(_ body: Data) -> [String: String] {
    let items = URLComponents(string: "?" + (String(data: body, encoding: .utf8) ?? ""))?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

private func jdata(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

private func input(video: Bool = false, file: URL? = nil, caption: String = "Slow mornings.", account: String = "ig1") -> PublishInput {
    var i = PublishInput(idempotencyKey: "k1", accountID: "mac-x", accessToken: "TOKEN", title: "Mug", description: caption, link: "",
                         altText: "", boardID: account, image: nil, contentType: video ? "video/mp4" : "image/jpeg")
    i.mediaFile = file
    i.isVideo = video
    return i
}

private func tempFile(_ name: String, bytes: Int = 64) -> URL {
    let u = Fixture.tempDir().appending(path: name)
    try! Data(repeating: 7, count: bytes).write(to: u)
    return u
}

@Suite("Meta publishing")
struct MetaPublishingTests {
    // AWS's published example: GET /test.txt with a Range header (Signature Version 4, S3 docs).
    @Test func sigV4MatchesAWSExample() {
        let auth = SigV4.authorization(method: "GET", path: "/test.txt",
                                       headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9",
                                                 "x-amz-content-sha256": SigV4.emptyPayloadHash, "x-amz-date": "20130524T000000Z"],
                                       payloadHash: SigV4.emptyPayloadHash, region: "us-east-1",
                                       accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func s3ConfigNeedsEveryFieldAndHTTPS() {
        #expect(S3Config.make(endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "b", region: "auto", accessKeyID: "k", secret: "s",
                              publicBase: "https://pub.r2.dev") != nil)
        #expect(S3Config.make(endpoint: "http://acct.r2.cloudflarestorage.com", bucket: "b", region: "auto", accessKeyID: "k", secret: "s",
                              publicBase: "https://pub.r2.dev") == nil)
        #expect(S3Config.make(endpoint: "https://e", bucket: "", region: "auto", accessKeyID: "k", secret: "s", publicBase: "https://p") == nil)
    }

    @Test func s3UploadSignsAPathStylePut() async throws {
        let stub = HTTPStub.make { _, _ in (200, Data()) }
        // The stub serves http; the uploader only builds the request from the endpoint.
        let config = S3Config(endpoint: stub.base, bucket: "media", region: "auto", accessKeyID: "AK", secretAccessKey: "SK",
                              publicBaseURL: URL(string: "https://pub.example.com")!)
        let out = try await S3Uploader(config: config, session: stub.session).put(file: tempFile("a b.jpg"), contentType: "image/jpeg")
        let req = try #require(stub.log.all.first?.request)
        #expect(req.httpMethod == "PUT")
        #expect(req.url!.path().hasPrefix("/media/socialforge/"))
        #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AK/") == true)
        #expect(req.value(forHTTPHeaderField: "x-amz-content-sha256")?.count == 64)
        #expect(out.url.absoluteString.hasPrefix("https://pub.example.com/socialforge/") && out.key.hasSuffix(".jpg"))
        // Opaque key must never leak original filename.
        #expect(!out.key.contains("a b"))
    }

    @Test func s3RefusalIsExplained() async {
        let stub = HTTPStub.make { _, _ in (403, Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        let config = S3Config(endpoint: stub.base, bucket: "m", region: "auto", accessKeyID: "A", secretAccessKey: "S", publicBaseURL: URL(string: "https://p")!)
        do {
            _ = try await S3Uploader(config: config, session: stub.session).put(file: tempFile("x.jpg"), contentType: "image/jpeg")
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .permanent && error.message.contains("AccessDenied"))
        }
    }

    @Test func instagramReelUploadsFromTheMacAndPublishes() async throws {
        let polls = Counter()
        let stub = HTTPStub.make { req, body in
            let path = req.url!.path()
            switch (req.httpMethod ?? "GET", path) {
            case ("POST", "/ig1/media"):
                let f = form(body)
                guard f["media_type"] == "REELS", f["upload_type"] == "resumable", f["caption"] == "Slow mornings.", f["access_token"] == "TOKEN" else { return (400, Data()) }
                return (200, jdata(["id": "c1", "uri": "http://\(req.url!.host!)/ig-api-upload/v25.0/c1"]))
            case ("POST", "/ig-api-upload/v25.0/c1"):
                guard req.value(forHTTPHeaderField: "Authorization") == "OAuth TOKEN", req.value(forHTTPHeaderField: "offset") == "0",
                      req.value(forHTTPHeaderField: "file_size") == "128" else { return (400, Data()) }
                return (200, jdata(["success": true]))
            case ("GET", "/c1"):
                return (200, jdata(["status_code": polls.next() < 2 ? "IN_PROGRESS" : "FINISHED"]))
            case ("POST", "/ig1/media_publish"):
                return form(body)["creation_id"] == "c1" ? (200, jdata(["id": "m1"])) : (400, Data())
            case ("GET", "/m1"):
                return (200, jdata(["permalink": "https://www.instagram.com/reel/abc/"]))
            default: return (404, Data())
            }
        }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: nil, session: stub.session, pollEvery: .milliseconds(1))
        let out = try await target.publish(input(video: true, file: tempFile("reel.mp4", bytes: 128)))
        #expect(out.providerPostID == "m1" && out.url == "https://www.instagram.com/reel/abc/")
        #expect(polls.value == 3)
    }

    @Test func instagramPhotoNeedsPublicStorage() async {
        let stub = HTTPStub.make { _, _ in (500, Data()) }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: nil, session: stub.session)
        do {
            _ = try await target.publish(input(file: tempFile("p.jpg")))
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .permanent && error.message.contains("public media storage"))
            #expect(stub.log.all.isEmpty)
        }
    }

    @Test func instagramPhotoUsesStorageAndCleansUp() async throws {
        let host = FakeMediaHost()
        let stub = HTTPStub.make { req, body in
            switch (req.httpMethod ?? "GET", req.url!.path()) {
            case ("POST", "/ig1/media"):
                return form(body)["image_url"] == "https://media.example.com/sf/p.jpg" ? (200, jdata(["id": "c2"])) : (400, Data())
            case ("GET", "/c2"): return (200, jdata(["status_code": "FINISHED"]))
            case ("POST", "/ig1/media_publish"): return (200, jdata(["id": "m2"]))
            case ("GET", "/m2"): return (200, jdata(["permalink": "https://www.instagram.com/p/xyz/"]))
            default: return (404, Data())
            }
        }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: host, session: stub.session, pollEvery: .milliseconds(1))
        let out = try await target.publish(input(file: tempFile("p.jpg")))
        #expect(out.providerPostID == "m2")
        #expect(host.puts == ["p.jpg"] && host.deletes == ["sf/p.jpg"])
    }

    @Test func containerErrorStops() async {
        let stub = HTTPStub.make { req, _ in
            switch (req.httpMethod ?? "GET", req.url!.path()) {
            case ("POST", "/ig1/media"): return (200, jdata(["id": "c3"]))
            case ("GET", "/c3"): return (200, jdata(["status_code": "ERROR", "status": "Error: 2207026"]))
            default: return (404, Data())
            }
        }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: FakeMediaHost(), session: stub.session, pollEvery: .milliseconds(1))
        do {
            _ = try await target.publish(input(file: tempFile("p.jpg")))
            Issue.record("expected a failure")
        } catch {
            #expect(error.kind == .permanent && error.message.contains("2207026"))
        }
    }

    @Test func graphErrorsMapToActions() {
        func err(_ code: Int, _ sub: Int = 0) -> Data { jdata(["error": ["message": "m", "code": code, "error_subcode": sub, "fbtrace_id": "T"]]) }
        #expect(Meta.failure(status: 400, body: err(190), service: "Instagram").kind == .auth)
        #expect(Meta.failure(status: 403, body: err(200), service: "Facebook").kind == .permission)
        #expect(Meta.failure(status: 400, body: err(4), service: "Facebook").kind == .rateLimited)
        let igLimit = Meta.failure(status: 400, body: err(9, 2207042), service: "Instagram")
        #expect(igLimit.kind == .rateLimited && igLimit.message.contains("24-hour") && (igLimit.retryAfter ?? 0) >= 3600)
        #expect(Meta.failure(status: 400, body: err(100), service: "Instagram").kind == .permanent)
        #expect(Meta.failure(status: 400, body: err(100), service: "Instagram").requestID == "T")
        #expect(Meta.failure(status: 503, body: Data(), service: "Threads").kind == .retryable)
    }

    @Test func facebookTextPhotoAndReel() async throws {
        let stub = HTTPStub.make { req, body in
            switch (req.httpMethod ?? "GET", req.url!.path()) {
            case ("POST", "/p1/feed"):
                return form(body)["message"] == "Slow mornings." ? (200, jdata(["id": "p1_9"])) : (400, Data())
            case ("POST", "/p1/photos"):
                let text = String(decoding: body, as: UTF8.self)
                let ok = req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true
                    && text.contains("name=\"source\"; filename=\"p.jpg\"") && text.contains("Slow mornings.")
                return ok ? (200, jdata(["id": "ph1", "post_id": "p1_10"])) : (400, Data())
            case ("POST", "/p1/video_reels"):
                let f = form(body)
                if f["upload_phase"] == "start" { return (200, jdata(["video_id": "v1"])) }
                return f["upload_phase"] == "finish" && f["video_state"] == "PUBLISHED" && f["video_id"] == "v1" ? (200, jdata(["success": true])) : (400, Data())
            case ("POST", "/video-upload/v25.0/v1"): return (200, jdata(["success": true]))
            default: return (404, Data())
            }
        }
        let fb = FacebookPageTarget(graph: stub.base, rupload: stub.base, session: stub.session)
        #expect(try await fb.publish(input(account: "p1")).providerPostID == "p1_9")
        #expect(try await fb.publish(input(file: tempFile("p.jpg"), account: "p1")).providerPostID == "p1_10")
        let reel = try await fb.publish(input(video: true, file: tempFile("r.mp4"), account: "p1"))
        #expect(reel.providerPostID == "v1" && reel.url == "https://www.facebook.com/reel/v1")
    }

    @Test func threadsTextAndMediaRules() async throws {
        let stub = HTTPStub.make { req, body in
            switch (req.httpMethod ?? "GET", req.url!.path()) {
            case ("POST", "/u1/threads"):
                let f = form(body)
                return f["media_type"] == "TEXT" && f["text"] == "Slow mornings." ? (200, jdata(["id": "t1"])) : (400, Data())
            case ("POST", "/u1/threads_publish"): return (200, jdata(["id": "post1"]))
            case ("GET", "/post1"): return (200, jdata(["permalink": "https://www.threads.net/@me/post/1"]))
            default: return (404, Data())
            }
        }
        let threads = ThreadsTarget(api: stub.base, media: nil, session: stub.session)
        let out = try await threads.publish(input(account: "u1"))
        #expect(out.providerPostID == "post1" && out.url == "https://www.threads.net/@me/post/1")
        await #expect(throws: PublishFailure.self) { try await threads.publish(input(file: tempFile("p.jpg"), account: "u1")) }
    }

    @Test func reconcileFindsTheSamePostAfterATimeout() async throws {
        let stub = HTTPStub.make { _, _ in
            (200, jdata(["data": [["id": "old", "caption": "Slow mornings.", "timestamp": "2020-01-01T00:00:00+0000"],
                                 ["id": "m9", "caption": "Slow mornings.", "permalink": "https://www.instagram.com/p/9/",
                                  "timestamp": ISO8601DateFormatter().string(from: .now)]]]))
        }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: nil, session: stub.session)
        let found = try await target.findExisting(input(), since: Date.now.addingTimeInterval(-60))
        #expect(found?.providerPostID == "m9")
        #expect(try await target.findExisting(input(caption: "Different"), since: Date.now.addingTimeInterval(-60)) == nil)
    }

    @Test func redirectParsing() throws {
        let landed = "https://www.facebook.com/connect/login_success.html?code=ABC&state=s1#_=_"
        #expect(try OAuthRedirect.code(from: landed, state: "s1", expectedRedirectURI: Meta.desktopRedirect) == "ABC")
        #expect(try OAuthRedirect.code(from: "https://example.com/cb?code=XYZ&state=s2#_", state: "s2") == "XYZ")
        // Bare codes and missing state MUST be rejected (CSRF protection).
        #expect(throws: OAuthRedirect.ParseError.badState) { try OAuthRedirect.code(from: "  RAWCODE#_ ", state: "s") }
        #expect(throws: OAuthRedirect.ParseError.badState) { try OAuthRedirect.code(from: "https://example.com/cb?code=XYZ", state: "s2") }
        #expect(throws: OAuthRedirect.ParseError.badState) { try OAuthRedirect.code(from: "https://x/?code=a&state=other", state: "s1") }
        #expect(throws: OAuthRedirect.ParseError.badRedirectURI) {
            try OAuthRedirect.code(from: "https://evil.example/cb?code=a&state=s1", state: "s1", expectedRedirectURI: Meta.desktopRedirect)
        }
        #expect(throws: OAuthRedirect.ParseError.denied("Permissions error")) {
            try OAuthRedirect.code(from: "https://x/?error=access_denied&error_description=Permissions%20error&state=s1", state: "s1")
        }
        #expect(throws: OAuthRedirect.ParseError.noCode) { try OAuthRedirect.code(from: "https://x/?state=s1", state: "s1") }
    }

    @Test func authorizeURLs() {
        let fb = MetaAuth.facebookAuthorizeURL(appID: "1", redirectURI: Meta.desktopRedirect, state: "s").absoluteString
        #expect(fb.contains("dialog/oauth") && fb.contains("instagram_content_publish") && fb.contains("pages_manage_posts"))
        let business = MetaAuth.facebookAuthorizeURL(appID: "1", redirectURI: Meta.desktopRedirect, state: "s", configID: "cfg").absoluteString
        #expect(business.contains("config_id=cfg") && !business.contains("scope="))
        let th = MetaAuth.threadsAuthorizeURL(appID: "2", redirectURI: "https://e/cb", state: "s").absoluteString
        #expect(th.hasPrefix("https://threads.net/oauth/authorize") && th.contains("threads_content_publish"))
    }

    @Test func pagesAndLinkedInstagram() async throws {
        let stub = HTTPStub.make { req, _ in
            req.url!.path() == "/me/accounts"
                ? (200, jdata(["data": [["id": "p1", "name": "Oak & Ember", "access_token": "PT",
                                         "instagram_business_account": ["id": "ig1", "username": "oakandember"]],
                                        ["id": "p2", "name": "Side page", "access_token": "PT2"]]]))
                : (404, Data())
        }
        let pages = try await MetaAuth(graph: stub.base, threads: stub.base, session: stub.session).pages("UT")
        #expect(pages.count == 2)
        #expect(pages[0].instagramID == "ig1" && pages[0].instagramUsername == "oakandember" && pages[1].instagramID == nil)
    }
}

/// A thread-safe counter for stub handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

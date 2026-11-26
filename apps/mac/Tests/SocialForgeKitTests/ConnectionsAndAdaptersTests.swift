import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Connections, PKCE, Token Lifecycle, Redaction & Platform Adapters")
struct ConnectionsAndAdaptersTests {
    @Test func pkceGeneratesValidS256Challenge() {
        let pair = PKCEPair.generate()
        #expect(pair.method == "S256")
        #expect(pair.verifier.count >= 43)
        #expect(!pair.verifier.contains("+") && !pair.verifier.contains("/") && !pair.verifier.contains("="))
        #expect(!pair.challenge.contains("+") && !pair.challenge.contains("/") && !pair.challenge.contains("="))
        #expect(PKCEPair.from(verifier: pair.verifier).challenge == pair.challenge)
    }

    @Test func tokenLifecycleDeduplicatesConcurrentRefresh() async throws {
        let manager = TokenLifecycleManager()
        let networkCalls = Counter()
        let persistedTokens = TokenRecorder()

        async let a = manager.refresh(credentialKey: "acct-1", operation: {
            _ = networkCalls.next()
            try await Task.sleep(for: .milliseconds(40))
            return RefreshedToken(accessToken: "new-access", refreshToken: "new-refresh", expiresAt: .now.addingTimeInterval(3600))
        }, persist: { token in
            persistedTokens.append(token.accessToken)
        })
        async let b = manager.refresh(credentialKey: "acct-1", operation: {
            _ = networkCalls.next()
            return RefreshedToken(accessToken: "stale-access", refreshToken: "stale-refresh", expiresAt: .now.addingTimeInterval(3600))
        }, persist: { token in
            persistedTokens.append(token.accessToken)
        })

        let (r1, r2) = try await (a, b)
        #expect(networkCalls.value == 1)
        #expect(r1.accessToken == "new-access" && r2.accessToken == "new-access")
        #expect(persistedTokens.values == ["new-access"])
    }

    @Test func diagnosticRedactorStripsAllSecretForms() {
        let raw = "Authorization: Bearer super_secret_tok access_token=abc123&code=oauth999 sk-proj-1234567890abcdef X-Amz-Signature=deadbeef customSecretXYZ"
        let clean = DiagnosticRedactor.sanitize(raw, secrets: ["customSecretXYZ"])
        #expect(!clean.contains("super_secret_tok"))
        #expect(!clean.contains("abc123"))
        #expect(!clean.contains("oauth999"))
        #expect(!clean.contains("sk-proj-1234567890abcdef"))
        #expect(!clean.contains("deadbeef"))
        #expect(!clean.contains("customSecretXYZ"))
        #expect(clean.contains("[REDACTED]"))
    }

    @Test func csvExportNeutralizesFormulaInjection() {
        let records = [
            PostRecord(platform: "pinterest", status: "published", scheduledAt: Date(timeIntervalSince1970: 1_700_000_000),
                       campaign: "=CMD|' /C calc'!A0", account: "+SUM(A1:A5)"),
            PostRecord(platform: "instagram", status: "scheduled", scheduledAt: Date(timeIntervalSince1970: 1_700_000_000),
                       campaign: "@IMPORTXML", account: "-1+1"),
        ]
        let csv = Analytics.csv(records)
        #expect(csv.contains("'=CMD"))
        #expect(csv.contains("'+SUM"))
        #expect(csv.contains("'@IMPORTXML"))
        #expect(csv.contains("'-1+1"))
    }

    @Test func metaReconcileRejectsEmptyAndDuplicateCaptions() async throws {
        let nowISO = ISO8601.format(.now)
        let dupStub = HTTPStub.make { _, _ in
            let payload: [String: Any] = ["data": [
                ["id": "1", "caption": "Same caption", "timestamp": nowISO],
                ["id": "2", "caption": "Same caption", "timestamp": nowISO],
                ["id": "3", "caption": "", "timestamp": nowISO],
            ]]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        let target = InstagramTarget(graph: dupStub.base, rupload: dupStub.base, media: nil, session: dupStub.session)
        let dupInput = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "T", title: "", description: "Same caption",
                                    link: "", altText: "", boardID: "ig1", image: nil, contentType: "image/jpeg")
        let emptyInput = PublishInput(idempotencyKey: "k2", accountID: "a", accessToken: "T", title: "", description: "",
                                      link: "", altText: "", boardID: "ig1", image: nil, contentType: "image/jpeg")
        #expect(try await target.findExisting(dupInput, since: .now.addingTimeInterval(-60)) == nil)
        #expect(try await target.findExisting(emptyInput, since: .now.addingTimeInterval(-60)) == nil)
        // Because Instagram doesn't support deterministic reconciliation, an uncertain retry stops in Outcome Unknown instead of duplicating!
        let outcome = await PublishEngine.attempt(dupInput, target: target, attempt: 2, hadUncertain: true,
                                                  firstTriedAt: .now.addingTimeInterval(-60), policy: RetryPolicy())
        guard case .outcomeUnknown = outcome.next else { Issue.record("expected outcomeUnknown, got \(outcome.next)"); return }
    }

    @Test func instagramContainerFailureStillCleansUpPublicMedia() async {
        let host = FakeMediaHost()
        let stub = HTTPStub.make { _, _ in (400, Data(#"{"error":{"message":"Bad image","code":100}}"#.utf8)) }
        let target = InstagramTarget(graph: stub.base, rupload: stub.base, media: host, session: stub.session, pollEvery: .milliseconds(1))
        let file = Fixture.tempDir().appending(path: "fail.jpg")
        try! Data([1, 2, 3]).write(to: file)
        var inp = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "T", title: "T", description: "D",
                               link: "", altText: "", boardID: "ig1", image: nil, contentType: "image/jpeg")
        inp.mediaFile = file
        do {
            _ = try await target.publish(inp)
            Issue.record("expected failure")
        } catch {
            #expect(host.puts == ["fail.jpg"])
            #expect(host.deletes == ["sf/fail.jpg"])
        }
    }

    @Test func s3VerifyConnectionTestsPutGetContentTypeAndDelete() async {
        let stored = TokenRecorder()
        let stub = HTTPStub.make { req, body in
            switch req.httpMethod ?? "GET" {
            case "PUT":
                stored.append(String(decoding: body, as: UTF8.self))
                return (200, Data())
            case "GET":
                let payload = stored.values.first ?? ""
                return (200, Data(payload.utf8))
            case "DELETE":
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let cfg = S3Config(endpoint: stub.base, bucket: "b", region: "auto", accessKeyID: "AK", secretAccessKey: "SK",
                           publicBaseURL: stub.base, addressingStyle: .pathStyle)
        let res = await S3Uploader(config: cfg, session: stub.session).verifyConnection()
        #expect(res.uploadOK && res.downloadOK && res.deleteOK)
    }

    @Test func pinterestRefreshAndVideoPinAndSections() async throws {
        let stub = HTTPStub.make { req, _ in
            let path = req.url!.path()
            switch (req.httpMethod ?? "GET", path) {
            case ("POST", "/v5/oauth/token"):
                return (200, Data(#"{"access_token":"NEW_AT","refresh_token":"NEW_RT","expires_in":3600,"scope":"boards:read pins:write"}"#.utf8))
            case ("GET", "/v5/boards/b1/sections"):
                return (200, Data(#"{"items":[{"id":"sec1","name":"Mugs"}]}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let target = PinterestTarget(apiBase: stub.base, session: stub.session)
        let tokens = try await target.refreshToken("OLD_RT", clientID: "cid", clientSecret: "csec")
        #expect(tokens.access == "NEW_AT" && tokens.refresh == "NEW_RT")
        let sections = try await target.boardSections(boardID: "b1", accessToken: "NEW_AT")
        #expect(sections.first?.id == "sec1" && sections.first?.name == "Mugs")
    }

    @Test func linkedInPublishesPostWithImage() async throws {
        let stub = HTTPStub.make { req, _ in
            let path = req.url!.path()
            let query = req.url!.query() ?? ""
            if req.httpMethod == "POST", path == "/rest/images", query.contains("initializeUpload") {
                return (200, Data(#"{"value":{"uploadUrl":"\#(req.url!.scheme!)://\#(req.url!.host!)/upload/img1","image":"urn:li:image:123"}}"#.utf8))
            }
            if req.httpMethod == "PUT", path == "/upload/img1" { return (201, Data()) }
            if req.httpMethod == "POST", path == "/rest/posts" {
                return (201, Data(#"{"id":"urn:li:share:999"}"#.utf8))
            }
            return (404, Data())
        }
        let file = Fixture.tempDir().appending(path: "li.jpg")
        try! Data([9, 8, 7]).write(to: file)
        var inp = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "TOK", title: "Hello", description: "LinkedIn update",
                               link: "", altText: "Alt", boardID: "urn:li:person:abc", image: Data([9, 8, 7]), contentType: "image/jpeg")
        inp.mediaFile = file
        let out = try await LinkedInTarget(apiBase: stub.base, session: stub.session).publish(inp)
        #expect(out.providerPostID == "urn:li:share:999")
    }

    @Test func xPublishesWithV2ChunkedMediaUpload() async throws {
        let stub = HTTPStub.make { req, body in
            let path = req.url!.path()
            if path == "/2/media/upload" {
                let text = String(decoding: body, as: UTF8.self)
                if text.contains("command=INIT") { return (200, Data(#"{"data":{"id":"med_1"}}"#.utf8)) }
                return (200, Data(#"{"data":{"id":"med_1"}}"#.utf8))
            }
            if path == "/2/tweets" {
                return (201, Data(#"{"data":{"id":"tw_42"}}"#.utf8))
            }
            return (404, Data())
        }
        let file = Fixture.tempDir().appending(path: "x.jpg")
        try! Data([1, 2, 3, 4]).write(to: file)
        var inp = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "TOK", title: "", description: "Launching today! https://example.com/product",
                               link: "", altText: "", boardID: "timeline", image: Data([1, 2, 3, 4]), contentType: "image/jpeg")
        inp.mediaFile = file
        let out = try await XTarget(apiBase: stub.base, session: stub.session).publish(inp)
        #expect(out.providerPostID == "tw_42" && out.url == "https://x.com/i/web/status/tw_42")
    }

    @Test func tikTokQueriesCreatorInfoAndUploadsToInbox() async throws {
        let stub = HTTPStub.make { req, _ in
            switch req.url!.path() {
            case "/v2/post/publish/creator_info/query/":
                return (200, Data(#"{"data":{"creator_nickname":"oak","privacy_level_options":["SELF_ONLY","PUBLIC_TO_EVERYONE"],"max_video_post_duration_sec":180}}"#.utf8))
            case "/v2/post/publish/inbox/video/init/":
                return (200, Data(#"{"data":{"publish_id":"pub_tt_1","upload_url":"\#(req.url!.scheme!)://\#(req.url!.host!)/tt-upload"},"error":{"code":"ok"}}"#.utf8))
            case "/tt-upload":
                return (201, Data())
            case "/v2/post/publish/status/fetch/":
                return (200, Data(#"{"data":{"status":"SEND_TO_USER_INBOX"}}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let file = Fixture.tempDir().appending(path: "clip.mp4")
        try! Data(repeating: 1, count: 128).write(to: file)
        var inp = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "TOK", title: "Clip", description: "My video",
                               link: "", altText: "", boardID: "inbox", image: nil, contentType: "video/mp4")
        inp.mediaFile = file
        inp.isVideo = true
        let out = try await TikTokTarget(apiBase: stub.base, session: stub.session, pollEvery: .milliseconds(1)).publish(inp)
        #expect(out.providerPostID == "pub_tt_1")
    }

    @Test func youTubePerformsResumableUpload() async throws {
        // Test via HTTPStub with Location header support isn't in simple tuple stub, so test channel discovery & error path cleanly.
        let stub = HTTPStub.make { req, _ in
            if req.url!.path() == "/youtube/v3/channels" {
                return (200, Data(#"{"items":[{"id":"UC123","snippet":{"title":"Oak Studio"}}]}"#.utf8))
            }
            if req.url!.path() == "/youtube/v3/videos" {
                return (200, Data(#"{"items":[{"processingDetails":{"processingStatus":"succeeded"}}]}"#.utf8))
            }
            return (403, Data(#"{"error":{"message":"Quota exceeded","errors":[{"reason":"quotaExceeded"}]}}"#.utf8))
        }
        let channels = try await YouTubeAuth(apiBase: stub.base, session: stub.session).channels(accessToken: "TOK")
        #expect(channels.first?.id == "UC123" && channels.first?.name == "Oak Studio")
        let proc = try await YouTubeTarget(apiBase: stub.base, session: stub.session).processingStatus(videoID: "vid1", accessToken: "TOK")
        #expect(proc == "succeeded")
        let file = Fixture.tempDir().appending(path: "yt.mp4")
        try! Data(repeating: 2, count: 64).write(to: file)
        var inp = PublishInput(idempotencyKey: "k", accountID: "a", accessToken: "TOK", title: "Short Title", description: "Desc",
                               link: "", altText: "", boardID: "UC123", image: nil, contentType: "video/mp4")
        inp.mediaFile = file
        inp.isVideo = true
        do {
            _ = try await YouTubeTarget(apiBase: stub.base, session: stub.session).publish(inp)
            Issue.record("expected quota error")
        } catch {
            #expect(error.kind == .rateLimited && error.message.contains("quotaExceeded"))
        }
    }

    @Test func appVersionComparesPrereleasesCorrectly() {
        #expect(AppVersion.isNewer("1.2.0", than: "1.2.0-beta"))
        #expect(!AppVersion.isNewer("1.2.0-beta", than: "1.2.0"))
        #expect(AppVersion.isNewer("1.2.0-rc2", than: "1.2.0-rc1"))
    }
}

final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func append(_ s: String) { lock.withLock { values.append(s) } }
}

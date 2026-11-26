import Foundation
import Testing
@testable import SocialForgeKit

@Suite("On-Mac publish engine")
struct PublishEngineTests {
    func input(_ key: String = UUID().uuidString) -> PublishInput {
        PublishInput(idempotencyKey: key, accountID: "acct", accessToken: nil, title: "Mug", description: "d", link: "https://a.example",
                     altText: "", boardID: "board_winter", image: Data([1, 2, 3]), contentType: "image/jpeg")
    }
    func target() -> MockPinterestTarget {
        MockPinterestTarget(file: Fixture.tempDir().appending(path: "mock.json"))
    }
    let policy = RetryPolicy(maxAttempts: 3, baseDelay: 60, maxDelay: 600)

    @Test func backoffDoublesAndCaps() {
        #expect(policy.delay(afterAttempt: 1) == 60)
        #expect(policy.delay(afterAttempt: 2) == 120)
        #expect(policy.delay(afterAttempt: 5) == 600)
    }

    @Test func statusClassification() {
        #expect(PublishFailure.kind(forStatus: 503) == .retryable)
        #expect(PublishFailure.kind(forStatus: 429) == .rateLimited)
        #expect(PublishFailure.kind(forStatus: 401) == .auth)
        #expect(PublishFailure.kind(forStatus: 403) == .permission)
        #expect(PublishFailure.kind(forStatus: 400) == .permanent)
    }

    @Test func permission403DoesNotExpireAccount() async {
        let t = target()
        await t.setScript([.permission])
        let r = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: .now, policy: policy)
        guard case .actionRequired(let msg) = r.next else { Issue.record("expected actionRequired"); return }
        #expect(msg.contains("pins:write"))
    }

    @Test func rateLimitRespectsRetryAfter() async {
        let t = target()
        await t.setScript([.rateLimited(180)])
        let now = Date(timeIntervalSince1970: 2_000_000)
        let r = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: now, policy: policy, now: now)
        #expect(r.next == .retry(at: now.addingTimeInterval(180)))
    }

    @Test func successPublishesOnce() async {
        let t = target()
        let r = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: .now, policy: policy)
        guard case .published(let out) = r.next else { Issue.record("not published"); return }
        #expect(out.url?.hasPrefix("https://mock.pinterest.local/pin/") == true)
        #expect(await t.posts().count == 1)
    }

    @Test func retryableSchedulesALaterAttemptThenGivesUp() async {
        let t = target()
        await t.setScript([.retryable, .retryable, .retryable])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r1 = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: now, policy: policy, now: now)
        #expect(r1.next == .retry(at: now.addingTimeInterval(60)))
        #expect(r1.httpStatus == 503)
        let r3 = await PublishEngine.attempt(input(), target: t, attempt: 3, hadUncertain: false, firstTriedAt: now, policy: policy, now: now)
        guard case .failed(let msg, false) = r3.next else { Issue.record("should fail"); return }
        #expect(msg.contains("gave up after 3 attempts"))
    }

    @Test("A timeout after sending is reconciled, never posted twice")
    func uncertainIsReconciled() async {
        let t = target()
        await t.setScript([.uncertainAfterCreate])
        let i = input("key-1")
        let start = Date.now
        let r1 = await PublishEngine.attempt(i, target: t, attempt: 1, hadUncertain: false, firstTriedAt: start, policy: policy)
        #expect(r1.outcome == "uncertain")
        let r2 = await PublishEngine.attempt(i, target: t, attempt: 2, hadUncertain: true, firstTriedAt: start, policy: policy)
        #expect(r2.outcome == "reconciled")
        #expect(await t.posts().count == 1)
    }

    @Test func authFailsAtOnceAndExpiresTheAccount() async {
        let t = target()
        await t.setScript([.auth])
        let r = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: .now, policy: policy)
        guard case .failed(let msg, true) = r.next else { Issue.record("should expire"); return }
        #expect(msg.contains("Reconnect"))
    }

    @Test func permanentFailsAtOnce() async {
        let t = target()
        await t.setScript([.permanent])
        let r = await PublishEngine.attempt(input(), target: t, attempt: 1, hadUncertain: false, firstTriedAt: .now, policy: policy)
        guard case .failed(_, false) = r.next else { Issue.record("should fail"); return }
        #expect(await t.posts().isEmpty)
    }

    @Test func pinterestAuthorizeURL() {
        let u = PinterestTarget.authorizeURL(clientID: "123", redirectURI: "http://127.0.0.1:8085/pinterest/callback", state: "s")
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.first { $0.name == "scope" }?.value == "user_accounts:read,boards:read,pins:read,pins:write")
        #expect(q.first { $0.name == "response_type" }?.value == "code")
    }
}

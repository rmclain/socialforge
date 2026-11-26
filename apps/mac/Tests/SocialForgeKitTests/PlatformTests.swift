import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Platform registry and validation")
struct PlatformTests {
    @Test func embeddedSpecsMatchSpecFolder() throws {
        let specDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "spec/platforms")
        let files = try FileManager.default.contentsOfDirectory(at: specDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count == PlatformSpecData.json.count, "run python3 tools/gen-spec.py")
        for f in files {
            let disk = try String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(PlatformSpecData.json[f.deletingPathExtension().lastPathComponent] == disk, "run python3 tools/gen-spec.py")
        }
    }

    @Test func registryDecodesEveryPlatform() {
        #expect(Set(PlatformRegistry.all.map(\.platform)) == ["pinterest", "x", "linkedin", "facebook", "tiktok", "instagram", "youtube", "threads"])
        #expect(Set(PlatformRegistry.all.filter(\.isAvailable).map(\.platform)) == ["pinterest", "facebook", "instagram", "threads", "linkedin", "x", "tiktok", "youtube"])
        // Built, never claimed as verified live.
        #expect(PlatformRegistry.all.allSatisfy { !$0.liveVerified })
        #expect(PlatformStatus.summary(PlatformRegistry.spec("instagram")!).contains("not yet verified live"))
        #expect(PlatformRegistry.all.allSatisfy { $0.video != nil })
        #expect(PlatformRegistry.spec("youtube")?.image == nil)
        #expect(PlatformRegistry.spec("pinterest")?.isAvailable == true)
        #expect(PlatformRegistry.spec("linkedin")?.image?.maxBytes == 5_242_880)
        #expect(PlatformRegistry.all.allSatisfy { !$0.liveVerified })
    }

    func pin(_ title: String = "Stoneware Mug", description: String = "Hand-thrown.", link: String = "https://oakandember.com/p/mug",
             board: String? = "b1", image: ImageFacts? = ImageFacts(width: 1000, height: 1500, bytes: 400_000, format: "jpeg")) -> PostDraft {
        PostDraft(platform: "pinterest", title: title, description: description, link: link, altText: "A grey mug", destinationID: board, image: image)
    }

    @Test func validPinHasNoErrors() {
        #expect(PostValidator.validate(pin()).filter { $0.level == .error }.isEmpty)
    }

    @Test func textLimits() {
        let issues = PostValidator.validate(pin(String(repeating: "t", count: 101), description: String(repeating: "d", count: 801)))
        #expect(issues.contains { $0.field == "title" && $0.level == .error && $0.message.contains("100") })
        #expect(issues.contains { $0.field == "description" && $0.level == .error && $0.message.contains("800") })
    }

    @Test func boardAndLinkRequiredForUse() {
        let issues = PostValidator.validate(pin(link: "ftp://x", board: nil))
        #expect(issues.contains { $0.field == "board" && $0.level == .error })
        #expect(issues.contains { $0.field == "link" && $0.level == .error })
    }

    @Test func imageRules() {
        let heic = PostValidator.validate(pin(image: ImageFacts(width: 400, height: 400, bytes: 25_000_000, format: "heic")))
        #expect(heic.contains { $0.field == "image" && $0.level == .error && $0.message.contains("HEIC") })
        #expect(heic.contains { $0.field == "image" && $0.level == .error && $0.message.contains("MB") })
        #expect(heic.contains { $0.field == "image" && $0.level == .warning && $0.message.contains("px wide") })
        // A square image is accepted; 2:3 is only recommended.
        #expect(heic.contains { $0.level == .info && $0.message.contains("2:3") })
    }

    @Test func allPlatformsValidateTextAndXWeightedLength() {
        // X weighted counting: URL counts as 23 chars even if longer; empty X text fails required check.
        #expect(PostValidator.validate(PostDraft(platform: "x", description: "")).contains { $0.field == "text" && $0.level == .error })
        let url = "https://example.com/very/long/product/url/that/exceeds/twenty-three/characters"
        #expect(XTextLength.weightedCount("Hi \(url)") == 3 + 23)
        #expect(PostValidator.validate(PostDraft(platform: "x", description: String(repeating: "a", count: 281))).contains { $0.field == "text" && $0.level == .error })
        // Instagram caption max 2200 & public media host check for image posts.
        let igOver = PostValidator.validate(PostDraft(platform: "instagram", description: String(repeating: "c", count: 2201),
                                                      image: ImageFacts(width: 1080, height: 1350, bytes: 100_000, format: "jpeg"),
                                                      hasPublicMediaHost: false))
        #expect(igOver.contains { $0.field == "caption" && $0.level == .error })
        #expect(igOver.contains { $0.field == "storage" && $0.level == .error })
        // LinkedIn requires commentary.
        #expect(PostValidator.validate(PostDraft(platform: "linkedin", description: "")).contains { $0.field == "commentary" && $0.level == .error })
        // YouTube requires title and Shorts requires vertical/square aspect.
        #expect(PostValidator.validate(PostDraft(platform: "youtube", title: "")).contains { $0.field == "title" && $0.level == .error })
        let badShort = PostValidator.validateVideo(platform: "youtube", seconds: 30, width: 1920, height: 1080, bytes: 1_000_000, format: "mp4", requireShortsAspect: true)
        #expect(badShort.contains { $0.level == .error && $0.message.contains("square or vertical") })
    }

    @Test func duplicatesAcrossARun() {
        let w = PostValidator.duplicates([(id: "1", imageHash: "h", link: "https://a"), (id: "2", imageHash: "h", link: "https://A"),
                                          (id: "3", imageHash: "z", link: "https://b")])
        #expect(w["1"]?.count == 2)
        #expect(w["3"] == nil)
    }

    @Test("Scenario E: an account without pins:write cannot publish")
    func capabilities() {
        let ok = Capabilities.forAccount(platform: "pinterest", grantedScopes: ["boards:read", "pins:write", "pins:read"], status: "connected")
        #expect(ok.allSatisfy { $0.allowed })
        let readOnly = Capabilities.forAccount(platform: "pinterest", grantedScopes: ["boards:read"], status: "connected")
        #expect(readOnly.first?.allowed == false)
        #expect(readOnly.first?.missingScopes == ["pins:write"])
        #expect(readOnly.first?.reason?.contains("Reconnect") == true)
        let expired = Capabilities.forAccount(platform: "pinterest", grantedScopes: ["boards:read", "pins:write"], status: "expired")
        #expect(expired.first?.allowed == false)
        let liMember = Capabilities.forAccount(platform: "linkedin", grantedScopes: ["w_member_social"], status: "connected")
        #expect(liMember.first(where: { $0.contentType.id == "member_post" })?.allowed == true)
        #expect(liMember.first(where: { $0.contentType.id == "organization_post" })?.allowed == false)
        let tiktokInbox = Capabilities.forAccount(platform: "tiktok", grantedScopes: ["video.upload"], status: "connected")
        #expect(tiktokInbox.first(where: { $0.contentType.id == "inbox_video" })?.allowed == true)
        #expect(tiktokInbox.first(where: { $0.contentType.id == "video" })?.allowed == false)
    }

    @Test func videoRules() {
        // A 30 s vertical MP4 fits TikTok.
        let ok = PostValidator.validateVideo(platform: "tiktok", seconds: 30, width: 1080, height: 1920, bytes: 40_000_000, format: "mp4", fps: 30)
        #expect(ok.isEmpty)
        // Too long for Facebook Reels (90 s), and landscape is only information.
        let fb = PostValidator.validateVideo(platform: "facebook", seconds: 120, width: 1920, height: 1080, bytes: 10_000_000, format: "mp4")
        #expect(fb.filter { $0.level == .error }.count == 1)
        #expect(fb.contains { $0.level == .info && $0.message.contains("9:16") })
        // Instagram: 300 MB cap, MOV or MP4 only, at least 23 fps.
        let ig = PostValidator.validateVideo(platform: "instagram", seconds: 10, width: 1080, height: 1920, bytes: 400_000_000, format: "webm", fps: 15)
        #expect(ig.filter { $0.level == .error }.count == 3)
        // Too short for Pinterest (4 s).
        #expect(PostValidator.validateVideo(platform: "pinterest", seconds: 2, width: 1080, height: 1920, bytes: 1_000_000, format: "mp4").contains { $0.level == .error })
        #expect(PostValidator.validateVideo(platform: "nope", seconds: 2, width: 1, height: 1, bytes: 1, format: "mp4").first?.field == "platform")
    }

    @Test func youtubeTakesNoImagePosts() {
        let issues = PostValidator.validate(PostDraft(platform: "youtube", image: ImageFacts(width: 1080, height: 1920, bytes: 1000, format: "jpeg")))
        #expect(issues.contains { $0.field == "image" && $0.message.contains("does not take image posts") })
    }

    @Test func durations() {
        #expect(PostValidator.duration(90) == "1 min 30 s")
        #expect(PostValidator.duration(600) == "10 min")
        #expect(PostValidator.duration(45) == "45 s")
        #expect(PlatformStatus.summary(PlatformRegistry.spec("tiktok")!).contains("not yet verified live"))
        #expect(PlatformStatus.summary(PlatformRegistry.spec("x")!).contains("not yet verified live"))
    }
}

@Suite("Backend sync")
struct SyncTests {
    func server(_ client: String, _ status: String, url: String? = nil) -> API.Publication {
        API.Publication(id: "s-\(client)", clientId: client, status: status, scheduledAt: .now, publishedUrl: url,
                        providerPostId: nil, lastError: status == "failed" ? "401" : nil, attempts: 1, updatedAt: .now)
    }

    @Test("Scenario D: results merge into local rows by id")
    func merge() {
        let local = [LocalPublicationState(clientId: "a", serverId: nil, status: "scheduled"),
                     LocalPublicationState(clientId: "b", serverId: "s-b", status: "scheduled"),
                     LocalPublicationState(clientId: "c", serverId: "s-c", status: "canceled")]
        let (out, changed) = SyncMerge.merge(local: local, server: [server("a", "published", url: "https://pin.it/1"), server("b", "failed"),
                                                                    server("c", "failed"), server("zzz", "published")])
        #expect(out.count == 3)
        #expect(out[0].status == "published" && out[0].publishedUrl == "https://pin.it/1" && out[0].serverId == "s-a")
        #expect(out[1].status == "failed" && out[1].lastError == "401")
        #expect(out[2].status == "canceled")
        #expect(changed == 2)
    }

    @Test func decodesServerDates() throws {
        let json = #"{"publications":[{"id":"1","clientId":"c","status":"scheduled","scheduledAt":"2026-12-01T14:00:00.000Z","attempts":0,"updatedAt":"2026-11-19T10:00:00Z"}],"serverTime":"2026-11-19T10:00:00.123Z"}"#
        let p = try BackendClient.decoder.decode(API.Publications.self, from: Data(json.utf8))
        #expect(p.publications.first?.scheduledAt == ISO8601.parse("2026-12-01T14:00:00Z"))
        #expect(p.serverTime != nil)
    }

    @Test func comfyTransportRules() {
        #expect(ComfyUIClient.transportProblem(URL(string: "http://127.0.0.1:8188")!) == nil)
        #expect(ComfyUIClient.transportProblem(URL(string: "http://192.168.1.20:8188")!) == nil)
        #expect(ComfyUIClient.transportProblem(URL(string: "http://comfy.example.com")!) != nil)
        #expect(ComfyUIClient.transportProblem(URL(string: "https://comfy.example.com")!) == nil)
    }
}

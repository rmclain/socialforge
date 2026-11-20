import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Updates from GitHub releases")
struct UpdaterTests {
    func release(tag: String = "v0.3.0", asset: String = "SocialForge-0.3.0.zip", url: String? = nil, draft: Bool = false) -> Data {
        let link = url ?? "https://github.com/rmclain/socialforge/releases/download/\(tag)/\(asset)"
        return Data("""
        {"tag_name":"\(tag)","name":"SocialForge 0.3.0","body":"New: things.","draft":\(draft),"prerelease":false,
         "html_url":"https://github.com/rmclain/socialforge/releases/tag/\(tag)","published_at":"2026-11-19T12:00:00Z",
         "assets":[{"name":"\(asset)","size":1234,"browser_download_url":"\(link)"}]}
        """.utf8)
    }

    @Test func versions() {
        #expect(AppVersion.isNewer("v0.10", than: "0.9"))
        #expect(AppVersion.isNewer("0.2.1", than: "0.2.0"))
        #expect(!AppVersion.isNewer("0.2.0", than: "0.2"))
        #expect(!AppVersion.isNewer("1.2.0-beta", than: "1.2.0"))
    }

    @Test func repositoryNames() {
        #expect(UpdateChecker.isValidRepository("rmclain/socialforge"))
        #expect(!UpdateChecker.isValidRepository("rmclain"))
        #expect(!UpdateChecker.isValidRepository("../x/y"))
        #expect(!UpdateChecker.isValidRepository("a/-b"))
    }

    @Test func parsesTheZipAndRejectsOtherHosts() {
        #expect(UpdateChecker.parse(release())?.version == "0.3.0")
        #expect(UpdateChecker.parse(release(asset: "Other.zip")) == nil)
        #expect(UpdateChecker.parse(release(url: "https://evil.example/SocialForge.zip")) == nil)
        #expect(UpdateChecker.parse(release(url: "http://github.com/x/SocialForge.zip")) == nil)
        #expect(UpdateChecker.parse(release(draft: true)) == nil)
        #expect(UpdateChecker.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/a")!))
    }

    @Test func checkFindsANewerRelease() async {
        let body = release()
        let stub = HTTPStub.make { req, _ in
            (req.url?.path == "/repos/rmclain/socialforge/releases/latest" ? 200 : 404, body)
        }
        let checker = UpdateChecker(repository: "rmclain/socialforge", session: stub.session, apiBase: stub.base)
        guard case .available(let r) = await checker.check(currentVersion: "0.2.0") else { Issue.record("expected an update"); return }
        #expect(r.version == "0.3.0" && r.notes == "New: things.")
        #expect(await checker.check(currentVersion: "0.3.0") == .upToDate(latest: "0.3.0"))
    }

    @Test func noReleasesAndRateLimits() async {
        let none = HTTPStub.make { _, _ in (404, Data()) }
        #expect(await UpdateChecker(repository: "a/b", session: none.session, apiBase: none.base).check(currentVersion: "1") == .noDownload("No release has been published yet."))
        let limited = HTTPStub.make { _, _ in (403, Data()) }
        guard case .failed(let why) = await UpdateChecker(repository: "a/b", session: limited.session, apiBase: limited.base).check(currentVersion: "1") else {
            Issue.record("expected failure"); return
        }
        #expect(why.contains("limiting"))
    }

    @Test func teamParsing() {
        #expect(UpdateInstaller.parseTeam("Identifier=x\nTeamIdentifier=S572Y4JKKT\n") == "S572Y4JKKT")
        #expect(UpdateInstaller.parseTeam("TeamIdentifier=not set") == nil)
    }

    @Test func unpackFindsTheAppAndVerifyRejectsUnsigned() async throws {
        let dir = Fixture.tempDir()
        let app = dir.appending(path: "src/SocialForge.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: app.appending(path: "SocialForge"))
        let zip = dir.appending(path: "SocialForge-9.zip")
        _ = try await UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dir.appending(path: "src/SocialForge.app").path, zip.path])
        let found = try await UpdateInstaller().unpack(zip, into: dir.appending(path: "work"))
        #expect(found.lastPathComponent == "SocialForge.app")
        await #expect(throws: UpdateInstaller.Failure.self) { try await UpdateInstaller().verify(found, sameTeamAs: found) }
    }

    /// The new copy opens only after the old one has exited, so two never run at once.
    @Test func relaunchWaitsForTheOldCopyToExit() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        let old = Process()
        old.executableURL = URL(filePath: "/bin/sleep")
        old.arguments = ["1"]
        try old.run()
        let (tool, args) = UpdateInstaller.relaunchCommand(waitingFor: old.processIdentifier, then: marker, opener: "/usr/bin/touch")
        let waiter = Process()
        waiter.executableURL = URL(filePath: tool)
        waiter.arguments = args
        try waiter.run()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "opened while the old copy still ran")
        old.waitUntilExit()
        waiter.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: marker)
    }

    @Test func relaunchPassesPathsAsArguments() {
        let app = URL(filePath: "/Applications/Odd \"name\"; rm -rf ~.app")
        let (tool, args) = UpdateInstaller.relaunchCommand(waitingFor: 42, then: app)
        #expect(tool == "/bin/sh")
        #expect(args.last == app.path)
        #expect(!args[1].contains(app.path))
    }
}

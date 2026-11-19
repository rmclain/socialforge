import Foundation
import Testing
@testable import SocialForgeKit

/// The real update path against the published GitHub release. Off by default (it uses the network);
/// run with SF_LIVE_UPDATE=1 swift test --filter LiveUpdate
@Suite("Live update from GitHub", .enabled(if: ProcessInfo.processInfo.environment["SF_LIVE_UPDATE"] == "1"))
struct LiveUpdateTests {
    @Test func olderCopyFindsDownloadsAndAcceptsTheRelease() async throws {
        let check = await UpdateChecker(repository: "rmclain/socialforge").check(currentVersion: "0.1.9")
        guard case .available(let release) = check else { Issue.record("expected an update, got \(check)"); return }
        #expect(release.downloadURL.lastPathComponent.hasPrefix("SocialForge-"))

        let work = Fixture.tempDir()
        let installer = UpdateInstaller()
        let zip = try await installer.download(release, into: work)
        let app = try await installer.unpack(zip, into: work)
        #expect(app.lastPathComponent == "SocialForge.app")

        // The installed copy (Apple Development, same team) must accept the Developer ID release.
        let installed = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Applications/SocialForge.app")
        try await installer.verify(app, sameTeamAs: installed)
        #expect(await installer.teamIdentifier(of: app) == "S572Y4JKKT")

        // And the same release is "up to date" for a copy that already has it.
        #expect(await UpdateChecker(repository: "rmclain/socialforge").check(currentVersion: release.version) == .upToDate(latest: release.version))
    }
}

import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Developer keys")
struct PlatformKeysTests {
    @Test func everyPlatformSaysWhereItsKeysComeFrom() {
        for spec in PlatformRegistry.all {
            let keys = PlatformKeys.forPlatform(spec.platform)
            #expect(keys != nil, "\(spec.platform) has no developer site")
            #expect(keys?.portal.scheme == "https" && keys?.guide.scheme == "https")
            #expect(keys?.keys.isEmpty == false)
        }
        #expect(Set(PlatformKeys.all.map(\.platform)).count == PlatformKeys.all.count)
    }

    @Test func onlyPlatformsSocialForgePostsToAskForKeys() {
        for keys in PlatformKeys.all {
            #expect(keys.usedBySocialForge == (PlatformRegistry.spec(keys.platform)?.isAvailable == true), "\(keys.platform)")
        }
    }
}

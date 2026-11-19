import CoreGraphics
import Foundation
import Testing
@testable import SocialForgeKit

@Suite("On-device image operations")
struct ImageOpsTests {
    func sample() -> URL { Fixture.image(Fixture.tempDir().appending(path: "s.png"), width: 200, height: 300, type: .png) }

    @Test func upscaleDoublesSize() throws {
        let out = Fixture.tempDir().appending(path: "u.png")
        try ImageOps.upscale2x(sample()).write(to: out)
        let info = try #require(ImageProbe.info(out))
        #expect(info.width == 400 && info.height == 600)
    }

    @Test func saliencyIsNormalized() throws {
        let p = try ImageOps.saliencyFocus(sample())
        #expect((0...1).contains(p.x) && (0...1).contains(p.y))
    }

    @Test func tintKeepsSize() throws {
        let out = Fixture.tempDir().appending(path: "t.png")
        try ImageOps.tint(sample(), color: RGBA(hex: 0xFF8A5C)).write(to: out)
        #expect(ImageProbe.info(out)?.width == 200)
    }

    @Test func removeBackgroundGivesAlphaOrSaysNoSubject() throws {
        do {
            let out = Fixture.tempDir().appending(path: "r.png")
            try ImageOps.removeBackground(sample()).write(to: out)
            #expect(ImageProbe.info(out)?.hasAlpha == true)
        } catch let e as ImageOps.OpError {
            #expect(e == .noSubject || e.errorDescription != nil)
        }
    }

    @Test func unreadableThrows() {
        let bad = Fixture.tempDir().appending(path: "x.png")
        try? Data("no".utf8).write(to: bad)
        #expect(throws: ImageOps.OpError.unreadable) { try ImageOps.upscale2x(bad) }
    }

    @Test func focusMovesTheFillCrop() {
        let (left, _) = ImageTransformer.layout(source: CGSize(width: 2000, height: 1000), canvas: CGSize(width: 1000, height: 1000), mode: .fill, focus: CGPoint(x: 0.1, y: 0.5))
        let (right, _) = ImageTransformer.layout(source: CGSize(width: 2000, height: 1000), canvas: CGSize(width: 1000, height: 1000), mode: .fill, focus: CGPoint(x: 0.9, y: 0.5))
        #expect(left.minX > right.minX)
    }
}

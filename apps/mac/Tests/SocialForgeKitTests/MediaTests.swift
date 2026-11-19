import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SocialForgeKit

/// Fixture images are drawn at test time, so the repo holds no binaries.
enum Fixture {
    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "sf-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    static func image(_ url: URL, width: Int, height: Int, color: (Double, Double, Double) = (0.8, 0.3, 0.2),
                      type: UTType = .jpeg, alpha: Bool = false, exifNote: String? = nil) -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let exifNote { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: exifNote] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }
}

@Suite("Media import")
struct MediaImportTests {
    @Test func recursiveScanSortsAndSkips() throws {
        let dir = Fixture.tempDir()
        let sub = dir.appending(path: "Winter")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        Fixture.image(dir.appending(path: "b.jpg"), width: 20, height: 30)
        Fixture.image(sub.appending(path: "a.png"), width: 20, height: 30, type: .png)
        Fixture.image(sub.appending(path: "c.heic"), width: 20, height: 30, type: .heic)
        try Data("x".utf8).write(to: dir.appending(path: "notes.txt"))
        try Data("x".utf8).write(to: dir.appending(path: ".hidden.jpg"))
        try Data("filename\n".utf8).write(to: dir.appending(path: "products.csv"))

        let r = MediaScanner.scan([dir])
        #expect(r.files.map(\.url.lastPathComponent).sorted() == ["a.png", "b.jpg", "c.heic"])
        #expect(r.skipped.map(\.url.lastPathComponent) == ["notes.txt"])
        #expect(r.skipped.first?.reason.contains(".txt") == true)
    }

    @Test func importCopiesHashesAndFindsDuplicates() async throws {
        let src = Fixture.tempDir(), lib = Fixture.tempDir()
        let a = Fixture.image(src.appending(path: "a.jpg"), width: 40, height: 60)
        let copy = src.appending(path: "a-copy.jpg")
        try FileManager.default.copyItem(at: a, to: copy)
        let b = Fixture.image(src.appending(path: "b.png"), width: 50, height: 50, color: (0.1, 0.5, 0.9), type: .png, alpha: true)
        try Data("not an image".utf8).write(to: src.appending(path: "broken.jpg"))
        let before = try Data(contentsOf: a)

        let files = MediaScanner.scan([src]).files
        let storage = ManagedStorage(root: lib)
        let out = await MediaImporter.run(files, storage: storage, known: [])
        #expect(out.imported.count == 2)
        #expect(out.duplicates.count == 1)
        #expect(out.failed.map(\.url.lastPathComponent) == ["broken.jpg"])
        // Originals untouched; copies live under the library.
        #expect(try Data(contentsOf: a) == before)
        let stored = try #require(out.imported.first { $0.source.lastPathComponent == "b.png" })
        #expect(stored.stored.path.hasPrefix(lib.path))
        #expect(stored.info == ImageInfo(width: 50, height: 50, hasAlpha: true, format: "png"))
        #expect(try ContentHash.sha256(of: b) == stored.hash)

        // A second import of the same folder finds only duplicates.
        let again = await MediaImporter.run(files, storage: storage, known: Set(out.imported.map(\.hash)))
        #expect(again.imported.isEmpty)
        #expect(again.duplicates.count == 3)
    }

    @Test func hashIsStable() throws {
        let f = Fixture.tempDir().appending(path: "x.bin")
        try Data("hello".utf8).write(to: f)
        #expect(try ContentHash.sha256(of: f) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}

@Suite("Image transforms")
struct TransformTests {
    @Test func fillLayoutCoversWithoutStretching() {
        let (draw, crop) = ImageTransformer.layout(source: CGSize(width: 2000, height: 2000), canvas: CGSize(width: 1000, height: 1500), mode: .fill)
        #expect(draw.width == draw.height)
        #expect(draw.height == 1500)
        #expect(draw.minX <= 0 && draw.maxX >= 1000)
        #expect(crop.width.rounded() == 1333 && crop.height == 2000)
        #expect(crop.minX.rounded() == 333)
    }

    @Test func fillFocusIsClamped() {
        let (draw, _) = ImageTransformer.layout(source: CGSize(width: 2000, height: 1000), canvas: CGSize(width: 1000, height: 1000), mode: .fill, focus: CGPoint(x: 0, y: 0.5))
        #expect(draw.minX == 0)
    }

    @Test func fitLayoutPads() {
        let (draw, _) = ImageTransformer.layout(source: CGSize(width: 2000, height: 1000), canvas: CGSize(width: 1000, height: 1500), mode: .fit)
        #expect(draw.width == 1000 && draw.height == 500)
        #expect(draw.minY == 500)
    }

    @Test("Scenario C: Pinterest variants keep the original and hit the exact size", arguments: [FitMode.fill, .fit])
    func pinterestVariant(mode: FitMode) throws {
        let dir = Fixture.tempDir()
        let src = Fixture.image(dir.appending(path: "src.png"), width: 1200, height: 800, type: .png, alpha: true, exifNote: "secret")
        let before = try Data(contentsOf: src)
        var preset = ExportPreset.builtIn[0]
        preset.mode = mode
        let out = try ImageTransformer.apply(preset, to: src, output: dir.appending(path: "out.jpg"))
        #expect(try Data(contentsOf: src) == before)
        let info = try #require(ImageProbe.info(out.url))
        #expect(info.width == 1000 && info.height == 1500 && info.format == "jpeg")
        // EXIF stripped by default.
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out.url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(PostValidator.validate(PostDraft(platform: "pinterest", title: "t", link: "https://a.b", destinationID: "b",
                                                 image: ImageFacts(width: info.width, height: info.height, bytes: out.bytes, format: info.format)))
            .filter { $0.field == "image" }.isEmpty)
    }

    @Test func unreadableSourceThrows() {
        let dir = Fixture.tempDir()
        let bad = dir.appending(path: "bad.jpg")
        try? Data("nope".utf8).write(to: bad)
        #expect(throws: ImageTransformer.TransformError.unreadable) {
            try ImageTransformer.apply(ExportPreset.builtIn[0], to: bad, output: dir.appending(path: "o.jpg"))
        }
    }
}

@Suite("Creative documents")
struct CreativeTests {
    func doc(font: String = "Helvetica") -> CreativeDocument {
        CreativeDocument(name: "Pin", width: 1000, height: 1500, background: RGBA(hex: 0xF4EFE8), layers: [
            CreativeLayer(name: "Band", x: 0, y: 1100, width: 1000, height: 400,
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(hex: 0x2A211C), gradientTo: RGBA(hex: 0x5A4436)))),
            CreativeLayer(name: "Headline", x: 80, y: 120, width: 840, height: 400,
                          content: .text(TextLayer(text: "{{title}}", fontName: font, size: 96, color: RGBA(hex: 0x2A211C)))),
            CreativeLayer(name: "Price", x: 80, y: 1200, width: 840, height: 120,
                          content: .text(TextLayer(text: "{{ price }} · {{cta}}", fontName: font, size: 56, color: .white, alignment: .center))),
        ])
    }

    @Test func jsonRoundTrip() throws {
        let d = doc()
        #expect(try CreativeDocument.from(json: d.json()) == d)
    }

    @Test func templateVariablesFillAndStayVisibleWhenMissing() {
        let d = doc()
        #expect(d.variables == ["title", "price", "cta"])
        let filled = d.filled(["title": "Slow mornings", "price": "$38"])
        guard case .text(let h) = filled.layers[1].content, case .text(let p) = filled.layers[2].content else {
            Issue.record("not text"); return
        }
        #expect(h.text == "Slow mornings")
        #expect(p.text == "$38 · {{cta}}")
    }

    @Test func rendersAtCanvasSizeWithRealText() throws {
        let image = try CreativeRenderer.render(doc().filled(["title": "Slow mornings", "price": "$38", "cta": "Shop"]))
        #expect(image.width == 1000 && image.height == 1500)
        // The headline area is no longer just background.
        let empty = try CreativeRenderer.render(CreativeDocument(name: "e", width: 1000, height: 1500, background: RGBA(hex: 0xF4EFE8)))
        let headline = CGRect(x: 80, y: 120, width: 840, height: 200)
        #expect(inkCount(empty, headline) == 0)
        #expect(inkCount(image, headline) > 20)
        // The gradient band is dark at the bottom.
        let bottom = pixel(image, 500, 1490)
        #expect(bottom.0 < 120)
    }

    @Test func missingFontIsReportedNotSubstituted() {
        let d = doc(font: "NoSuchFont-Regular")
        #expect(d.missingFonts == ["NoSuchFont-Regular"])
        #expect(throws: CreativeRenderer.RenderError.missingFonts(["NoSuchFont-Regular"])) { try CreativeRenderer.render(d) }
        #expect((try? CreativeRenderer.render(d, scale: 0.25, allowFallbackFonts: true)) != nil)
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    func inkCount(_ img: CGImage, _ r: CGRect) -> Int {
        var n = 0
        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 8) {
            for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 8) where pixel(img, x, y).0 < 120 { n += 1 }
        }
        return n
    }
}

@Suite("Import order")
struct ImportOrderTests {
    @Test("Of identical files, the first in folder order is kept", arguments: 1...5)
    func firstWins(run: Int) async throws {
        let src = Fixture.tempDir(), lib = Fixture.tempDir()
        let a = Fixture.image(src.appending(path: "a-original.jpg"), width: 30, height: 30)
        for i in 0..<6 { try FileManager.default.copyItem(at: a, to: src.appending(path: "z-copy-\(i).jpg")) }
        let out = await MediaImporter.run(MediaScanner.scan([src]).files, storage: ManagedStorage(root: lib), known: [], concurrency: 4)
        #expect(out.imported.map(\.source.lastPathComponent) == ["a-original.jpg"])
        #expect(out.duplicates.count == 6)
    }
}

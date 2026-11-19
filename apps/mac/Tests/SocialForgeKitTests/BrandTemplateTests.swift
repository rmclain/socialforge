import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Brand templates")
struct BrandTemplateTests {
    let brand = BrandStyle(palette: [RGBA(hex: 0x2A211C), RGBA(hex: 0xF4EFE8), RGBA(hex: 0xFF8A5C)],
                           headlineFont: "Georgia", bodyFont: "Helvetica", logoPath: "/tmp/logo.png")

    func template() -> CreativeDocument {
        CreativeDocument(name: "T", width: 1000, height: 1500, background: .white, layers: [
            CreativeLayer(name: "Photo", x: 0, y: 0, width: 1000, height: 1500, content: .image(ImageLayer(path: "", role: "photo"))),
            CreativeLayer(name: "Band", x: 0, y: 1100, width: 1000, height: 400,
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(0, 0, 0, 0.8), fillRole: "brand.0"))),
            CreativeLayer(name: "Logo", x: 60, y: 60, width: 160, height: 60, content: .image(ImageLayer(path: "", mode: .fit, role: "logo"))),
            CreativeLayer(name: "Headline", x: 80, y: 1140, width: 840, height: 200,
                          content: .text(TextLayer(text: "{{title}}", fontName: "Times", size: 80, colorRole: "brand.1", fontRole: "headline"))),
            CreativeLayer(name: "Wordmark", x: 80, y: 80, width: 840, height: 40,
                          content: .text(TextLayer(text: "oak & ember", fontName: "Times", size: 24, fontRole: "body", tracking: 6, uppercase: true))),
        ])
    }

    @Test func brandRolesResolveColorsFontsAndLogo() {
        let d = template().applyingBrand(brand)
        guard case .shape(let band) = d.layers[1].content, case .image(let logo) = d.layers[2].content,
              case .text(let h) = d.layers[3].content, case .text(let w) = d.layers[4].content else { Issue.record("kinds"); return }
        #expect(band.fill.hex == 0x2A211C && band.fill.a == 0.8)
        #expect(logo.path == "/tmp/logo.png")
        #expect(h.color.hex == 0xF4EFE8 && h.fontName == "Georgia")
        #expect(w.fontName == "Helvetica" && w.displayText == "OAK & EMBER")
    }

    @Test func changingTheBrandRestylesTheSameTemplate() {
        var other = brand
        other.palette[0] = RGBA(hex: 0x123456)
        guard case .shape(let s) = template().applyingBrand(other).layers[1].content else { return }
        #expect(s.fill.hex == 0x123456)
    }

    @Test func photoSlotsFillPerAsset() {
        let d = template().withPhoto("/tmp/a.jpg")
        #expect(d.hasPhotoSlot)
        guard case .image(let i) = d.layers[0].content else { return }
        #expect(i.path == "/tmp/a.jpg")
    }

    @Test func emptySlotsRenderWithoutError() throws {
        let img = try CreativeRenderer.render(template().applyingBrand(BrandStyle(palette: brand.palette, headlineFont: "Helvetica", bodyFont: "Helvetica")).filled(["title": "Hi"]), scale: 0.2)
        #expect(img.width == 200)
    }

    @Test("Smart resize keeps text unstretched and full-bleed layers full-bleed", arguments: CanvasPreset.all)
    func smartResize(preset: CanvasPreset) {
        let d = template().resized(width: preset.width, height: preset.height)
        #expect(d.width == preset.width && d.height == preset.height)
        #expect(d.layers[0].width == Double(preset.width) && d.layers[0].height == Double(preset.height))
        guard case .text(let h) = d.layers[3].content else { return }
        let s = min(Double(preset.width) / 1000, Double(preset.height) / 1500)
        #expect(h.size == (80 * s).rounded())
        #expect(d.layers.allSatisfy { $0.width <= Double(preset.width) + 1 })
    }

    @Test func oldDocumentsWithoutRolesStillDecode() throws {
        let json = #"{"version":1,"name":"Old","width":100,"height":100,"background":{"r":1,"g":1,"b":1,"a":1},"layers":[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"T","x":0,"y":0,"width":10,"height":10,"opacity":1,"isLocked":false,"isHidden":false,"content":{"text":{"_0":{"text":"a","fontName":"Helvetica","size":12,"lineHeight":1,"color":{"r":0,"g":0,"b":0,"a":1},"alignment":"leading","shadow":false}}}}]}"#
        let d = try CreativeDocument.from(json: Data(json.utf8))
        #expect(d.layers.count == 1)
    }
}

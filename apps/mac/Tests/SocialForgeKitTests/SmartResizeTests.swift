import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Generate all sizes keeps the layout together")
struct SmartResizeTests {
    /// Like the Editorial template: photo, a shade at the top, headline, and a price button (pill + two labels).
    func pin() -> CreativeDocument {
        CreativeDocument(name: "Editorial", width: 1000, height: 1500, background: RGBA(hex: 0xB98A68), layers: [
            CreativeLayer(name: "Photo", x: 0, y: 0, width: 1000, height: 1500, content: .image(ImageLayer(path: "", role: "photo"))),
            CreativeLayer(name: "Shade", x: 0, y: 0, width: 1000, height: 700, content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(0, 0, 0, 0.3)))),
            CreativeLayer(name: "Headline", x: 80, y: 150, width: 840, height: 330,
                          content: .text(TextLayer(text: "{{title}}", fontName: "Helvetica", size: 150))),
            CreativeLayer(name: "Footer", x: 0, y: 1440, width: 1000, height: 60, content: .shape(ShapeLayer(kind: .rectangle, fill: .white))),
            CreativeLayer(name: "Price tag", x: 250, y: 1300, width: 500, height: 92, group: "Price",
                          content: .shape(ShapeLayer(kind: .rectangle, fill: .white, cornerRadius: 46))),
            CreativeLayer(name: "Price", x: 280, y: 1322, width: 130, height: 50, group: "Price",
                          content: .text(TextLayer(text: "{{price}}", fontName: "Helvetica", size: 36))),
            CreativeLayer(name: "Call to action", x: 410, y: 1322, width: 320, height: 50, group: "Price",
                          content: .text(TextLayer(text: "{{cta}}", fontName: "Helvetica", size: 34))),
        ])
    }

    func layer(_ d: CreativeDocument, _ name: String) -> CreativeLayer { d.layers.first { $0.name == name }! }

    @Test(arguments: CanvasPreset.all)
    func everyLayerStaysOnTheCanvas(_ preset: CanvasPreset) {
        let d = pin().resized(width: preset.width, height: preset.height)
        #expect(d.layersOutsideCanvas.isEmpty, "\(preset.name): \(d.layersOutsideCanvas)")
    }

    @Test(arguments: CanvasPreset.all)
    func aLayerOnAnEdgeStaysOnThatEdge(_ preset: CanvasPreset) {
        let d = pin().resized(width: preset.width, height: preset.height)
        #expect(layer(d, "Shade").y == 0, "the top shade left the top in \(preset.name)")
        let footer = layer(d, "Footer")
        #expect(abs(footer.y + footer.height - Double(preset.height)) <= 1, "the footer left the bottom in \(preset.name)")
    }

    @Test(arguments: CanvasPreset.all)
    func aGroupMovesAsOnePiece(_ preset: CanvasPreset) {
        let d = pin().resized(width: preset.width, height: preset.height)
        let tag = layer(d, "Price tag"), cta = layer(d, "Call to action"), price = layer(d, "Price")
        for label in [cta, price] {
            #expect(label.x >= tag.x - 1 && label.x + label.width <= tag.x + tag.width + 1, "\(label.name) left its button in \(preset.name)")
            #expect(label.y >= tag.y - 1 && label.y + label.height <= tag.y + tag.height + 1, "\(label.name) left its button in \(preset.name)")
        }
        // The label sits at the same scaled offset inside the pill.
        let s = min(Double(preset.width) / 1000, Double(preset.height) / 1500)
        #expect(abs((cta.x - tag.x) - 160 * s) <= 1)
    }

    @Test func fullBleedPhotoFillsEverySize() {
        for p in CanvasPreset.all {
            let photo = layer(pin().resized(width: p.width, height: p.height), "Photo")
            #expect(photo.x == 0 && photo.y == 0 && photo.width == Double(p.width) && photo.height == Double(p.height))
        }
    }
}

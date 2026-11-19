import CoreGraphics
import Foundation

/// What a brand kit contributes to a design: palette, fonts, and logo.
/// Templates refer to these by role ("brand.0", "headline", logo slot), so
/// changing the kit restyles every template that uses it.
public struct BrandStyle: Sendable, Equatable {
    public var palette: [RGBA]
    public var headlineFont: String
    public var bodyFont: String
    public var logoPath: String?
    public init(palette: [RGBA], headlineFont: String, bodyFont: String, logoPath: String? = nil) {
        self.palette = palette; self.headlineFont = headlineFont; self.bodyFont = bodyFont; self.logoPath = logoPath
    }

    /// "brand.2" → palette[2]. Unknown roles give nil, so the fixed color stays.
    public func color(_ role: String?) -> RGBA? {
        guard let role, role.hasPrefix("brand."), let i = Int(role.dropFirst(6)), palette.indices.contains(i) else { return nil }
        return palette[i]
    }

    public func font(_ role: String?) -> String? {
        switch role {
        case "headline": headlineFont
        case "body": bodyFont
        default: nil
        }
    }
}

extension CreativeDocument {
    /// The document with every brand role resolved: colors, fonts, logo.
    public func applyingBrand(_ brand: BrandStyle) -> CreativeDocument {
        var copy = self
        copy.layers = layers.map { layer in
            var l = layer
            switch l.content {
            case .text(var t):
                if let c = brand.color(t.colorRole) { t.color = RGBA(c.r, c.g, c.b, t.color.a) }
                if let f = brand.font(t.fontRole) { t.fontName = f }
                l.content = .text(t)
            case .shape(var s):
                if let c = brand.color(s.fillRole) { s.fill = RGBA(c.r, c.g, c.b, s.fill.a) }
                if let c = brand.color(s.gradientRole) { s.gradientTo = c }
                l.content = .shape(s)
            case .image(var i):
                if i.role == "logo", let logo = brand.logoPath { i.path = logo }
                l.content = .image(i)
            }
            return l
        }
        return copy
    }

    /// Fills every photo slot with `path` (bulk: one design per asset).
    public func withPhoto(_ path: String) -> CreativeDocument {
        var copy = self
        copy.layers = layers.map { layer in
            var l = layer
            if case .image(var i) = l.content, i.role == "photo" {
                i.path = path
                l.content = .image(i)
            }
            return l
        }
        return copy
    }

    public var hasPhotoSlot: Bool {
        layers.contains { if case .image(let i) = $0.content { i.role == "photo" } else { false } }
    }

    /// Smart resize to another canvas: positions scale per axis, sizes scale
    /// uniformly (so text and logos never stretch), and full-bleed layers stay
    /// full-bleed. Text stays live; the result is a new editable document.
    public func resized(width newW: Int, height newH: Int, name: String? = nil) -> CreativeDocument {
        let sx = Double(newW) / Double(width), sy = Double(newH) / Double(height)
        let s = min(sx, sy)
        var copy = self
        copy.width = newW
        copy.height = newH
        if let name { copy.name = name }
        copy.layers = layers.map { layer in
            var l = layer
            let fullBleedX = layer.x <= 1 && layer.width >= Double(width) - 1
            let fullBleedY = layer.y <= 1 && layer.height >= Double(height) - 1
            if fullBleedX && fullBleedY {
                l.x = 0; l.y = 0; l.width = Double(newW); l.height = Double(newH)
                return l
            }
            // Keep each layer's center in the same relative place, size scaled uniformly.
            let cx = (layer.x + layer.width / 2) * sx, cy = (layer.y + layer.height / 2) * sy
            l.width = fullBleedX ? Double(newW) : layer.width * s
            l.height = fullBleedY ? Double(newH) : layer.height * s
            // Wide text boxes keep their share of the canvas width so lines do not wrap more.
            if case .text = layer.content, !fullBleedX {
                l.width = min(Double(newW) - 2 * max(0, layer.x * sx), layer.width * sx)
            }
            l.x = fullBleedX ? 0 : (cx - l.width / 2).rounded()
            l.y = fullBleedY ? 0 : (cy - l.height / 2).rounded()
            switch l.content {
            case .text(var t):
                t.size = (t.size * s).rounded()
                if let k = t.tracking { t.tracking = k * s }
                l.content = .text(t)
            case .shape(var sh):
                sh.cornerRadius *= s
                l.content = .shape(sh)
            case .image(var i):
                i.cornerRadius = i.cornerRadius.map { $0 * s }
                l.content = .image(i)
            }
            return l
        }
        return copy
    }

    /// Layers whose frame leaves the canvas (shown as warnings after a resize).
    public var layersOutsideCanvas: [String] {
        layers.filter { $0.x < -1 || $0.y < -1 || $0.x + $0.width > Double(width) + 1 || $0.y + $0.height > Double(height) + 1 }.map(\.name)
    }
}

/// Canvas sizes for "Generate all sizes", from the design's smart-resize strip.
public struct CanvasPreset: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let width: Int
    public let height: Int
    public var ratio: String

    public static let all: [CanvasPreset] = [
        CanvasPreset(id: "pin", name: "Pinterest Pin", platform: "pinterest", width: 1000, height: 1500, ratio: "2:3"),
        CanvasPreset(id: "fb", name: "Facebook Feed", platform: "facebook", width: 1200, height: 628, ratio: "1.91:1"),
        CanvasPreset(id: "x", name: "X Post", platform: "x", width: 1600, height: 900, ratio: "16:9"),
        CanvasPreset(id: "li", name: "LinkedIn", platform: "linkedin", width: 1200, height: 1200, ratio: "1:1"),
        CanvasPreset(id: "story", name: "Story", platform: "instagram", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "ig", name: "Instagram Portrait", platform: "instagram", width: 1080, height: 1350, ratio: "4:5"),  // grid: ok platform pixel size
    ]
}

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
            case .video:
                break
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
    ///
    /// Layers that touch an edge stay on that edge (a top shade stays at the top),
    /// and a group (a button and its label) moves and scales as one piece, so its
    /// parts keep their places relative to each other.
    public func resized(width newW: Int, height newH: Int, name: String? = nil) -> CreativeDocument {
        let oldW = Double(width), oldH = Double(height)
        let newWidth = Double(newW), newHeight = Double(newH)
        let sx = newWidth / oldW, sy = newHeight / oldH
        let s = min(sx, sy)
        var copy = self
        copy.width = newW
        copy.height = newH
        if let name { copy.name = name }

        /// Where a box of the old canvas goes: edges stay on edges, otherwise the center keeps its relative place.
        func place(start: Double, length: Double, newLength: Double, old: Double, new: Double, scale: Double) -> Double {
            if start <= 1 { return 0 }
            if start + length >= old - 1 { return (new - newLength).rounded() }
            return ((start + length / 2) * scale - newLength / 2).rounded()
        }

        // Each group's bounding box in the old canvas.
        var boxes: [String: (x: Double, y: Double, maxX: Double, maxY: Double)] = [:]
        for l in layers {
            guard let g = l.group else { continue }
            let b = boxes[g] ?? (l.x, l.y, l.x + l.width, l.y + l.height)
            boxes[g] = (min(b.x, l.x), min(b.y, l.y), max(b.maxX, l.x + l.width), max(b.maxY, l.y + l.height))
        }

        copy.layers = layers.map { layer in
            var l = layer
            let fullBleedX = layer.x <= 1 && layer.width >= oldW - 1
            let fullBleedY = layer.y <= 1 && layer.height >= oldH - 1
            if fullBleedX && fullBleedY {
                l.x = 0; l.y = 0; l.width = newWidth; l.height = newHeight
                return l
            }
            if let g = layer.group, let box = boxes[g] {
                // The group is placed like one layer; members keep their offsets, scaled uniformly.
                let bw = box.maxX - box.x, bh = box.maxY - box.y
                let gx = place(start: box.x, length: bw, newLength: bw * s, old: oldW, new: newWidth, scale: sx)
                let gy = place(start: box.y, length: bh, newLength: bh * s, old: oldH, new: newHeight, scale: sy)
                l.x = (gx + (layer.x - box.x) * s).rounded()
                l.y = (gy + (layer.y - box.y) * s).rounded()
                l.width = layer.width * s
                l.height = layer.height * s
            } else {
                l.width = fullBleedX ? newWidth : layer.width * s
                l.height = fullBleedY ? newHeight : layer.height * s
                // Wide text boxes keep their share of the canvas width so lines do not wrap more.
                if case .text = layer.content, !fullBleedX {
                    l.width = min(newWidth - 2 * max(0, layer.x * sx), layer.width * sx)
                }
                l.x = fullBleedX ? 0 : place(start: layer.x, length: layer.width, newLength: l.width, old: oldW, new: newWidth, scale: sx)
                l.y = fullBleedY ? 0 : place(start: layer.y, length: layer.height, newLength: l.height, old: oldH, new: newHeight, scale: sy)
            }
            switch l.content {
            case .text(var t):
                t.size = (t.size * s).rounded()
                if let k = t.tracking { t.tracking = k * s }
                l.content = .text(t)
            case .shape(var sh):
                sh.cornerRadius *= s
                l.content = .shape(sh)
            case .video(var v):
                v.cornerRadius = v.cornerRadius.map { $0 * s }
                l.content = .video(v)
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

    /// Video canvases. Every short-video platform takes 9:16 at 1080 × 1920.
    public static let video: [CanvasPreset] = [
        CanvasPreset(id: "tiktok", name: "TikTok", platform: "tiktok", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "reels", name: "Instagram Reels", platform: "instagram", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "shorts", name: "YouTube Shorts", platform: "youtube", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "pin-video", name: "Pinterest Video", platform: "pinterest", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "fb-reel", name: "Facebook Reels", platform: "facebook", width: 1080, height: 1920, ratio: "9:16"),
        CanvasPreset(id: "ig-feed-video", name: "Instagram Feed Video", platform: "instagram", width: 1080, height: 1350, ratio: "4:5"),  // grid: ok platform pixel size
        CanvasPreset(id: "square-video", name: "Square Video (X, LinkedIn, Facebook)", platform: "x", width: 1080, height: 1080, ratio: "1:1"),
        CanvasPreset(id: "youtube", name: "YouTube", platform: "youtube", width: 1920, height: 1080, ratio: "16:9"),
    ]
}

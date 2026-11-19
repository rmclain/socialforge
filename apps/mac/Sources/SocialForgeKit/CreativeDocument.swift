import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// A non-destructive design: canvas, background, and layers. Saved as JSON.
/// Text stays text: it is drawn with real fonts at export, never baked into
/// the background.
public struct CreativeDocument: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version = CreativeDocument.formatVersion
    public var name: String
    public var width: Int
    public var height: Int
    public var background: RGBA
    public var layers: [CreativeLayer]
    /// Seconds. Set for a video design; nil for a still image.
    public var duration: Double?
    /// Music and sound under the video, mixed with the sound of video layers.
    public var audio: [AudioTrack]?

    /// True when the design exports as a video (it has a length).
    public var isVideo: Bool { (duration ?? 0) > 0 }
    public var audioTracks: [AudioTrack] {
        get { audio ?? [] }
        set { audio = newValue.isEmpty ? nil : newValue }
    }

    public init(name: String, width: Int, height: Int, background: RGBA = .white, layers: [CreativeLayer] = []) {
        self.name = name; self.width = width; self.height = height; self.background = background; self.layers = layers
    }

    public static func from(json: Data) throws -> CreativeDocument { try JSONDecoder().decode(Self.self, from: json) }
    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Template variables used anywhere in the text: ["title", "price"].
    public var variables: [String] {
        var seen: [String] = []
        for layer in layers {
            if case .text(let t) = layer.content {
                for v in TemplateText.variables(in: t.text) where !seen.contains(v) { seen.append(v) }
            }
        }
        return seen
    }

    /// A copy with every {{variable}} replaced from `values`.
    public func filled(_ values: [String: String]) -> CreativeDocument {
        var copy = self
        copy.layers = layers.map { layer in
            var l = layer
            if case .text(var t) = l.content {
                t.text = TemplateText.fill(t.text, values)
                l.content = .text(t)
            }
            return l
        }
        return copy
    }

    /// Fonts the document uses that are not installed. Export refuses to
    /// substitute them silently.
    public var missingFonts: [String] {
        var out: [String] = []
        for layer in layers {
            if case .text(let t) = layer.content, !FontCheck.isInstalled(t.fontName), !out.contains(t.fontName) {
                out.append(t.fontName)
            }
        }
        return out
    }
}

public struct RGBA: Codable, Sendable, Equatable, Hashable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var hex: UInt32 { UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255) }
}

public struct CreativeLayer: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Frame in canvas points, origin top left.
    public var x: Double, y: Double, width: Double, height: Double
    public var opacity: Double
    public var isLocked: Bool
    public var isHidden: Bool
    /// Layers with the same group name move, lock, and hide together.
    public var group: String?
    /// In a video: the second the layer appears, and the second it goes away. nil = the whole video.
    public var start: Double?
    public var end: Double?
    public var content: Content

    /// Whether the layer shows at `time` seconds (nil time = a still render: always).
    public func isVisible(at time: Double?) -> Bool {
        guard let time else { return true }
        if let start, time < start { return false }
        if let end, time >= end { return false }
        return true
    }

    public enum Content: Codable, Sendable, Equatable {
        case image(ImageLayer)
        case text(TextLayer)
        case shape(ShapeLayer)
        case video(VideoLayer)
    }

    public init(id: UUID = UUID(), name: String, x: Double, y: Double, width: Double, height: Double,
                opacity: Double = 1, isLocked: Bool = false, isHidden: Bool = false, group: String? = nil,
                start: Double? = nil, end: Double? = nil, content: Content) {
        self.id = id; self.name = name; self.x = x; self.y = y; self.width = width; self.height = height
        self.opacity = opacity; self.isLocked = isLocked; self.isHidden = isHidden; self.group = group
        self.start = start; self.end = end; self.content = content
    }

    public var kind: String {
        switch content {
        case .image: "Image"
        case .text: "Text"
        case .shape: "Shape"
        case .video: "Video"
        }
    }
}

/// A video clip on the canvas. Its sound is mixed in unless muted.
public struct VideoLayer: Codable, Sendable, Equatable {
    public var path: String
    public var mode: FitMode
    public var cornerRadius: Double?
    public var focusX: Double?
    public var focusY: Double?
    /// Seconds skipped at the start of the clip.
    public var trimStart: Double
    /// Length of the clip file in seconds (read when it was added).
    public var clipDuration: Double
    public var volume: Double
    public var muted: Bool
    /// Starts over when it reaches the end, until the layer's end.
    public var loop: Bool
    public init(path: String, mode: FitMode = .fill, cornerRadius: Double? = nil, focusX: Double? = nil, focusY: Double? = nil,
                trimStart: Double = 0, clipDuration: Double, volume: Double = 1, muted: Bool = false, loop: Bool = false) {
        self.path = path; self.mode = mode; self.cornerRadius = cornerRadius; self.focusX = focusX; self.focusY = focusY
        self.trimStart = trimStart; self.clipDuration = clipDuration; self.volume = volume; self.muted = muted; self.loop = loop
    }
    public var focus: CGPoint { CGPoint(x: focusX ?? 0.5, y: focusY ?? 0.5) }

    /// The second in the clip file shown at `local` seconds after the layer starts, or nil after a non-looping clip ended.
    public func clipTime(at local: Double) -> Double? {
        let usable = max(0, clipDuration - trimStart)
        guard usable > 0, local >= 0 else { return local < 0 ? nil : trimStart }
        if local < usable { return trimStart + local }
        if loop { return trimStart + local.truncatingRemainder(dividingBy: usable) }
        // Hold the last frame.
        return trimStart + max(0, usable - 0.001)
    }
}

/// A music or sound track in a video design.
public struct AudioTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    /// Second of the video where the track starts.
    public var start: Double
    /// Seconds skipped at the start of the file.
    public var trimStart: Double
    public var fileDuration: Double
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public var loop: Bool
    public init(id: UUID = UUID(), name: String, path: String, start: Double = 0, trimStart: Double = 0, fileDuration: Double,
                volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 1, loop: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.start = start; self.trimStart = trimStart
        self.fileDuration = fileDuration; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.loop = loop
    }
}

public struct ImageLayer: Codable, Sendable, Equatable {
    /// Path of the image file in managed storage. Empty for an unfilled slot.
    public var path: String
    public var mode: FitMode
    /// "photo": filled per asset in bulk use. "logo": filled from the brand kit. nil: a fixed image.
    public var role: String?
    public var cornerRadius: Double?
    /// Where Fill crops around, 0...1 from the top left (smart crop sets it). nil = center.
    public var focusX: Double?
    public var focusY: Double?
    public init(path: String, mode: FitMode = .fill, role: String? = nil, cornerRadius: Double? = nil, focusX: Double? = nil, focusY: Double? = nil) {
        self.path = path; self.mode = mode; self.role = role; self.cornerRadius = cornerRadius; self.focusX = focusX; self.focusY = focusY
    }
    public var focus: CGPoint { CGPoint(x: focusX ?? 0.5, y: focusY ?? 0.5) }
}

public struct TextLayer: Codable, Sendable, Equatable {
    public enum Alignment: String, Codable, Sendable, CaseIterable { case leading, center, trailing }
    public var text: String
    /// PostScript or family name, such as "InstrumentSerif-Regular" or "Helvetica Neue".
    public var fontName: String
    public var size: Double
    public var lineHeight: Double
    public var color: RGBA
    public var alignment: Alignment
    public var shadow: Bool
    /// "brand.N": palette color N of the brand kit. nil: the fixed `color`.
    public var colorRole: String?
    /// "headline" or "body": the brand kit's font. nil: the fixed `fontName`.
    public var fontRole: String?
    /// Extra spacing between letters, in points (the design's spaced wordmark).
    public var tracking: Double?
    public var uppercase: Bool?
    public init(text: String, fontName: String, size: Double, lineHeight: Double = 1.1, color: RGBA = .black,
                alignment: Alignment = .leading, shadow: Bool = false, colorRole: String? = nil, fontRole: String? = nil,
                tracking: Double? = nil, uppercase: Bool? = nil) {
        self.text = text; self.fontName = fontName; self.size = size; self.lineHeight = lineHeight
        self.color = color; self.alignment = alignment; self.shadow = shadow
        self.colorRole = colorRole; self.fontRole = fontRole; self.tracking = tracking; self.uppercase = uppercase
    }

    /// The text as drawn: uppercase when asked.
    public var displayText: String { uppercase == true ? text.uppercased() : text }
}

public struct ShapeLayer: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case rectangle, ellipse }
    public var kind: Kind
    public var fill: RGBA
    /// A second color makes a top-to-bottom gradient.
    public var gradientTo: RGBA?
    public var cornerRadius: Double
    public var border: RGBA?
    public var borderWidth: Double
    /// "brand.N" for the fill (and gradient end with `gradientRole`).
    public var fillRole: String?
    public var gradientRole: String?
    public var shadow: Bool?
    public init(kind: Kind, fill: RGBA, gradientTo: RGBA? = nil, cornerRadius: Double = 0, border: RGBA? = nil, borderWidth: Double = 0,
                fillRole: String? = nil, gradientRole: String? = nil, shadow: Bool? = nil) {
        self.kind = kind; self.fill = fill; self.gradientTo = gradientTo; self.cornerRadius = cornerRadius
        self.border = border; self.borderWidth = borderWidth
        self.fillRole = fillRole; self.gradientRole = gradientRole; self.shadow = shadow
    }
}

public enum TemplateText {
    private static var pattern: Regex<(Substring, Substring)> { /\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/ }

    public static func variables(in text: String) -> [String] {
        text.matches(of: pattern).map { String($0.output.1) }
    }

    /// Replaces {{name}} with values[name]. Unknown variables are left as they are,
    /// so a missing value is visible instead of silently blank.
    public static func fill(_ text: String, _ values: [String: String]) -> String {
        text.replacing(pattern) { match in values[String(match.output.1)] ?? String(match.output.0) }
    }
}

public enum FontCheck {
    public static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let ps = CTFontCopyPostScriptName(font) as String
        let family = CTFontCopyFamilyName(font) as String
        let full = CTFontCopyFullName(font) as String
        return [ps, family, full].contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum CreativeRenderer {
    public enum RenderError: Error, Equatable {
        case missingFonts([String])
        case missingImage(String)
        case cannotDraw
    }

    /// Renders at `scale` × the canvas size. Fails on missing fonts unless
    /// `allowFallbackFonts` (used for on-screen previews only).
    /// `time` (seconds) shows only the layers visible then; `frames` holds each video layer's picture
    /// at that time (a video layer without one draws a dark placeholder).
    public static func render(_ doc: CreativeDocument, scale: Double = 1, allowFallbackFonts: Bool = false,
                              time: Double? = nil, frames: [UUID: CGImage] = [:]) throws(RenderError) -> CGImage {
        if !allowFallbackFonts, !doc.missingFonts.isEmpty { throw .missingFonts(doc.missingFonts) }
        let w = Int(Double(doc.width) * scale), h = Int(Double(doc.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .cannotDraw }
        try draw(doc, in: ctx, pixelHeight: h, scale: scale, time: time, frames: frames, images: nil)
        guard let image = ctx.makeImage() else { throw .cannotDraw }
        return image
    }

    /// Draws into any bitmap context (a video frame's pixel buffer, for example). `images` caches decoded
    /// image layers across frames.
    public static func draw(_ doc: CreativeDocument, in ctx: CGContext, pixelHeight h: Int, scale: Double,
                            time: Double?, frames: [UUID: CGImage], images: ImageCache?) throws(RenderError) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Work in canvas points with the origin at the top left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(doc.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: doc.width, height: doc.height))
        for layer in doc.layers where !layer.isHidden && layer.isVisible(at: time) {
            let frame = CGRect(x: layer.x, y: layer.y, width: layer.width, height: layer.height)
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            switch layer.content {
            case .image(let img):
                if img.path.isEmpty {
                    // An unfilled photo or logo slot draws nothing.
                    ctx.restoreGState()
                    continue
                }
                guard let image = images?.image(img.path) ?? ImageTransformer.load(URL(fileURLWithPath: img.path)) else {
                    ctx.restoreGState()
                    throw .missingImage(img.path)
                }
                drawPicture(image, in: frame, mode: img.mode, focus: img.focus, cornerRadius: img.cornerRadius, ctx: ctx)
            case .video(let v):
                if let image = frames[layer.id] {
                    drawPicture(image, in: frame, mode: v.mode, focus: v.focus, cornerRadius: v.cornerRadius, ctx: ctx)
                } else {
                    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
                    ctx.fill(frame)
                }
            case .shape(let shape):
                let path: CGPath = shape.kind == .ellipse
                    ? CGPath(ellipseIn: frame, transform: nil)
                    : CGPath(roundedRect: frame, cornerWidth: min(shape.cornerRadius, frame.width / 2),
                             cornerHeight: min(shape.cornerRadius, frame.height / 2), transform: nil)
                if shape.shadow == true {
                    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
                }
                ctx.addPath(path)
                if let to = shape.gradientTo,
                   let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [shape.fill.cgColor, to.cgColor] as CFArray, locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.clip()
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: frame.midX, y: frame.minY), end: CGPoint(x: frame.midX, y: frame.maxY), options: [])
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(shape.fill.cgColor)
                    ctx.fillPath()
                }
                if let border = shape.border, shape.borderWidth > 0 {
                    ctx.addPath(path)
                    ctx.setStrokeColor(border.cgColor)
                    ctx.setLineWidth(shape.borderWidth)
                    ctx.strokePath()
                }
            case .text(let text):
                drawText(text, in: frame, ctx: ctx)
            }
            ctx.restoreGState()
        }
    }

    static func drawPicture(_ image: CGImage, in frame: CGRect, mode: FitMode, focus: CGPoint, cornerRadius: Double?, ctx: CGContext) {
        let (draw, _) = ImageTransformer.layout(source: CGSize(width: image.width, height: image.height), canvas: frame.size, mode: mode, focus: focus)
        if let r = cornerRadius, r > 0 {
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: min(r, frame.width / 2), cornerHeight: min(r, frame.height / 2), transform: nil))
            ctx.clip()
        } else {
            ctx.clip(to: frame)
        }
        // Flip back so the image is upright.
        ctx.translateBy(x: frame.minX + draw.minX, y: frame.minY + draw.minY + draw.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: draw.size))
    }

    public static func attributed(_ t: TextLayer) -> NSAttributedString {
        let font = CTFontCreateWithName(t.fontName as CFString, t.size, nil)
        var align: CTTextAlignment = switch t.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var lineHeight = CGFloat(t.size * t.lineHeight)
        let settings: [CTParagraphStyleSetting] = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &lineHeight) { l in
                [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                 CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!),
                 CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!)]
            }
        }
        let para = CTParagraphStyleCreate(settings, settings.count)
        var attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: t.color.cgColor,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: para,
        ]
        if let tracking = t.tracking, tracking != 0 { attrs[kCTKernAttributeName as NSAttributedString.Key] = tracking }
        return NSAttributedString(string: t.displayText, attributes: attrs)
    }

    private static func drawText(_ t: TextLayer, in frame: CGRect, ctx: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(t))
        ctx.saveGState()
        if t.shadow { ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: t.size * 0.15, color: CGColor(gray: 0, alpha: 0.45)) }
        // Core Text draws bottom-up: flip the frame back.
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(ctFrame, ctx)
        ctx.restoreGState()
    }

    public static func export(_ doc: CreativeDocument, to url: URL, format: OutputFormat = .png, quality: Double = 0.92) throws -> URL {
        let image = try render(doc)
        try ImageTransformer.write(image, to: url, format: format, quality: quality)
        return url
    }
}

/// Decoded image layers, kept across the frames of a video export.
public final class ImageCache {
    private var images: [String: CGImage] = [:]
    public init() {}
    public func image(_ path: String) -> CGImage? {
        if let hit = images[path] { return hit }
        let loaded = ImageTransformer.load(URL(fileURLWithPath: path))
        images[path] = loaded
        return loaded
    }
}

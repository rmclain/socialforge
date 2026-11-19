import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A reusable export preset: "Pinterest 2:3, 1000 × 1500, JPEG 85".
public struct ExportPreset: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String?
    public var width: Int
    public var height: Int
    public var mode: FitMode
    public var format: OutputFormat
    public var quality: Double
    public var stripMetadata: Bool
    /// Background for Fit padding and for flattening transparency to JPEG, 0xRRGGBB.
    public var background: UInt32

    public init(id: String, name: String, platform: String?, width: Int, height: Int, mode: FitMode = .fill,
                format: OutputFormat = .jpeg, quality: Double = 0.85, stripMetadata: Bool = true, background: UInt32 = 0xFFFFFF) {
        self.id = id; self.name = name; self.platform = platform; self.width = width; self.height = height
        self.mode = mode; self.format = format; self.quality = quality; self.stripMetadata = stripMetadata; self.background = background
    }

    public static let builtIn: [ExportPreset] = [
        ExportPreset(id: "pinterest-2x3", name: "Pinterest Pin 2:3", platform: "pinterest", width: 1000, height: 1500),
        ExportPreset(id: "instagram-square", name: "Instagram square", platform: "instagram", width: 1080, height: 1080),
        ExportPreset(id: "instagram-portrait", name: "Instagram portrait 4:5", platform: "instagram", width: 1080, height: 1350),  // grid: ok platform pixel size
        ExportPreset(id: "facebook-feed", name: "Facebook feed 4:5", platform: "facebook", width: 1080, height: 1350),  // grid: ok platform pixel size
        ExportPreset(id: "linkedin-graphic", name: "LinkedIn 1.91:1", platform: "linkedin", width: 1200, height: 627),  // grid: ok platform pixel size
        ExportPreset(id: "x-image", name: "X 16:9", platform: "x", width: 1600, height: 900),
    ]
}

public enum FitMode: String, Sendable, Codable, CaseIterable {
    /// Scale to cover the canvas and crop the overflow around the focal point.
    case fill
    /// Scale to fit inside the canvas and pad with the background.
    case fit
}

public enum OutputFormat: String, Sendable, Codable, CaseIterable {
    case jpeg, png, heic

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        }
    }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

public struct TransformResult: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let bytes: Int
    /// The part of the source that was kept, in source pixels (Fill), or the whole source (Fit).
    public let sourceCrop: CGRect
}

public enum ImageTransformer {
    public enum TransformError: Error, Equatable { case unreadable, cannotWrite }

    /// Where the drawn image lands on the canvas, and which part of the source it covers.
    /// Never stretches: one scale for both axes.
    public static func layout(source: CGSize, canvas: CGSize, mode: FitMode,
                              focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> (draw: CGRect, crop: CGRect) {
        let sx = canvas.width / source.width, sy = canvas.height / source.height
        switch mode {
        case .fit:
            let s = min(sx, sy)
            let w = source.width * s, h = source.height * s
            return (CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h),
                    CGRect(origin: .zero, size: source))
        case .fill:
            let s = max(sx, sy)
            let w = source.width * s, h = source.height * s
            // Center the focal point, clamped so no empty edge shows.
            let x = min(0, max(canvas.width - w, canvas.width / 2 - focus.x * w))
            let y = min(0, max(canvas.height - h, canvas.height / 2 - (1 - focus.y) * h))
            let crop = CGRect(x: -x / s, y: (h + y - canvas.height) / s, width: canvas.width / s, height: canvas.height / s)
            return (CGRect(x: x, y: y, width: w, height: h), crop)
        }
    }

    /// Decodes `source` with its orientation applied, converted to sRGB.
    public static func load(_ source: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // A full-size "thumbnail" with the transform applied gives an upright image.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Writes a new file; the source is only read.
    public static func apply(_ preset: ExportPreset, to source: URL, output: URL,
                             focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws(TransformError) -> TransformResult {
        guard let image = load(source) else { throw .unreadable }
        let canvas = CGSize(width: preset.width, height: preset.height)
        let (draw, crop) = layout(source: CGSize(width: image.width, height: image.height), canvas: canvas, mode: preset.mode, focus: focus)
        let opaque = preset.format == .jpeg
        guard let ctx = CGContext(data: nil, width: preset.width, height: preset.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else { throw .cannotWrite }
        ctx.interpolationQuality = .high
        if opaque || preset.mode == .fit {
            let b = preset.background
            ctx.setFillColor(CGColor(srgbRed: CGFloat((b >> 16) & 0xFF) / 255, green: CGFloat((b >> 8) & 0xFF) / 255,
                                     blue: CGFloat(b & 0xFF) / 255, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: canvas))
        }
        ctx.draw(image, in: draw)
        guard let out = ctx.makeImage() else { throw .cannotWrite }
        try write(out, to: output, format: preset.format, quality: preset.quality,
                  metadataFrom: preset.stripMetadata ? nil : source)
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return TransformResult(url: output, width: preset.width, height: preset.height, bytes: bytes, sourceCrop: crop)
    }

    public static func write(_ image: CGImage, to url: URL, format: OutputFormat, quality: Double,
                             metadataFrom: URL? = nil) throws(TransformError) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { throw .cannotWrite }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let metadataFrom, let src = CGImageSourceCreateWithURL(metadataFrom as CFURL, nil),
           let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let v = meta[key] { props[key] = v }
            }
            // Pixels are already upright.
            props[kCGImagePropertyOrientation] = 1
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw .cannotWrite }
    }
}

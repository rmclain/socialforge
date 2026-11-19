import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// On-device image operations for Creative Studio's Transform panel. All use
/// Apple frameworks (Vision, Core Image); nothing leaves the Mac.
public enum ImageOps {
    public enum OpError: Error, Equatable, LocalizedError {
        case unreadable, noSubject, failed(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable: "The image could not be read."
            case .noSubject: "No clear subject was found to cut out."
            case .failed(let why): why
            }
        }
    }

    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func load(_ url: URL) throws(OpError) -> CGImage {
        guard let img = ImageTransformer.load(url) else { throw .unreadable }
        return img
    }

    static func png(_ image: CIImage) throws(OpError) -> Data {
        guard let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw .failed("Could not encode the result.")
        }
        return data
    }

    /// Cuts the main subject out onto transparency (Vision foreground instance mask).
    public static func removeBackground(_ url: URL) throws(OpError) -> Data {
        let cg = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do { try handler.perform([request]) } catch { throw .failed("Vision could not analyze the image: \(error.localizedDescription)") }
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw .noSubject }
        let mask: CVPixelBuffer
        do { mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) } catch {
            throw .failed("Vision could not build a mask: \(error.localizedDescription)")
        }
        let original = CIImage(cgImage: cg)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = original
        blend.backgroundImage = CIImage.empty().cropped(to: original.extent)
        blend.maskImage = CIImage(cvPixelBuffer: mask)
        guard let out = blend.outputImage else { throw .failed("Could not apply the mask.") }
        return try png(out.cropped(to: original.extent))
    }

    /// Doubles the size with Lanczos resampling and light sharpening. Not AI super-resolution.
    public static func upscale2x(_ url: URL) throws(OpError) -> Data {
        let image = CIImage(cgImage: try load(url))
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = 2
        scale.aspectRatio = 1
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = scale.outputImage
        sharpen.sharpness = 0.3
        guard let out = sharpen.outputImage else { throw .failed("Could not resize.") }
        return try png(out.cropped(to: CGRect(x: 0, y: 0, width: image.extent.width * 2, height: image.extent.height * 2)))
    }

    /// The center of the most eye-catching region, 0...1 from the top left (Vision attention saliency).
    public static func saliencyFocus(_ url: URL) throws(OpError) -> CGPoint {
        let cg = try load(url)
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { throw .failed(error.localizedDescription) }
        guard let box = request.results?.first?.salientObjects?.first?.boundingBox else { return CGPoint(x: 0.5, y: 0.5) }
        // Vision boxes are normalized with the origin at the bottom left.
        return CGPoint(x: box.midX, y: 1 - box.midY)
    }

    /// Tones the image toward a brand color (Core Image color monochrome), keeping alpha.
    public static func tint(_ url: URL, color: RGBA, intensity: Double = 0.55) throws(OpError) -> Data {
        let image = CIImage(cgImage: try load(url))
        let f = CIFilter.colorMonochrome()
        f.inputImage = image
        f.color = CIColor(red: color.r, green: color.g, blue: color.b)
        f.intensity = Float(intensity)
        guard let out = f.outputImage else { throw .failed("Could not tint.") }
        return try png(out.cropped(to: image.extent))
    }
}

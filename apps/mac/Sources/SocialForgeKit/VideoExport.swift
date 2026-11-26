@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import Foundation

// Video and audio for Creative Studio: reading a clip's details and frames, and
// exporting a design as an H.264/AAC MP4 (the format TikTok, Reels, Shorts,
// Pinterest, Facebook, X, and LinkedIn all accept).

public struct AVMediaInfo: Sendable, Equatable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var format: String
}

public enum AVProbe {
    /// Length, upright size, and tracks. Nil when AVFoundation cannot read the file.
    public static func info(_ url: URL) async -> AVMediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return nil }
        var w = 0, h = 0
        if let track = videoTracks.first, let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let upright = CGRect(origin: .zero, size: size).applying(transform)
            w = Int(abs(upright.width).rounded()); h = Int(abs(upright.height).rounded())
        }
        return AVMediaInfo(duration: duration.seconds, width: w, height: h, hasVideo: !videoTracks.isEmpty,
                           hasAudio: !audioTracks.isEmpty, format: url.pathExtension.lowercased())
    }

    /// One upright frame, for thumbnails and the Studio preview.
    public static func frame(_ url: URL, at seconds: Double, maxPixel: Int, exact: Bool = false) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        return try? await gen.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }
}

/// Decodes a clip's frames in order, for export. Asking for an earlier time restarts the reader there.
final class VideoFrameReader {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let transform: CGAffineTransform
    private let maxPixel: Int
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, image: CGImage)?
    private var next: (time: Double, buffer: CMSampleBuffer)?
    private var lastAsked = -1.0
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init?(url: URL, maxPixel: Int) async {
        asset = AVURLAsset(url: url)
        guard let t = try? await asset.loadTracks(withMediaType: .video).first,
              let tf = try? await t.load(.preferredTransform) else { return nil }
        track = t; transform = tf; self.maxPixel = maxPixel
    }

    private func start(at seconds: Double) throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        r.add(out)
        r.timeRange = CMTimeRange(start: CMTime(seconds: max(0, seconds - 0.1), preferredTimescale: 600), duration: .positiveInfinity)
        guard r.startReading() else { throw r.error ?? CocoaError(.fileReadCorruptFile) }
        reader = r; output = out; current = nil; next = nil
    }

    /// The frame on screen at `seconds` in the clip.
    func frame(at seconds: Double) throws -> CGImage? {
        if reader == nil || seconds < lastAsked - 0.0001 { try start(at: seconds) }
        lastAsked = seconds
        while true {
            if next == nil, let buffer = output?.copyNextSampleBuffer() {
                next = (CMSampleBufferGetPresentationTimeStamp(buffer).seconds, buffer)
            }
            guard let n = next else { break }
            // Avoid a blank frame 0 when the clip's first PTS starts slightly after 0.
            if current == nil && n.time > seconds + 0.0001 {
                if let image = upright(n.buffer) { current = (n.time, image) }
                next = nil
                break
            }
            guard n.time <= seconds + 0.0001 else { break }
            if let image = upright(n.buffer) { current = (n.time, image) }
            next = nil
        }
        return current?.image
    }

    private func upright(_ buffer: CMSampleBuffer) -> CGImage? {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        var image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let longest = max(image.extent.width, image.extent.height)
        if longest > CGFloat(maxPixel) {
            let s = CGFloat(maxPixel) / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        return Self.context.createCGImage(image, from: image.extent)
    }
}

public enum VideoExporter {
    public enum ExportError: Error, Equatable, CustomStringConvertible {
        case notAVideo, missingFonts([String]), missingFile(String), writer(String)
        public var description: String {
            switch self {
            case .notAVideo: "Give the design a length first (Canvas › Duration)."
            case .missingFonts(let f): "Install or replace these fonts first: \(f.joined(separator: ", "))."
            case .missingFile(let p): "A clip or track is missing: \((p as NSString).lastPathComponent)."
            case .writer(let why): "The video could not be written: \(why)"
            }
        }
    }

    /// Bit rate for H.264 at this size and frame rate (about 9 Mbps for 1080 × 1920 at 30 fps).
    public static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        max(2_000_000, Int(Double(width * height * fps) * 0.15))
    }

    /// Renders every frame with real fonts, mixes the sound of video layers and audio tracks, and writes an MP4.
    /// `progress` gets 0...1. Cancelling the task stops the export and removes the partial file.
    public static func export(_ doc: CreativeDocument, to url: URL, fps: Int = 30,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let duration = doc.duration, duration > 0 else { throw ExportError.notAVideo }
        if !doc.missingFonts.isEmpty { throw ExportError.missingFonts(doc.missingFonts) }
        for case .video(let v) in doc.layers.map(\.content) where !FileManager.default.fileExists(atPath: v.path) { throw ExportError.missingFile(v.path) }
        for t in doc.audioTracks where !FileManager.default.fileExists(atPath: t.path) { throw ExportError.missingFile(t.path) }

        // H.264 needs even sizes.
        let width = doc.width / 2 * 2, height = doc.height / 2 * 2
        let silent = FileManager.default.temporaryDirectory.appending(path: "sf-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: silent) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try await writeFrames(doc, width: width, height: height, fps: fps, duration: duration, to: silent) { progress($0 * 0.85) }
        try Task.checkCancellation()
        try await mux(doc, video: silent, duration: duration, to: url)
        progress(1)
        return url
    }

    private static func writeFrames(_ doc: CreativeDocument, width: Int, height: Int, fps: Int, duration: Double, to url: URL,
                                    progress: (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw ExportError.writer("H.264 at \(width) × \(height) is not supported") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "could not start") }
        writer.startSession(atSourceTime: .zero)

        // One reader per video layer, decoded at about the size it is drawn.
        var readers: [UUID: VideoFrameReader] = [:]
        for layer in doc.layers {
            if case .video(let v) = layer.content {
                let px = Int(max(layer.width, layer.height) * 1.2)
                if let r = await VideoFrameReader(url: URL(fileURLWithPath: v.path), maxPixel: max(256, px)) { readers[layer.id] = r }
            }
        }
        let images = ImageCache()
        let total = max(1, Int((duration * Double(fps)).rounded(.up)))
        let scaleX = Double(width) / Double(doc.width)
        do {
            for i in 0..<total {
                try Task.checkCancellation()
                let t = Double(i) / Double(fps)
                var frames: [UUID: CGImage] = [:]
                for layer in doc.layers where !layer.isHidden && layer.isVisible(at: t) {
                    guard case .video(let v) = layer.content, let reader = readers[layer.id],
                          let clipTime = v.clipTime(at: t - (layer.start ?? 0)) else { continue }
                    if let f = try reader.frame(at: clipTime) { frames[layer.id] = f }
                }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                    if writer.status == .failed { throw ExportError.writer(writer.error?.localizedDescription ?? "failed") }
                }
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw ExportError.writer("no pixel buffer") }
                CVPixelBufferLockBaseAddress(buffer, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                var drawError: CreativeRenderer.RenderError?
                if let ctx {
                    do { try CreativeRenderer.draw(doc, in: ctx, pixelHeight: height, scale: scaleX, time: t, frames: frames, images: images) }
                    catch { drawError = error }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                if let drawError { throw ExportError.writer("\(drawError)") }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                    throw ExportError.writer(writer.error?.localizedDescription ?? "a frame could not be added")
                }
                if i % 10 == 0 { progress(Double(i) / Double(total)) }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "did not finish") }
    }

    /// One piece of sound placed on the video's timeline.
    struct AudioPiece: Equatable {
        var path: String
        var at: Double
        var from: Double
        var length: Double
        var volume: Double
        var fadeIn: Double
        var fadeOut: Double
    }

    /// Where each sound plays, cut to the video's length, with loops unrolled.
    static func audioPlan(_ doc: CreativeDocument, duration: Double) -> [[AudioPiece]] {
        var plans: [[AudioPiece]] = []
        func place(path: String, start: Double, end: Double, trim: Double, fileLength: Double, loop: Bool,
                   volume: Double, fadeIn: Double, fadeOut: Double) {
            let usable = fileLength - trim
            guard usable > 0.01, volume > 0, start < duration else { return }
            let stop = min(end, duration)
            var pieces: [AudioPiece] = []
            var at = max(0, start)
            var from = trim + (at - start)
            while at < stop - 0.01 {
                let length = min(stop - at, trim + usable - from)
                guard length > 0.01 else { break }
                pieces.append(AudioPiece(path: path, at: at, from: from, length: length, volume: volume, fadeIn: 0, fadeOut: 0))
                at += length
                from = trim
                if !loop { break }
            }
            guard !pieces.isEmpty else { return }
            pieces[0].fadeIn = fadeIn
            pieces[pieces.count - 1].fadeOut = fadeOut
            plans.append(pieces)
        }
        for layer in doc.layers where !layer.isHidden {
            guard case .video(let v) = layer.content, !v.muted else { continue }
            place(path: v.path, start: layer.start ?? 0, end: layer.end ?? duration, trim: v.trimStart, fileLength: v.clipDuration,
                  loop: v.loop, volume: v.volume, fadeIn: 0, fadeOut: 0)
        }
        for t in doc.audioTracks {
            place(path: t.path, start: t.start, end: duration, trim: t.trimStart, fileLength: t.fileDuration, loop: t.loop,
                  volume: t.volume, fadeIn: t.fadeIn, fadeOut: t.fadeOut)
        }
        return plans
    }

    /// Adds each planned sound as its own audio track with volume and fades. Returns the mix settings.
    static func addAudio(_ plans: [[AudioPiece]], to comp: AVMutableComposition) async throws -> [AVMutableAudioMixInputParameters] {
        var mixParams: [AVMutableAudioMixInputParameters] = []
        let ts: CMTimeScale = 600
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        for pieces in plans {
            guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let params = AVMutableAudioMixInputParameters(track: track)
            var inserted = false
            for p in pieces {
                let asset = AVURLAsset(url: URL(fileURLWithPath: p.path))
                guard let src = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
                try track.insertTimeRange(CMTimeRange(start: cm(p.from), duration: cm(p.length)), of: src, at: cm(p.at))
                inserted = true
                params.setVolume(Float(p.volume), at: cm(p.at))
                let half = p.length / 2.0
                let safeFadeIn = p.fadeIn > 0 ? min(p.fadeIn, p.fadeOut > 0 ? half : p.length) : 0
                let safeFadeOut = p.fadeOut > 0 ? min(p.fadeOut, p.fadeIn > 0 ? half : p.length) : 0
                if safeFadeIn > 0.001 {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(p.volume),
                                         timeRange: CMTimeRange(start: cm(p.at), duration: cm(safeFadeIn)))
                }
                if safeFadeOut > 0.001 {
                    params.setVolumeRamp(fromStartVolume: Float(p.volume), toEndVolume: 0,
                                         timeRange: CMTimeRange(start: cm(p.at + p.length - safeFadeOut), duration: cm(safeFadeOut)))
                }
            }
            if inserted { mixParams.append(params) } else { comp.removeTrack(track) }
        }
        return mixParams
    }

    /// The design's sound alone, for playing in the Studio preview. Nil when it is silent.
    public static func previewAudio(_ doc: CreativeDocument) async -> (AVComposition, AVAudioMix)? {
        guard let duration = doc.duration, duration > 0 else { return nil }
        let comp = AVMutableComposition()
        guard let params = try? await addAudio(audioPlan(doc, duration: duration), to: comp), !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return (comp, mix)
    }

    private static func mux(_ doc: CreativeDocument, video: URL, duration: Double, to url: URL) async throws {
        let plans = audioPlan(doc, duration: duration)
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let dstVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.writer("the rendered video has no picture")
        }
        let videoLength = try await videoAsset.load(.duration)
        try dstVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoLength), of: srcVideo, at: .zero)

        let mixParams = try await addAudio(plans, to: comp)
        if mixParams.isEmpty {
            // No sound: the rendered file is the result.
            try FileManager.default.moveItem(at: video, to: url)
            return
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.writer("no export session")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams
        session.audioMix = mix
        session.timeRange = CMTimeRange(start: .zero, duration: videoLength)
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: url, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writer(error.localizedDescription)
        }
    }
}

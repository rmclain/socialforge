import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

/// Limits concurrent thumbnail decodes so scrolling a 5,000+ asset library never exhausts threads or memory.
private actor DecodeGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 6) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            running = max(0, running - 1)
        }
    }
}

/// Decoded thumbnails, downsampled to the size they are shown at, with bounded concurrency,
/// in-flight deduplication, memory cost cap, and disk caching in `ManagedStorage.thumbnails`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let gate = DecodeGate(limit: 6)
    private let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "com.socialforge.app/Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func cached(_ path: String, _ px: Int) -> NSImage? { cache.object(forKey: "\(px):\(path)" as NSString) }

    func invalidate(_ path: String) {
        for px in [96, 120, 200, 360, 400, 440, 500, 600] {
            cache.removeObject(forKey: "\(px):\(path)" as NSString)
        }
    }

    func load(_ path: String, _ px: Int) async -> NSImage? {
        let key = "\(px):\(path)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let task = inFlight[key] { return await task.value }

        let diskFile = Self.diskCacheURL(dir: diskDir, key: key)
        let gate = self.gate
        let task = Task<NSImage?, Never> {
            await gate.acquire()
            defer { Task { await gate.release() } }
            guard !Task.isCancelled else { return nil }
            // Check disk thumbnail cache first (fast JPEG read).
            if let diskImg = await Task.detached(priority: .utility, operation: { () -> CGImage? in
                guard FileManager.default.fileExists(atPath: diskFile.path),
                      let src = CGImageSourceCreateWithURL(diskFile as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }).value {
                return NSImage(cgImage: diskImg, size: NSSize(width: diskImg.width, height: diskImg.height))
            }

            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let image: CGImage?
            switch MediaFormats.kind(of: url) {
            case .video?: image = await AVProbe.frame(url, at: 0.5, maxPixel: px)
            case .audio?: image = nil
            default:
                image = await Task.detached(priority: .utility) { () -> CGImage? in
                    ImageProbe.thumbnail(url, maxPixel: px)
                }.value
            }
            guard let image else { return nil }
            // Persist downsampled thumbnail to disk asynchronously for instant future scrolls.
            let imgCopy = image
            Task.detached(priority: .background) {
                if let dest = CGImageDestinationCreateWithURL(diskFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, imgCopy, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
            }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * 4)
            cache.setObject(result, forKey: key as NSString, cost: max(1, cost))
        }
        return result
    }

    private nonisolated static func diskCacheURL(dir: URL, key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appending(path: "\(hex).jpg")
    }
}

struct Thumbnail: View {
    let path: String?
    var maxPixel: Int = 400
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if path == nil {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            } else if let path, MediaFormats.kind(of: URL(fileURLWithPath: path)) == .audio {
                Image(systemName: "waveform").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.accent)
            } else if let path, !FileManager.default.fileExists(atPath: path) {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.amber)
                    Text("Missing").font(DS.caption).foregroundStyle(DS.text3)
                }
            }
            if let path, MediaFormats.kind(of: URL(fileURLWithPath: path)) == .video {
                Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(Space.sm).background(.black.opacity(0.55), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(Space.sm)
            }
        }
        .clipped()
        .task(id: path) {
            guard let path else { image = nil; return }
            image = ThumbnailCache.shared.cached(path, maxPixel)
            if image == nil { image = await ThumbnailCache.shared.load(path, maxPixel) }
        }
        .accessibilityHidden(true)
    }
}

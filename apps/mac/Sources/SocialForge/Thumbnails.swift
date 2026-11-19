import AppKit
import SwiftUI
import SocialForgeKit

/// Decoded thumbnails, downsampled to the size they are shown at, cached in
/// memory with a cost limit so thousands of assets do not fill memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    func cached(_ path: String, _ px: Int) -> NSImage? { cache.object(forKey: "\(px):\(path)" as NSString) }

    func load(_ path: String, _ px: Int) async -> NSImage? {
        if let hit = cached(path, px) { return hit }
        let url = URL(fileURLWithPath: path)
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
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(ns, forKey: "\(px):\(path)" as NSString, cost: image.width * image.height * 4)
        return ns
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

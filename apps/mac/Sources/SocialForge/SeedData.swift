import AVFoundation
import AppKit
import Foundation
import ImageIO
import SwiftData
import SocialForgeKit
import UniformTypeIdentifiers

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an empty
/// store with the design file's "Oak & Ember" run: 30 product images, a CSV,
/// a mock Pinterest account, a brand kit, and a December schedule.
/// Everything here is something a person can create in the app.
@MainActor
enum SeedData {
    static let products: [(String, Double, Int)] = [
        ("Stoneware Mug — Fog", 215, 38), ("Linen Throw — Clay", 30, 120), ("Beeswax Taper Set", 70, 24),
        ("Walnut Serving Board", 45, 86), ("Ceramic Bud Vase", 165, 32), ("Wool Bouclé Cushion", 60, 68),
        ("Amber Glass Diffuser", 50, 44), ("Hand-poured Candle — Cedar", 25, 36), ("Oak Side Table", 55, 240),
        ("Rattan Pendant Lamp", 80, 160), ("Stoneware Dinner Plates", 230, 96), ("Cotton Waffle Towels", 195, 42),
        ("Terracotta Planter", 20, 58), ("Linen Napkins — Sage", 120, 34), ("Brass Candle Holder", 75, 46),
        ("Woven Storage Basket", 65, 52), ("Ceramic Pour-over Set", 200, 72), ("Merino Wool Blanket", 15, 180),
        ("Marble Coaster Set", 240, 28), ("Olive Wood Spoons", 85, 26), ("Glass Carafe", 190, 38),
        ("Speckled Pasta Bowls", 35, 64), ("Linen Apron — Rust", 18, 48), ("Cork Trivet", 40, 18),
        ("Sheepskin Rug", 52, 210), ("Stoneware Teapot", 210, 88), ("Hemp Table Runner", 95, 44),
        ("Ash Wood Stool", 48, 150), ("Ceramic Oil Bottle", 140, 30), ("Wool Felt Ornaments", 5, 22),
    ]

    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        let ctx = model.context
        guard ((try? ctx.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0) == 0 else { return }
        for w in model.workspaces { ctx.delete(w) }
        let ws = Workspace(name: "Oak & Ember", colorHex: 0xFF8A5C)
        ws.voice = "Calm, tactile, never salesy. Avoid exclamation marks."
        ctx.insert(ws)
        let second = Workspace(name: "Northwind Studio", colorHex: 0x5E6AD2)
        second.createdAt = .now.addingTimeInterval(10)
        ctx.insert(second)
        try? ctx.save()
        model.workspaceID = ws.uuid

        // Images and CSV in a /tmp source folder, imported like a person would.
        let src = model.storage.root.deletingLastPathComponent().appending(path: "seed-source", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        var csv = "filename,sku,title,price,url\n"
        for (i, p) in products.enumerated() {
            let name = String(format: "oe-winter-%02d.jpg", i + 1)
            drawProduct(to: src.appending(path: name), hue: p.1, shape: i % 3)
            let slug = p.0.lowercased().replacingOccurrences(of: "é", with: "e")
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            csv += "\(name),OE-\(i + 1),\"\(p.0)\",\(p.2).00,https://oakandember.com/products/\(slug)?utm_source=pinterest&utm_campaign=winter26\n"
        }
        try? csv.write(to: src.appending(path: "products.csv"), atomically: true, encoding: .utf8)

        let kit = BrandKit(workspaceID: ws.uuid, name: "Oak & Ember")
        kit.colors = [0x2A211C, 0xF4EFE8, 0xFF8A5C, 0x7A5C48, 0xC9B8A6]
        kit.headlineFont = FontRegistry.hasInstrumentSerif ? "Instrument Serif" : "Baskerville"
        kit.imageStyle = "Warm natural window light, linen and oak, soft shadows, negative space for a headline"
        kit.bodyFont = "Helvetica Neue"
        kit.voice = ws.voice
        kit.audience = "People furnishing a calm, natural home"
        kit.ctas = ["Shop the collection", "See the details"]
        kit.hashtags = ["#slowliving", "#handmade"]
        ctx.insert(kit)

        let acct = SocialAccount(serverID: "acct_mock_pinterest", workspaceID: ws.uuid, platform: "pinterest", name: "Oak & Ember", status: "connected")
        acct.handle = "@oakandember"
        acct.scopes = ["user_accounts:read", "boards:read", "pins:read", "pins:write"]
        acct.isMock = true
        acct.tokenExpiresAt = .now.addingTimeInterval(25 * 86_400)
        ctx.insert(acct)
        model.boards[acct.serverID] = [API.Board(id: "board_winter", name: "Winter Home Edit", privacy: "PUBLIC"),
                                       API.Board(id: "board_kitchen", name: "Kitchen & Table", privacy: "PUBLIC")]
        try? ctx.save()

        Task {
            let assets = await model.importMedia([src])
            let sorted = assets.sorted { $0.filename < $1.filename }
            model.lastImportSummary = nil
            let bulk = model.bulk
            bulk.assetIDs = sorted.map(\.uuid)
            bulk.accountID = acct.serverID
            bulk.boardID = "board_winter"
            bulk.presetID = nil
            bulk.rule = ScheduleRule(timeZoneID: "America/New_York", start: nextDecemberFirst(), times: [LocalTime(9)])
            bulk.rematch(assets: sorted)
            if let made = try? bulk.createPosts(model: model, assets: sorted, account: acct, board: model.boards[acct.serverID]?.first) {
                for (i, p) in made.enumerated() {
                    switch i {
                    case 0..<3: p.status = .published; p.publishedURL = "https://www.pinterest.com/pin/mock-\(i)"; p.attempts = 1
                    case 3: p.status = .failed; p.lastError = "Pinterest answered 429 Too Many Requests; retries used up"; p.attempts = 5
                    case 4..<20: p.status = .scheduled; p.serverID = "pub_\(i)"
                    case 20..<27: p.status = .approved
                    default: p.status = .needsReview
                    }
                }
                // Shift the first posts into the past so the result states make sense.
                for p in made.prefix(4) { p.scheduledAt = p.scheduledAt.addingTimeInterval(-40 * 86_400) }
            }
            ctx.insert(Design(workspaceID: ws.uuid, document: StudioModel.productPin().withPhoto(sorted.first?.storedPath ?? "")))
            for (text, symbol) in [("Scheduled 16 posts with the publishing service", "clock.badge.checkmark"),
                                   ("Published “Stoneware Mug — Fog”", "checkmark.seal")] {
                ctx.insert(ActivityEntry(workspaceID: ws.uuid, text: text, symbol: symbol))
            }
            try? ctx.save()
            model.mediaSelection = Set(sorted.prefix(6).map(\.uuid))
        }
    }

    static func nextDecemberFirst() -> LocalDay {
        let now = LocalDay(.now, in: .current)
        return LocalDay(now.month == 12 ? now.year + 1 : now.year, 12, 1)
    }

    static func sampleDesign(_ model: AppModel) -> CreativeDocument? {
        let ws = model.workspaceID
        let assets = (try? model.context.fetch(FetchDescriptor<MediaAsset>(sortBy: [SortDescriptor(\.filename)]))) ?? []
        let kit = (try? model.context.fetch(FetchDescriptor<BrandKit>()))?.first { $0.workspaceID == ws }
        guard let a = assets.first(where: { $0.workspaceID == ws }) else { return nil }
        _ = kit
        model.studio.previewValues = ["title": "Slow mornings, warmer mugs.", "subtitle": "Hand-thrown stoneware, made in small batches in Portland.",
                                      "price": "$38", "cta": "Shop the Fog mug", "brand": "Oak & Ember", "url": "", "product_name": "Stoneware Mug — Fog", "date": ""]
        return StudioModel.productPin().withPhoto(a.storedPath)
    }

    /// A TikTok-sized video design for snapshots: a clip made from a product photo, the text over it, and a music track.
    static func sampleVideoDesign(_ model: AppModel) async -> CreativeDocument? {
        guard var doc = sampleDesign(model) else { return nil }
        doc = doc.resized(width: 1080, height: 1920, name: "Fog mug · TikTok")
        let dir = model.storage.exports
        // A 4-second clip of the photo layer alone, and a tone for the music.
        var clipDoc = doc
        clipDoc.layers = clipDoc.layers.filter { if case .image = $0.content { true } else { false } }
        clipDoc.duration = 4
        guard let clip = try? await VideoExporter.export(clipDoc, to: dir.appending(path: "sample-clip.mp4"), fps: 12) else { return nil }
        let tone = dir.appending(path: "sample-music.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let frames = AVAudioFrameCount(8 * 22_050)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let file = try? AVAudioFile(forWriting: tone, settings: format.settings) {
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 330 / 22_050) * 0.2) }
            try? file.write(from: buffer)
        }
        doc.layers.removeAll { if case .image(let i) = $0.content { i.role == "photo" } else { false } }
        doc.layers.insert(CreativeLayer(name: "Product clip", x: 0, y: 0, width: 1080, height: 1920,
                                        content: .video(VideoLayer(path: clip.path, clipDuration: 4, loop: true))), at: 0)
        if let i = doc.layers.lastIndex(where: { if case .text = $0.content { true } else { false } }) { doc.layers[i].start = 2 }
        doc.duration = 12
        doc.audioTracks = [AudioTrack(name: "Warm acoustic", path: tone.path, fileDuration: 8, volume: 0.8, fadeIn: 0.5, fadeOut: 1.5, loop: true)]
        return doc
    }

    /// A soft product-photo stand-in: gradient backdrop, a shadow, and an object.
    static func drawProduct(to url: URL, hue: Double, shape: Int) {
        let w = 1200, h = 1800
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        func c(_ s: Double, _ b: Double, _ dh: Double = 0) -> CGColor {
            NSColor(hue: ((hue + dh).truncatingRemainder(dividingBy: 360)) / 360, saturation: s, brightness: b, alpha: 1).cgColor
        }
        let g = CGGradient(colorsSpace: nil, colors: [c(0.28, 0.78), c(0.35, 0.45, 25)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        ctx.fillEllipse(in: CGRect(x: 300, y: 300, width: 600, height: 110))  // grid: ok sample image pixels
        let body: CGRect = switch shape {
        case 0: CGRect(x: 380, y: 360, width: 440, height: 560)
        case 1: CGRect(x: 470, y: 360, width: 260, height: 820)
        default: CGRect(x: 230, y: 360, width: 740, height: 300)
        }
        let og = CGGradient(colorsSpace: nil, colors: [c(0.1, 0.95), c(0.22, 0.8)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 60, cornerHeight: 60, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(og, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        ctx.restoreGState()
        guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

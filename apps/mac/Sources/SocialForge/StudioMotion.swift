import AppKit
import AVFoundation
import SwiftData
import SwiftUI
import SocialForgeKit

// Video and audio in Creative Studio: clips and music on the canvas, the
// playhead and playback, and exporting an MP4 for TikTok, Reels, Shorts, and
// the rest. The export uses VideoExporter (SocialForgeKit).

extension StudioModel {
    static let defaultVideoLength = 10.0
    /// Longest design length offered (YouTube Shorts and TikTok both take longer, but posts this long are rare).
    static let maxVideoLength = 180.0

    var selectedTrack: AudioTrack? { document?.audioTracks.first { $0.id == selectedAudio } }

    /// Gives a still design a length, so it exports as a video.
    func makeVideo(seconds: Double = StudioModel.defaultVideoLength) {
        change { $0.duration = min(StudioModel.maxVideoLength, max(1, seconds)) }
        time = 0
    }

    func makeStill() {
        stop()
        change { $0.duration = nil; $0.audio = nil }
        time = 0
    }

    func setDuration(_ seconds: Double) {
        change { $0.duration = min(StudioModel.maxVideoLength, max(1, seconds)) }
        time = min(time, document?.duration ?? 0)
    }

    /// A clip from the library or a file, full canvas, under the text. A still design becomes a video as long as the clip.
    func addVideo(path: String, name: String, seconds: Double) {
        guard let doc = document else { return }
        let layer = CreativeLayer(name: name, x: 0, y: 0, width: Double(doc.width), height: Double(doc.height),
                                  content: .video(VideoLayer(path: path, clipDuration: seconds)))
        change { d in
            let index = d.layers.lastIndex { if case .image = $0.content { true } else if case .video = $0.content { true } else { false } }
            d.layers.insert(layer, at: index.map { $0 + 1 } ?? 0)
            if !d.isVideo { d.duration = min(StudioModel.maxVideoLength, max(1, seconds.rounded(.up))) }
        }
        selectedLayer = layer.id
        selectedAudio = nil
        tool = .select
    }

    /// Music or a sound under the video. A still design becomes a video (the track's length, at most 30 seconds).
    func addAudio(path: String, name: String, seconds: Double) {
        let track = AudioTrack(name: name, path: path, fileDuration: seconds, fadeOut: 1)
        change { d in
            d.audioTracks.append(track)
            if !d.isVideo { d.duration = min(30, max(1, seconds.rounded(.up))) }
        }
        selectedAudio = track.id
        selectedLayer = nil
    }

    func changeTrack(_ id: UUID, _ edit: (inout AudioTrack) -> Void) {
        change { d in
            guard let i = d.audioTracks.firstIndex(where: { $0.id == id }) else { return }
            edit(&d.audioTracks[i])
        }
    }

    func removeTrack(_ id: UUID) {
        change { $0.audioTracks.removeAll { $0.id == id } }
        if selectedAudio == id { selectedAudio = nil }
    }

    /// Adds library media to the canvas by kind: images as layers, clips as video layers, music as tracks.
    func add(_ asset: MediaAsset) {
        switch asset.kind {
        case "video": addVideo(path: asset.storedPath, name: asset.title.isEmpty ? "Video" : asset.title, seconds: asset.duration)
        case "audio": addAudio(path: asset.storedPath, name: asset.title.isEmpty ? (asset.filename as NSString).deletingPathExtension : asset.title, seconds: asset.duration)
        default: addImage(path: asset.storedPath, below: false)
        }
    }

    // MARK: Drop

    /// Files dropped on the canvas, from Finder or the Media Library. A photo becomes the base: it fills an
    /// empty photo slot, else goes under everything at full size. With Option held it goes on top where it lands.
    /// Clips become video layers; music becomes a track. Files from outside are copied into the library first.
    func drop(_ urls: [URL], at point: CGPoint, onTop: Bool, model: AppModel) async {
        let paths = urls.map(\.path)
        let inLibrary = (try? model.context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { paths.contains($0.storedPath) }))) ?? []
        let known = Dictionary(inLibrary.map { ($0.storedPath, $0) }, uniquingKeysWith: { a, _ in a })
        var assets: [MediaAsset] = urls.compactMap { known[$0.path] }
        let outside = urls.filter { known[$0.path] == nil && MediaFormats.kind(of: $0) != nil }
        if !outside.isEmpty { assets += await model.importMedia(outside) }
        for a in assets {
            guard a.kind == "image" else { add(a); continue }
            if onTop, let doc = document {
                let w = Double(doc.width) * 0.4
                let h = a.width > 0 ? w * Double(a.height) / Double(a.width) : w
                let layer = CreativeLayer(name: a.title.isEmpty ? "Image" : a.title, x: (point.x - w / 2).rounded(), y: (point.y - h / 2).rounded(),
                                          width: w.rounded(), height: h.rounded(), content: .image(ImageLayer(path: a.storedPath, mode: .fit)))
                change { $0.layers.append(layer) }
                selectedLayer = layer.id
            } else if document?.layers.contains(where: { if case .image(let i) = $0.content { i.role == "photo" && i.path.isEmpty } else { false } }) == true {
                change { $0 = $0.withPhoto(a.storedPath) }
            } else {
                addImage(path: a.storedPath, below: true)
            }
        }
        if assets.isEmpty, !urls.isEmpty { exportMessage = "Those files can't go on the canvas. Drop images, video clips, or music." }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? stop() : play() }

    /// Plays from the playhead: the picture redraws at preview rate; the sound plays in sync.
    func play() {
        guard let doc = rendered(brand: nil), let duration = doc.duration, duration > 0 else { return }
        if time >= duration - 0.05 { time = 0 }
        isPlaying = true
        let startTime = time
        playback = Task { @MainActor [weak self] in
            var player: AVPlayer?
            if let (comp, mix) = await VideoExporter.previewAudio(doc) {
                let item = AVPlayerItem(asset: comp)
                item.audioMix = mix
                let p = AVPlayer(playerItem: item)
                await p.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                p.play()
                player = p
                self?.audioPlayer = p
            }
            let clock = ContinuousClock.now
            while !Task.isCancelled, let self, self.isPlaying {
                // The sound is the clock when there is sound.
                let t = player.map { $0.currentTime().seconds } ?? (startTime + (ContinuousClock.now - clock) / .seconds(1))
                self.time = min(t, duration)
                if t >= duration { break }
                try? await Task.sleep(for: .milliseconds(80))
            }
            self?.stop()
        }
    }

    func stop() {
        isPlaying = false
        playback?.cancel()
        playback = nil
        audioPlayer?.pause()
        audioPlayer = nil
    }

    // MARK: Export

    /// Renders the design to an MP4 in Exports/ and adds it to the library.
    func exportVideo(model: AppModel) {
        guard let base = document, base.isVideo, exportTask == nil else { return }
        stop()
        var doc = base
        if let brand = model.brandKit?.style { doc = doc.applyingBrand(brand) }
        doc = doc.filled(previewValues)
        if !doc.missingFonts.isEmpty {
            exportMessage = "Install or replace these fonts first: \(doc.missingFonts.joined(separator: ", ")). Nothing was exported."
            return
        }
        let safe = doc.name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        let url = model.storage.exports.appending(path: "\(safe)-\(doc.width)x\(doc.height)-\(UUID().uuidString.prefix(6)).mp4")
        let final = doc
        videoProgress = 0
        busy = "Rendering \(doc.width) × \(doc.height) video…"
        exportMessage = nil
        exportTask = Task { @MainActor in
            defer { exportTask = nil; videoProgress = nil; busy = nil }
            do {
                let out = try await VideoExporter.export(final, to: url) { p in
                    Task { @MainActor in self.videoProgress = p }
                }
                let added = await model.importMedia([out])
                if let a = added.first {
                    a.title = previewValues["title"] ?? base.name
                    a.collection = "Videos"
                    a.tags = Array(Set(a.tags + ["branded", "video"]))
                    a.notes = "Made in Creative Studio from “\(base.name)” (\(final.width) × \(final.height), \(Int((final.duration ?? 0).rounded())) s)."
                }
                try? model.context.save()
                exportMessage = "Video exported: \(out.lastPathComponent). It's in the Media Library under Videos."
                model.log("Exported a \(Int((final.duration ?? 0).rounded())) s video from Studio", symbol: "film")
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                exportMessage = "Export canceled."
            } catch {
                exportMessage = "Video export failed: \(error)"
            }
        }
    }

    func cancelVideoExport() { exportTask?.cancel() }
}

/// Under the canvas of a video design: play, the playhead, length, and one bar per layer and track.
struct StudioTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var dragBase: (start: Double, end: Double)?
    private var studio: StudioModel { model.studio }
    private let labelWidth: CGFloat = 132
    private let rowHeight: CGFloat = 22

    var body: some View {
        if let doc = studio.document, let duration = doc.duration {
            VStack(alignment: .leading, spacing: Space.sm) {
                header(duration)
                GeometryReader { geo in
                    let w = max(1, geo.size.width - labelWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        ruler(duration, width: w)
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(doc.layers.reversed()) { layer in layerRow(layer, duration: duration, width: w) }
                                ForEach(doc.audioTracks) { track in trackRow(track, duration: duration, width: w) }
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // The playhead.
                        Rectangle().fill(DS.accentFill).frame(width: 2)
                            .offset(x: labelWidth + w * CGFloat(studio.time / duration) - 1)  // grid: ok playhead position
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: min(240, 28 + CGFloat(doc.layers.count + doc.audioTracks.count) * (rowHeight + 2)))
            }
            .padding(Space.md)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.stroke))
            .padding(.horizontal, Space.xxl)
        }
    }

    private func header(_ duration: Double) -> some View {
        HStack(spacing: Space.md) {
            Button(studio.isPlaying ? "Pause" : "Play", systemImage: studio.isPlaying ? "pause.fill" : "play.fill") { studio.togglePlay() }
                .labelStyle(.iconOnly).buttonStyle(IconButtonStyle(selected: studio.isPlaying))
                .keyboardShortcut(.space, modifiers: [])
                .help("Play the preview (Space)")
            Text("\(Self.clock(studio.time)) / \(Self.clock(duration))").font(DS.mono).foregroundStyle(DS.text2).monospacedDigit()
            Spacer()
            Text("Length").font(DS.small).foregroundStyle(DS.text2)
            TextField("Seconds", value: Binding(get: { duration }, set: { studio.setDuration($0) }), format: .number.precision(.fractionLength(0...1)))
                .fieldStyle().frame(width: 64).multilineTextAlignment(.trailing)
            Text("s").font(DS.small).foregroundStyle(DS.text2)
        }
    }

    private func ruler(_ duration: Double, width: CGFloat) -> some View {
        let step: Double = duration <= 15 ? 1 : duration <= 60 ? 5 : 15
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).frame(height: 20)
            ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { s in
                Text(Self.clock(s, fraction: false)).font(.system(size: 10).monospacedDigit()).foregroundStyle(DS.text3)
                    .offset(x: labelWidth + width * CGFloat(s / duration))  // grid: ok ruler tick
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            studio.stop()
            studio.time = min(duration, max(0, Double((g.location.x - labelWidth) / width) * duration))
        })
        .help("Drag to move the playhead")
    }

    private func label(_ symbol: String, _ name: String, selected: Bool) -> some View {
        Label(name, systemImage: symbol).font(DS.small).lineLimit(1).truncationMode(.tail)
            .foregroundStyle(selected ? DS.text : DS.text2)
            .frame(width: labelWidth - Space.sm, alignment: .leading)
    }

    private func layerRow(_ layer: CreativeLayer, duration: Double, width: CGFloat) -> some View {
        let start = layer.start ?? 0, end = min(layer.end ?? duration, duration)
        let isVideo = { if case .video = layer.content { true } else { false } }()
        let selected = studio.selectedLayer == layer.id
        return HStack(spacing: Space.sm) {
            label(isVideo ? "film" : symbol(layer), layer.name, selected: selected)
            ZStack(alignment: .leading) {
                bar(start: start, end: end, duration: duration, width: width, color: isVideo ? DS.accentFill : DS.text3, selected: selected)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in moveLayer(layer, by: g.translation.width, duration: duration, width: width) }
                        .onEnded { _ in dragBase = nil; studio.endDrag() })
                // Drag the right edge to change when it disappears.
                Rectangle().fill(.clear).frame(width: 8, height: rowHeight).contentShape(Rectangle())
                    .offset(x: width * CGFloat(end / duration) - 6)  // grid: ok bar edge
                    .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                        if dragBase == nil, let d = studio.document { dragBase = (start, end); studio.beginDrag(d) }
                        let newEnd = min(duration, max(start + 0.2, (dragBase?.end ?? end) + Double(g.translation.width / width) * duration))
                        retime(layer.id, start: start, end: newEnd, duration: duration)
                    }.onEnded { _ in dragBase = nil; studio.endDrag() })
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            }
            .frame(width: width, height: rowHeight, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedLayer = layer.id; studio.selectedAudio = nil }
    }

    private func trackRow(_ track: AudioTrack, duration: Double, width: CGFloat) -> some View {
        let usable = max(0, track.fileDuration - track.trimStart)
        let end = track.loop ? duration : min(duration, track.start + usable)
        let selected = studio.selectedAudio == track.id
        return HStack(spacing: Space.sm) {
            label("waveform", track.name, selected: selected)
            bar(start: track.start, end: end, duration: duration, width: width, color: DS.green, selected: selected)
                .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                    if dragBase == nil, let d = studio.document { dragBase = (track.start, end); studio.beginDrag(d) }
                    let s = max(0, min(duration - 0.2, (dragBase?.start ?? 0) + Double(g.translation.width / width) * duration))
                    studio.changeTrackLive(track.id) { $0.start = (s * 10).rounded() / 10 }
                }.onEnded { _ in dragBase = nil; studio.endDrag() })
                .frame(width: width, height: rowHeight, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedAudio = track.id; studio.selectedLayer = nil }
    }

    private func bar(start: Double, end: Double, duration: Double, width: CGFloat, color: Color, selected: Bool) -> some View {
        let x = width * CGFloat(start / duration), w = max(4, width * CGFloat((end - start) / duration))
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(selected ? 0.85 : 0.45))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(selected ? DS.text : .clear, lineWidth: 1))
            .frame(width: w, height: rowHeight - 4)
            .offset(x: x)  // grid: ok timeline position
            .frame(width: width, alignment: .leading)
    }

    private func moveLayer(_ layer: CreativeLayer, by dx: CGFloat, duration: Double, width: CGFloat) {
        let start = layer.start ?? 0, end = min(layer.end ?? duration, duration)
        if dragBase == nil, let d = studio.document { dragBase = (start, end); studio.beginDrag(d) }
        guard let base = dragBase else { return }
        let length = base.end - base.start
        let s = max(0, min(duration - length, base.start + Double(dx / width) * duration))
        retime(layer.id, start: s, end: s + length, duration: duration)
    }

    /// Whole-video spans are stored as nil, so a later length change keeps them whole.
    private func retime(_ id: UUID, start: Double, end: Double, duration: Double) {
        let s = (start * 10).rounded() / 10, e = (end * 10).rounded() / 10
        studio.changeLayerLive(id) { l in
            l.start = s <= 0.05 ? nil : s
            l.end = e >= duration - 0.05 ? nil : e
        }
    }

    private func symbol(_ l: CreativeLayer) -> String {
        switch l.content {
        case .text: "textformat"
        case .shape: "square"
        case .image: "photo"
        case .video: "film"
        }
    }

    static func clock(_ s: Double, fraction: Bool = true) -> String {
        let m = Int(s) / 60, sec = s - Double(m * 60)
        return fraction ? String(format: "%d:%04.1f", m, sec) : String(format: "%d:%02d", m, Int(sec))
    }
}

extension StudioModel {
    /// Edits during a drag, without undo steps (the drag records one step when it ends).
    func changeLayerLive(_ id: UUID, _ edit: (inout CreativeLayer) -> Void) {
        guard var d = document, let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
        edit(&d.layers[i])
        document = d
        touch()
    }

    func changeTrackLive(_ id: UUID, _ edit: (inout AudioTrack) -> Void) {
        guard var d = document, let i = d.audioTracks.firstIndex(where: { $0.id == id }) else { return }
        edit(&d.audioTracks[i])
        document = d
        touch()
    }
}

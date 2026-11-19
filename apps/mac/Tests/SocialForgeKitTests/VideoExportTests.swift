import AVFoundation
import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Video and audio")
struct VideoExportTests {
    /// A short sine-wave WAV.
    static func tone(seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.3) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func design(seconds: Double, width: Int = 360, height: Int = 640) -> CreativeDocument {
        var doc = CreativeDocument(name: "Clip", width: width, height: height, background: RGBA(hex: 0x223344))
        doc.duration = seconds
        doc.layers = [
            CreativeLayer(name: "Box", x: 40, y: 40, width: 120, height: 120, content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(hex: 0xFF7A45)))),
            CreativeLayer(name: "Title", x: 20, y: 400, width: 320, height: 80, start: 0.5,
                          content: .text(TextLayer(text: "Hello", fontName: "Helvetica", size: 48, color: .white))),
        ]
        return doc
    }

    @Test func clipTimeTrimsLoopsAndHolds() {
        let v = VideoLayer(path: "/x.mp4", trimStart: 1, clipDuration: 5)
        #expect(v.clipTime(at: 0) == 1)
        #expect(v.clipTime(at: 2) == 3)
        #expect(v.clipTime(at: 10)! > 4.99)        // holds the last frame
        var looping = v; looping.loop = true
        #expect(looping.clipTime(at: 5) == 2)       // 4 s usable: 5 → 1 s into the second pass
        #expect(v.clipTime(at: -1) == nil)
    }

    @Test func layerTiming() {
        let l = CreativeLayer(name: "t", x: 0, y: 0, width: 1, height: 1, start: 1, end: 2, content: .shape(ShapeLayer(kind: .rectangle, fill: .black)))
        #expect(l.isVisible(at: nil))
        #expect(!l.isVisible(at: 0.5) && l.isVisible(at: 1) && !l.isVisible(at: 2))
    }

    @Test func audioPlanCutsLoopsAndFades() {
        var doc = Self.design(seconds: 10)
        doc.audioTracks = [AudioTrack(name: "Music", path: "/m.wav", start: 1, trimStart: 2, fileDuration: 6, volume: 0.8, fadeIn: 0.5, fadeOut: 1, loop: true)]
        let plan = VideoExporter.audioPlan(doc, duration: 10)
        #expect(plan.count == 1)
        let pieces = plan[0]
        // 4 s usable per pass, from second 1 to 10: 4 + 4 + 1.
        #expect(pieces.map(\.length) == [4, 4, 1])
        #expect(pieces.map(\.at) == [1, 5, 9])
        #expect(pieces.allSatisfy { $0.from == 2 })
        #expect(pieces.first?.fadeIn == 0.5 && pieces.last?.fadeOut == 1 && pieces[1].fadeOut == 0)

        doc.audioTracks[0].loop = false
        #expect(VideoExporter.audioPlan(doc, duration: 10)[0].map(\.length) == [4])
        doc.audioTracks[0].start = 12
        #expect(VideoExporter.audioPlan(doc, duration: 10).isEmpty)
    }

    @Test func mutedVideoAddsNoSound() {
        var doc = Self.design(seconds: 3)
        doc.layers.append(CreativeLayer(name: "Clip", x: 0, y: 0, width: 10, height: 10, content: .video(VideoLayer(path: "/c.mp4", clipDuration: 5, muted: true))))
        #expect(VideoExporter.audioPlan(doc, duration: 3).isEmpty)
    }

    @Test func oldDesignsStillDecode() throws {
        let json = #"{"version":1,"name":"Old","width":100,"height":100,"background":{"r":1,"g":1,"b":1,"a":1},"layers":[]}"#
        let doc = try CreativeDocument.from(json: Data(json.utf8))
        #expect(!doc.isVideo && doc.audioTracks.isEmpty)
    }

    @Test func exportsAnMP4WithAClipAndMusic() async throws {
        let dir = Fixture.tempDir()
        // 1. A silent design becomes a clip.
        let clip = try await VideoExporter.export(Self.design(seconds: 1), to: dir.appending(path: "clip.mp4"), fps: 24)
        let clipInfo = try #require(await AVProbe.info(clip))
        #expect(abs(clipInfo.duration - 1) < 0.1)
        #expect(clipInfo.width == 360 && clipInfo.height == 640 && !clipInfo.hasAudio)
        #expect(await AVProbe.frame(clip, at: 0.5, maxPixel: 200) != nil)

        // 2. That clip as a looping video layer, plus a music track, in a vertical TikTok-shaped design.
        let music = dir.appending(path: "tone.wav")
        try Self.tone(seconds: 1.5, to: music)
        let musicInfo = try #require(await AVProbe.info(music))
        #expect(musicInfo.hasAudio && !musicInfo.hasVideo)

        var doc = CreativeDocument(name: "Reel", width: 540, height: 960)
        doc.duration = 2
        doc.layers = [CreativeLayer(name: "Clip", x: 0, y: 0, width: 540, height: 960,
                                    content: .video(VideoLayer(path: clip.path, clipDuration: clipInfo.duration, loop: true)))]
        doc.audioTracks = [AudioTrack(name: "Tone", path: music.path, fileDuration: musicInfo.duration, fadeOut: 0.3)]
        let out = try await VideoExporter.export(doc, to: dir.appending(path: "reel.mp4"), fps: 24)
        let info = try #require(await AVProbe.info(out))
        #expect(abs(info.duration - 2) < 0.15)
        #expect(info.width == 540 && info.height == 960)
        #expect(info.hasVideo && info.hasAudio)
    }

    @Test func refusesADesignWithoutLength() async {
        await #expect(throws: VideoExporter.ExportError.notAVideo) {
            _ = try await VideoExporter.export(CreativeDocument(name: "x", width: 10, height: 10), to: Fixture.tempDir().appending(path: "x.mp4"))
        }
    }

    @Test func audioFilesImport() {
        #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/a/song.mp3")) == .audio)
        #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/a/song.m4a")) == .audio)
        #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/a/song.wav")) == .audio)
        #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/a/clip.mov")) == .video)
    }
}

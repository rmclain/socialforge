import Foundation
import Testing
@testable import SocialForgeKit

/// Runs the starter video and music workflows on a real ComfyUI server. Off by default (it uses the GPU);
/// run with SF_LIVE_COMFY=http://host:8188 swift test --filter LiveComfy
@Suite("Live ComfyUI starters", .enabled(if: ProcessInfo.processInfo.environment["SF_LIVE_COMFY"] != nil), .serialized)
struct LiveComfyTests {
    let client = ComfyUIClient(baseURL: URL(string: ProcessInfo.processInfo.environment["SF_LIVE_COMFY"] ?? "http://127.0.0.1:8188")!)
    let folder = StarterWorkflowTests.folder

    func load(_ name: String) throws -> ComfyWorkflow {
        try ComfyWorkflow.parse(name: name, json: Data(contentsOf: folder.appending(path: "\(name).json")))
    }

    @Test func verticalVideo() async throws {
        let wf = try load("SocialForge Video Vertical")
        let graph = wf.applying(prompt: "slow push-in on a ceramic mug on an oak table, steam rising, morning light", negative: "blurry, watermark",
                                seed: 42, width: 704, height: 1216, batch: 1, checkpoint: nil, length: wf.frames(forSeconds: 2))
        let files = try await client.runFiles(graph: graph, timeout: .seconds(900))
        let file = try #require(files.first)
        #expect(file.filename.hasSuffix(".mp4"))
        let url = Fixture.tempDir().appending(path: file.filename)
        try file.data.write(to: url)
        let info = try #require(await AVProbe.info(url))
        #expect(info.width == 704 && info.height == 1216)
        #expect(abs(info.duration - Double(wf.frames(forSeconds: 2)) / wf.frameRate) < 0.1)
        print("LIVE video \(info.width)x\(info.height) \(info.duration)s \(file.data.count) bytes")
    }

    @Test func imageWithText() async throws {
        let wf = try load("SocialForge Image Text")
        let graph = wf.applying(prompt: "a kraft paper coffee bag on a linen table, the bag printed with the words \"OAK & EMBER\" in a clean serif",
                                negative: nil, seed: 11, width: 832, height: 1248, batch: 1, checkpoint: nil)
        let files = try await client.runFiles(graph: graph, timeout: .seconds(600))
        let file = try #require(files.first)
        let url = Fixture.tempDir().appending(path: file.filename)
        try file.data.write(to: url)
        let info = try #require(ImageProbe.info(url))
        #expect(info.width == 832 && info.height == 1248)
        try? file.data.write(to: URL(fileURLWithPath: "/tmp/sf-live-moss.png"))
        print("LIVE moss \(info.width)x\(info.height) \(file.data.count) bytes")
    }

    @Test func music() async throws {
        let wf = try load("SocialForge Music")
        let graph = wf.applying(prompt: "English, male vocal, lo-fi, soft piano, mellow, 80 BPM", negative: nil, seed: 7, width: nil, height: nil,
                                batch: nil, checkpoint: nil, seconds: 15, lyrics: "[Verse 1]\nQuiet morning, coffee in my hand\n\n[Chorus]\nSlow it down, slow it down")
        let files = try await client.runFiles(graph: graph, timeout: .seconds(900))
        let file = try #require(files.first)
        #expect(file.filename.hasSuffix(".mp3"))
        let url = Fixture.tempDir().appending(path: file.filename)
        try file.data.write(to: url)
        let info = try #require(await AVProbe.info(url))
        #expect(info.hasAudio && !info.hasVideo && info.duration > 3)
        print("LIVE music \(info.duration)s \(file.data.count) bytes")
    }
}

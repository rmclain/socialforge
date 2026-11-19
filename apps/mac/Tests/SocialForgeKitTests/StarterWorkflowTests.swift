import Foundation
import Testing
@testable import SocialForgeKit

/// The starter workflows in comfyui/workflows/api must map cleanly, or AI Studio would write the prompt to the wrong place.
@Suite("Starter ComfyUI workflows")
struct StarterWorkflowTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../comfyui/workflows/api").standardized

    func load(_ name: String) throws -> ComfyWorkflow {
        try ComfyWorkflow.parse(name: name, json: Data(contentsOf: Self.folder.appending(path: "\(name).json")))
    }

    func input(_ g: [String: JSONValue], _ ref: ComfyInputRef?) -> JSONValue? {
        guard let ref else { return nil }
        return g[ref.node]?.objectValue?["inputs"]?.objectValue?[ref.input]
    }

    @Test func image() throws {
        let wf = try load("SocialForge Image")
        #expect(wf.outputKind == .image)
        #expect(wf.mapping.positive == ComfyInputRef(node: "5", input: "text"))
        #expect(wf.mapping.negative == ComfyInputRef(node: "6", input: "text"))
        #expect(wf.mapping.width?.node == "7" && wf.mapping.seed?.node == "8")
        #expect(wf.unmappedRequired.isEmpty)
    }

    @Test func imageWithText() throws {
        let wf = try load("SocialForge Image Text")
        #expect(wf.outputKind == .image && wf.drawsText)
        #expect(wf.mapping.positive == ComfyInputRef(node: "4", input: "text"))
        #expect(wf.mapping.negative == ComfyInputRef(node: "5", input: "text"))
        // EmptyFlux2LatentImage: SocialForge sets the size.
        #expect(wf.mapping.width == ComfyInputRef(node: "6", input: "width"))
        #expect(wf.mapping.height == ComfyInputRef(node: "6", input: "height"))
        // A nil negative keeps the workflow's own, tuned one.
        let g = wf.applying(prompt: "a sign that says \"OPEN\"", negative: nil, seed: 3, width: 832, height: 1248, batch: 1, checkpoint: nil)
        #expect(input(g, wf.mapping.negative)?.stringValue?.hasPrefix("nsfw") == true)
        #expect(try !load("SocialForge Image").drawsText)
    }

    @Test(arguments: ["SocialForge Video Vertical", "SocialForge Video Square"])
    func video(_ name: String) throws {
        let wf = try load(name)
        #expect(wf.outputKind == .video)
        // Through LTXVConditioning: the prompt goes to the positive encoder, not the negative one.
        #expect(wf.mapping.positive == ComfyInputRef(node: "4", input: "text"))
        #expect(wf.mapping.negative == ComfyInputRef(node: "5", input: "text"))
        #expect(wf.mapping.length == ComfyInputRef(node: "7", input: "length"))
        #expect(wf.frameRate == 24)
        #expect(wf.frames(forSeconds: 4) == 97)
        #expect(wf.frames(forSeconds: 6) == 145)
        let g = wf.applying(prompt: "a mug", negative: "blurry", seed: 7, width: 704, height: 1216, batch: 1, checkpoint: nil, length: 145)
        #expect(input(g, wf.mapping.positive)?.stringValue == "a mug")
        #expect(input(g, wf.mapping.negative)?.stringValue == "blurry")
        #expect(input(g, wf.mapping.length)?.numberValue == 145)
        #expect(input(g, ComfyInputRef(node: "8", input: "seed"))?.numberValue == 7)
    }

    @Test func music() throws {
        let wf = try load("SocialForge Music")
        #expect(wf.outputKind == .audio)
        #expect(wf.mapping.positive == ComfyInputRef(node: "2", input: "style"))
        #expect(wf.mapping.lyrics == ComfyInputRef(node: "2", input: "lyrics"))
        #expect(wf.mapping.seconds == ComfyInputRef(node: "2", input: "max_duration"))
        #expect(wf.mapping.negative == nil)
        #expect(wf.unmappedRequired.isEmpty)
        let g = wf.applying(prompt: "lo-fi, warm", negative: nil, seed: 1, width: nil, height: nil, batch: nil, checkpoint: nil,
                            seconds: 30, lyrics: "[Verse]\nhello")
        #expect(input(g, wf.mapping.positive)?.stringValue == "lo-fi, warm")
        #expect(input(g, wf.mapping.lyrics)?.stringValue == "[Verse]\nhello")
        #expect(input(g, wf.mapping.seconds)?.numberValue == 30)
    }
}

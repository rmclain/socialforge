import Foundation
import Testing
@testable import SocialForgeKit

@Suite("ComfyUI workflows")
struct ComfyWorkflowTests {
    /// SDXL-style graph with odd node ids and a conditioning node between the sampler and the text encoder.
    let oddGraph = """
    {
      "ckpt": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sdxl.safetensors"}},
      "101": {"class_type": "CLIPTextEncode", "inputs": {"text": "a cat", "clip": ["ckpt", 1]}},
      "102": {"class_type": "CLIPTextEncode", "inputs": {"text": "ugly", "clip": ["ckpt", 1]}},
      "cn": {"class_type": "ConditioningCombine", "inputs": {"conditioning_1": ["101", 0], "conditioning_2": ["101", 0]}},
      "lat": {"class_type": "EmptySD3LatentImage", "inputs": {"width": 1024, "height": 768, "batch_size": 1}},
      "sampler": {"class_type": "KSamplerAdvanced", "inputs": {"noise_seed": 42, "positive": ["cn", 0], "negative": ["102", 0],
                  "latent_image": ["lat", 0], "model": ["ckpt", 0]}},
      "save": {"class_type": "SaveImage", "inputs": {"images": ["sampler", 0]}}
    }
    """

    @Test func detectsMappingWithNonStandardIDs() throws {
        let w = try ComfyWorkflow.parse(name: "odd", json: Data(oddGraph.utf8))
        #expect(w.mapping.positive == ComfyInputRef(node: "101", input: "text"))
        #expect(w.mapping.negative == ComfyInputRef(node: "102", input: "text"))
        #expect(w.mapping.seed == ComfyInputRef(node: "sampler", input: "noise_seed"))
        #expect(w.mapping.width == ComfyInputRef(node: "lat", input: "width"))
        #expect(w.mapping.height == ComfyInputRef(node: "lat", input: "height"))
        #expect(w.mapping.batch == ComfyInputRef(node: "lat", input: "batch_size"))
        #expect(w.mapping.checkpoint == ComfyInputRef(node: "ckpt", input: "ckpt_name"))
        #expect(w.unmappedRequired.isEmpty)
    }

    @Test func applyingSubstitutes() throws {
        let w = try ComfyWorkflow.parse(name: "odd", json: Data(oddGraph.utf8))
        let g = w.applying(prompt: "a mug", negative: nil, seed: 7, width: 832, height: nil, batch: 2, checkpoint: "other.safetensors")
        func input(_ node: String, _ key: String) -> JSONValue? { g[node]?.objectValue?["inputs"]?.objectValue?[key] }
        #expect(input("101", "text") == .string("a mug"))
        #expect(input("102", "text") == .string("ugly"))
        #expect(input("sampler", "noise_seed") == .number(7))
        #expect(input("lat", "width") == .number(832))
        #expect(input("lat", "height") == .number(768))
        #expect(input("lat", "batch_size") == .number(2))
        #expect(input("ckpt", "ckpt_name") == .string("other.safetensors"))
        #expect(input("sampler", "positive") == .array([.string("cn"), .number(0)]))
        // Encodes whole numbers as integers.
        let text = String(decoding: try JSONEncoder().encode(g["sampler"]!), as: UTF8.self)
        #expect(text.contains("\"noise_seed\":7") && !text.contains("7.0"))
    }

    @Test func rejectsUIFormatAndBadFiles() {
        #expect(throws: ComfyWorkflow.ParseError.uiFormat) {
            try ComfyWorkflow.parse(name: "ui", json: Data(#"{"last_node_id": 9, "nodes": [{"id": 3, "type": "KSampler"}], "links": []}"#.utf8))
        }
        #expect(throws: ComfyWorkflow.ParseError.notJSON) { try ComfyWorkflow.parse(name: "x", json: Data("nope".utf8)) }
        #expect(throws: ComfyWorkflow.ParseError.notJSON) { try ComfyWorkflow.parse(name: "x", json: Data("[1,2]".utf8)) }
        #expect(throws: ComfyWorkflow.ParseError.noNodes) { try ComfyWorkflow.parse(name: "x", json: Data("{}".utf8)) }
        #expect(throws: ComfyWorkflow.ParseError.missingClassType("2")) {
            try ComfyWorkflow.parse(name: "x", json: Data(#"{"1": {"class_type": "SaveImage", "inputs": {}}, "2": {"inputs": {}}}"#.utf8))
        }
        #expect(ComfyWorkflow.ParseError.uiFormat.errorDescription?.contains("Save (API Format)") == true)
    }

    @Test func unmappedPromptIsReported() throws {
        let w = try ComfyWorkflow.parse(name: "x", json: Data(#"{"1": {"class_type": "LoadImage", "inputs": {"image": "a.png"}}}"#.utf8))
        #expect(w.unmappedRequired == ["prompt"])
    }

    @Test func textToImageTemplateIsMapped() throws {
        let w = ComfyWorkflow.textToImage(checkpoint: "sd15.safetensors")
        #expect(w.unmappedRequired.isEmpty)
        #expect(w.mapping.positive == ComfyInputRef(node: "6", input: "text"))
        #expect(w.mapping.negative == ComfyInputRef(node: "7", input: "text"))
        #expect(w.mapping.seed?.input == "seed")
        #expect(w.mapping.width != nil && w.mapping.checkpoint != nil)
        // Survives a round trip through JSON as an API-format file.
        let data = try JSONEncoder().encode(JSONValue.object(w.graph))
        #expect(try ComfyWorkflow.parse(name: "t", json: data).mapping == w.mapping)
    }

    @Test func progressMessages() {
        #expect(ComfyProgress.parse(#"{"type":"progress","data":{"value":3,"max":20,"node":"3","prompt_id":"p"}}"#) == ComfyProgress(value: 3, max: 20, node: "3"))
        #expect(ComfyProgress.parse(#"{"type":"status","data":{}}"#) == nil)
    }
}

@Suite("ComfyUI client")
struct ComfyClientTests {
    @Test func checkpointsAndBearerToken() async throws {
        let stub = HTTPStub.make { _, _ in
            (200, json(#"{"CheckpointLoaderSimple":{"input":{"required":{"ckpt_name":[["a.safetensors","b.ckpt"],{"tooltip":"x"}]}}}}"#))
        }
        let c = ComfyUIClient(baseURL: stub.base, token: "tok", session: stub.session)
        #expect(try await c.checkpoints() == ["a.safetensors", "b.ckpt"])
        #expect(stub.log.paths == ["/object_info/CheckpointLoaderSimple"])
        #expect(stub.log.all[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func submitSendsPromptAndClientID() async throws {
        let stub = HTTPStub.make { _, _ in (200, json(#"{"prompt_id":"abc","number":1,"node_errors":{}}"#)) }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        let graph = ComfyWorkflow.textToImage(checkpoint: "m").applying(prompt: "mug", negative: nil, seed: 1, width: nil, height: nil, batch: nil, checkpoint: nil)
        #expect(try await c.submit(graph: graph, clientID: "client-1") == "abc")
        let body = jsonObject(stub.log.all[0].body)
        #expect(body["client_id"] as? String == "client-1")
        #expect(((body["prompt"] as? [String: Any])?["6"] as? [String: Any]).flatMap { ($0["inputs"] as? [String: Any])?["text"] as? String } == "mug")
        #expect(stub.log.all[0].request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func submitSurfacesNodeErrors() async throws {
        let stub = HTTPStub.make { _, _ in
            (400, json(#"{"error":{"type":"prompt_outputs_failed_validation","message":"Prompt outputs failed validation","details":""},"node_errors":{"4":{"class_type":"CheckpointLoaderSimple","errors":[{"message":"Value not in list","details":"ckpt_name: 'x' not in []"}]}}}"#))
        }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        await #expect(throws: ComfyUIClient.ClientError.invalidWorkflow(
            "Prompt outputs failed validation\nNode 4 (CheckpointLoaderSimple): Value not in list: ckpt_name: 'x' not in []")) {
            try await c.submit(graph: [:], clientID: "c")
        }
    }

    @Test func historyAndView() async throws {
        let stub = HTTPStub.make { req, _ in
            switch req.url?.path {
            case "/history/pending": (200, json("{}"))
            case "/history/done": (200, json(#"{"done":{"outputs":{"9":{"images":[{"filename":"a.png","subfolder":"","type":"output"}]},"12":{"images":[{"filename":"b.png","subfolder":"s","type":"temp"}]}},"status":{"status_str":"success","completed":true}}}"#))
            case "/history/bad": (200, json(#"{"bad":{"outputs":{},"status":{"status_str":"error","messages":[["execution_error",{"node_type":"KSampler","exception_message":"out of memory"}]]}}}"#))
            case "/view": (200, Data((req.url?.query ?? "").utf8))
            default: (404, Data())
            }
        }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        #expect(try await c.outputs(promptID: "pending") == nil)
        let out = try #require(try await c.outputs(promptID: "done"))
        #expect(out == [ComfyOutputImage(filename: "a.png", subfolder: "", type: "output"), ComfyOutputImage(filename: "b.png", subfolder: "s", type: "temp")])
        await #expect(throws: ComfyUIClient.ClientError.executionFailed("KSampler: out of memory")) { try await c.outputs(promptID: "bad") }
        let view = try await c.image(ComfyOutputImage(filename: "b c.png", subfolder: "s", type: "temp"))
        #expect(String(decoding: view, as: UTF8.self) == "filename=b%20c.png&subfolder=s&type=temp")
    }

    @Test func runPollsThenDownloads() async throws {
        let polls = RequestLog()
        let stub = HTTPStub.make { req, _ in
            switch req.url?.path {
            case "/prompt": return (200, json(#"{"prompt_id":"p1"}"#))
            case "/history/p1":
                polls.append(req, Data())
                return polls.all.count < 3 ? (200, json("{}"))
                    : (200, json(#"{"p1":{"outputs":{"9":{"images":[{"filename":"x.png","subfolder":"","type":"output"}]}},"status":{"status_str":"success"}}}"#))
            case "/view": return (200, Data([1, 2, 3]))
            default: return (404, Data())
            }
        }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        let images = try await c.run(graph: [:], pollEvery: .milliseconds(5), timeout: .seconds(10))
        #expect(images == [Data([1, 2, 3])])
        #expect(polls.all.count == 3)
    }

    @Test func runTimesOutAndStopsTheJob() async throws {
        let stub = HTTPStub.make { req, _ in
            req.url?.path == "/prompt" ? (200, json(#"{"prompt_id":"p2"}"#)) : (200, json("{}"))
        }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        await #expect(throws: ComfyUIClient.ClientError.timedOut) {
            try await c.run(graph: [:], pollEvery: .milliseconds(5), timeout: .milliseconds(30))
        }
        #expect(stub.log.paths.contains("/interrupt"))
        #expect(stub.log.paths.contains("/queue"))
    }

    @Test func runCancellationInterrupts() async throws {
        let stub = HTTPStub.make { req, _ in
            req.url?.path == "/prompt" ? (200, json(#"{"prompt_id":"p3"}"#)) : (200, json("{}"))
        }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        let task = Task { try await c.run(graph: [:], pollEvery: .milliseconds(20), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(stub.log.paths.contains("/interrupt"))
    }

    @Test func uploadImageMultipart() async throws {
        let stub = HTTPStub.make { _, _ in (200, json(#"{"name":"mug.png","subfolder":"sf","type":"input"}"#)) }
        let c = ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session)
        #expect(try await c.uploadImage(Data([9, 9]), filename: "mug.png") == "sf/mug.png")
        let req = stub.log.all[0]
        #expect(req.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(String(decoding: req.body, as: UTF8.self).contains("name=\"image\"; filename=\"mug.png\""))
    }

    @Test func legacyInitStillWorks() async throws {
        #expect(ComfyUIClient(baseURL: URL(string: "http://127.0.0.1:8188")!).token == nil)
        #expect(ComfyUIClient.transportProblem(URL(string: "http://example.com")!) != nil)
        #expect(ComfyUIClient.transportProblem(URL(string: "http://192.168.1.4:8188")!) == nil)
        let stub = HTTPStub.make { _, _ in (200, json(#"{"system":{"os":"posix"},"devices":[{"name":"mps"}]}"#)) }
        let stats = try await ComfyUIClient(baseURL: stub.base, token: nil, session: stub.session).systemStats()
        #expect(stats.devices.first?.name == "mps")
    }
}

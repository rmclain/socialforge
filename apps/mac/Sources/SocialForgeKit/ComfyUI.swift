import Foundation

// ComfyUI's documented server API: GET /system_stats, GET /object_info,
// POST /prompt, GET /history/{id}, GET /view, POST /upload/image,
// POST /interrupt, and the /ws progress socket.
//
// UNVERIFIED: these calls are covered by stubbed tests only; they have not yet
// been run against a live ComfyUI server.

// MARK: - JSON

/// Any JSON value. ComfyUI workflows are free-form, so they are kept as this.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers go out without ".0" so seeds and sizes stay integers.
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
}

// MARK: - Workflows

/// One input of one node in an API-format graph.
public struct ComfyInputRef: Codable, Sendable, Hashable {
    public var node: String
    public var input: String
    public init(node: String, input: String) { self.node = node; self.input = input }
}

/// Where SocialForge writes its values into a workflow. Nil means "leave the workflow's own value".
public struct ComfyMapping: Codable, Sendable, Equatable {
    public var positive: ComfyInputRef?
    public var negative: ComfyInputRef?
    public var seed: ComfyInputRef?
    public var width: ComfyInputRef?
    public var height: ComfyInputRef?
    public var batch: ComfyInputRef?
    public var checkpoint: ComfyInputRef?
    /// Frames, on a video latent (LTX, Hunyuan, Wan, Mochi, Cosmos).
    public var length: ComfyInputRef?
    /// Seconds, on an audio latent (ACE-Step) or a music node's maximum length (YuE).
    public var seconds: ComfyInputRef?
    /// Song lyrics, on a music node.
    public var lyrics: ComfyInputRef?
    /// Frames per second, on every node that has one (conditioning and video encoding must agree).
    public var fps: [ComfyInputRef] = []

    public init(positive: ComfyInputRef? = nil, negative: ComfyInputRef? = nil, seed: ComfyInputRef? = nil, width: ComfyInputRef? = nil,
                height: ComfyInputRef? = nil, batch: ComfyInputRef? = nil, checkpoint: ComfyInputRef? = nil) {
        self.positive = positive; self.negative = negative; self.seed = seed; self.width = width
        self.height = height; self.batch = batch; self.checkpoint = checkpoint
    }
}

public struct ComfyWorkflow: Codable, Sendable, Equatable {
    public var name: String
    /// API format: node id → {"class_type", "inputs"}.
    public var graph: [String: JSONValue]
    public var mapping: ComfyMapping

    public init(name: String, graph: [String: JSONValue], mapping: ComfyMapping) {
        self.name = name; self.graph = graph; self.mapping = mapping
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case notJSON, uiFormat, noNodes, missingClassType(String)

        public var errorDescription: String? {
            switch self {
            case .notJSON: "This file is not a ComfyUI workflow (it is not JSON)."
            case .uiFormat: "This is a ComfyUI editor file. In ComfyUI, turn on Dev mode in Settings, then use Workflow > Export (API), or \"Save (API Format)\", and import that file."
            case .noNodes: "This workflow has no nodes."
            case .missingClassType(let id): "Node \(id) has no class_type, so this is not an API-format workflow. Export it with \"Save (API Format)\"."
            }
        }
    }

    public static func parse(name: String, json: Data) throws(ParseError) -> ComfyWorkflow {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: json), let top = root.objectValue else { throw .notJSON }
        if top["nodes"]?.arrayValue != nil { throw .uiFormat }
        guard !top.isEmpty else { throw .noNodes }
        for id in sortedIDs(top.keys) {
            guard top[id]?.objectValue?["class_type"]?.stringValue != nil else { throw .missingClassType(id) }
        }
        return ComfyWorkflow(name: name, graph: top, mapping: detectMapping(top))
    }

    /// The graph with SocialForge's values written in. Nil values keep the workflow's own.
    public func applying(prompt: String, negative: String?, seed: Int, width: Int?, height: Int?, batch: Int?, checkpoint: String?,
                         length: Int? = nil, seconds: Double? = nil, lyrics: String? = nil) -> [String: JSONValue] {
        var g = graph
        func set(_ ref: ComfyInputRef?, _ value: JSONValue?) {
            guard let ref, let value, var node = g[ref.node]?.objectValue else { return }
            var inputs = node["inputs"]?.objectValue ?? [:]
            inputs[ref.input] = value
            node["inputs"] = .object(inputs)
            g[ref.node] = .object(node)
        }
        set(mapping.positive, .string(prompt))
        set(mapping.negative, negative.map(JSONValue.string))
        set(mapping.seed, .number(Double(seed)))
        set(mapping.width, width.map { .number(Double($0)) })
        set(mapping.height, height.map { .number(Double($0)) })
        set(mapping.batch, batch.map { .number(Double($0)) })
        set(mapping.checkpoint, checkpoint.map(JSONValue.string))
        set(mapping.length, length.map { .number(Double($0)) })
        set(mapping.seconds, seconds.map { .number($0) })
        set(mapping.lyrics, lyrics.map(JSONValue.string))
        return g
    }

    /// What the workflow makes, from its output nodes.
    public var outputKind: ComfyOutputKind {
        let classes = Set(graph.values.compactMap { $0.objectValue?["class_type"]?.stringValue })
        if !classes.isDisjoint(with: Self.videoOutputs) { return .video }
        if classes.contains(where: { $0.hasPrefix("SaveAudio") || $0 == "PreviewAudio" }) { return .audio }
        return .image
    }

    /// The video's frame rate, from the workflow (24 when it sets none).
    public var frameRate: Double {
        for ref in mapping.fps {
            if let v = graph[ref.node]?.objectValue?["inputs"]?.objectValue?[ref.input]?.numberValue, v > 0 { return v }
        }
        return 24
    }

    /// Frames for `seconds` of video. LTX needs 8n + 1 frames, which other video models accept too.
    public func frames(forSeconds seconds: Double) -> Int {
        let raw = max(9, Int((seconds * frameRate).rounded()))
        return (raw - 1 + 7) / 8 * 8 + 1
    }

    static let videoOutputs: Set<String> = ["SaveVideo", "CreateVideo", "SaveWEBM", "SaveAnimatedWEBP", "SaveAnimatedPNG", "VHS_VideoCombine"]

    /// True for workflows meant to draw words into the picture (named "… Text", like the Moss starter).
    /// AI Studio then leaves out its "no text" wording.
    public var drawsText: Bool {
        name.range(of: #"\btext\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What SocialForge cannot run without: ["prompt"] when no prompt text input was found.
    public var unmappedRequired: [String] {
        mapping.positive == nil ? ["prompt"] : []
    }

    /// A plain text-to-image graph for SD 1.5 / SDXL checkpoints, the same shape as ComfyUI's default workflow.
    public static func textToImage(checkpoint: String) -> ComfyWorkflow {
        func node(_ cls: String, _ inputs: [String: JSONValue]) -> JSONValue { .object(["class_type": .string(cls), "inputs": .object(inputs)]) }
        func link(_ id: String, _ slot: Int) -> JSONValue { .array([.string(id), .number(Double(slot))]) }
        let graph: [String: JSONValue] = [
            "4": node("CheckpointLoaderSimple", ["ckpt_name": .string(checkpoint)]),
            "5": node("EmptyLatentImage", ["width": .number(1024), "height": .number(1024), "batch_size": .number(1)]),
            "6": node("CLIPTextEncode", ["text": .string(""), "clip": link("4", 1)]),
            "7": node("CLIPTextEncode", ["text": .string("blurry, low quality, watermark, text"), "clip": link("4", 1)]),
            "3": node("KSampler", [
                "seed": .number(0), "steps": .number(25), "cfg": .number(7), "sampler_name": .string("euler"),
                "scheduler": .string("normal"), "denoise": .number(1), "model": link("4", 0),
                "positive": link("6", 0), "negative": link("7", 0), "latent_image": link("5", 0),
            ]),
            "8": node("VAEDecode", ["samples": link("3", 0), "vae": link("4", 2)]),
            "9": node("SaveImage", ["filename_prefix": .string("SocialForge"), "images": link("8", 0)]),
        ]
        return ComfyWorkflow(name: "Text to image", graph: graph, mapping: detectMapping(graph))
    }

    // MARK: Mapping detection

    /// Numeric ids in numeric order, then the rest alphabetically.
    static func sortedIDs<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        ids.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a < b
            }
        }
    }

    static func classType(_ graph: [String: JSONValue], _ id: String) -> String? { graph[id]?.objectValue?["class_type"]?.stringValue }
    static func inputs(_ graph: [String: JSONValue], _ id: String) -> [String: JSONValue] { graph[id]?.objectValue?["inputs"]?.objectValue ?? [:] }

    /// The node id a link input points at. Links are [nodeID, outputSlot].
    static func linkTarget(_ value: JSONValue?) -> String? {
        guard let a = value?.arrayValue, a.count == 2 else { return nil }
        if let s = a[0].stringValue { return s }
        if let n = a[0].numberValue { return String(Int(n)) }
        return nil
    }

    /// Follows conditioning links (through combine, ControlNet, and similar nodes) to the first text encoder.
    /// `role` ("positive" or "negative") is followed first through nodes that carry both, like LTXVConditioning,
    /// so the prompt never lands in the negative encoder.
    static func findTextInput(_ graph: [String: JSONValue], from start: String?, role: String? = nil) -> ComfyInputRef? {
        guard let start else { return nil }
        var queue = [start], seen = Set<String>()
        while !queue.isEmpty, seen.count < 50 {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted, let cls = classType(graph, id) else { continue }
            let ins = inputs(graph, id)
            if cls.contains("TextEncode") {
                for key in ["text", "text_g", "prompt"] where ins[key]?.stringValue != nil { return ComfyInputRef(node: id, input: key) }
            }
            if let role, let next = linkTarget(ins[role]) {
                queue.append(next)
                continue
            }
            for key in ins.keys.sorted() { if let next = linkTarget(ins[key]) { queue.append(next) } }
        }
        return nil
    }

    static let samplerClasses: Set<String> = ["KSampler", "KSamplerAdvanced"]
    static let latentClasses: Set<String> = ["EmptyLatentImage", "EmptySD3LatentImage", "EmptyFlux2LatentImage", "EmptyHunyuanImageLatent", "EmptyLTXVLatentVideo", "EmptyHunyuanLatentVideo",
                                             "EmptyMochiLatentVideo", "EmptyCosmosLatentVideo", "EmptyAceStepLatentAudio",
                                             "EmptyYuE2LatentAudio"]

    static func detectMapping(_ graph: [String: JSONValue]) -> ComfyMapping {
        var m = ComfyMapping()
        let ids = sortedIDs(graph.keys)
        if let sampler = ids.first(where: { samplerClasses.contains(classType(graph, $0) ?? "") }) {
            let ins = inputs(graph, sampler)
            if ins["seed"] != nil { m.seed = ComfyInputRef(node: sampler, input: "seed") }
            else if ins["noise_seed"] != nil { m.seed = ComfyInputRef(node: sampler, input: "noise_seed") }
            m.positive = findTextInput(graph, from: linkTarget(ins["positive"]), role: "positive")
            m.negative = findTextInput(graph, from: linkTarget(ins["negative"]), role: "negative")
            if m.negative == m.positive { m.negative = nil }
            if let latent = linkTarget(ins["latent_image"]), latentClasses.contains(classType(graph, latent) ?? "") {
                fillLatent(&m, graph, latent)
            }
        }
        if m.width == nil, let latent = ids.first(where: { latentClasses.contains(classType(graph, $0) ?? "") }) {
            fillLatent(&m, graph, latent)
        }
        if let ckpt = ids.first(where: { classType(graph, $0) == "CheckpointLoaderSimple" }), inputs(graph, ckpt)["ckpt_name"]?.stringValue != nil {
            m.checkpoint = ComfyInputRef(node: ckpt, input: "ckpt_name")
        }
        // Music nodes (YuE, ACE-Step) take a style or tags line and lyrics instead of a text encoder.
        if let music = ids.first(where: { inputs(graph, $0)["lyrics"]?.stringValue != nil }) {
            let ins = inputs(graph, music)
            m.lyrics = ComfyInputRef(node: music, input: "lyrics")
            if m.positive == nil {
                for key in ["style", "tags", "genre"] where ins[key]?.stringValue != nil { m.positive = ComfyInputRef(node: music, input: key); break }
            }
            if m.negative?.node == music { m.negative = nil }
            if m.seconds == nil {
                for key in ["max_duration", "seconds", "duration"] where ins[key]?.numberValue != nil { m.seconds = ComfyInputRef(node: music, input: key); break }
            }
        }
        // Frame rate, wherever it is set (LTXVConditioning frame_rate, CreateVideo fps).
        for id in ids {
            let ins = inputs(graph, id)
            for key in ["frame_rate", "fps"] where ins[key]?.numberValue != nil { m.fps.append(ComfyInputRef(node: id, input: key)) }
        }
        if m.positive != nil, m.positive == m.negative { m.negative = nil }
        return m
    }

    static func fillLatent(_ m: inout ComfyMapping, _ graph: [String: JSONValue], _ id: String) {
        let ins = inputs(graph, id)
        if ins["width"]?.numberValue != nil { m.width = ComfyInputRef(node: id, input: "width") }
        if ins["height"]?.numberValue != nil { m.height = ComfyInputRef(node: id, input: "height") }
        if ins["batch_size"]?.numberValue != nil { m.batch = ComfyInputRef(node: id, input: "batch_size") }
        if ins["length"]?.numberValue != nil { m.length = ComfyInputRef(node: id, input: "length") }
        if ins["seconds"]?.numberValue != nil { m.seconds = ComfyInputRef(node: id, input: "seconds") }
    }
}

public enum ComfyOutputKind: String, Sendable { case image, video, audio
    public var noun: String { switch self { case .image: "image"; case .video: "video"; case .audio: "track" } }
}

/// A finished output file: its name on the ComfyUI server (with the real extension) and its bytes.
public struct ComfyOutputFile: Sendable, Equatable {
    public var filename: String
    public var data: Data
}

public struct ComfyOutputImage: Codable, Sendable, Equatable {
    public var filename: String
    public var subfolder: String
    public var type: String
    public init(filename: String, subfolder: String, type: String) { self.filename = filename; self.subfolder = subfolder; self.type = type }
}

public struct ComfyProgress: Sendable, Equatable {
    public var value: Int
    public var max: Int
    public var node: String?
    public init(value: Int, max: Int, node: String?) { self.value = value; self.max = max; self.node = node }

    /// Reads a `{"type":"progress","data":{"value","max","node"}}` socket message. Nil for other messages.
    static func parse(_ text: String) -> ComfyProgress? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              obj["type"] as? String == "progress", let data = obj["data"] as? [String: Any],
              let value = (data["value"] as? NSNumber)?.intValue, let max = (data["max"] as? NSNumber)?.intValue else { return nil }
        let node = (data["node"] as? String) ?? (data["node"] as? NSNumber)?.stringValue
        return ComfyProgress(value: value, max: max, node: node)
    }
}

// MARK: - Client

public struct ComfyUIClient: Sendable {
    public struct SystemStats: Codable, Sendable, Equatable {
        public struct System: Codable, Sendable, Equatable {
            public let os: String?
            public let comfyui_version: String?
            public let python_version: String?
        }
        public struct Device: Codable, Sendable, Equatable {
            public let name: String
            public let type: String?
            public let vram_total: Int64?
            public let vram_free: Int64?
        }
        public let system: System
        public let devices: [Device]
    }

    public enum ClientError: Error, Equatable, LocalizedError {
        case http(Int, String)
        case badResponse(String)
        /// ComfyUI rejected the workflow (HTTP 400 on /prompt); the text lists each node's errors.
        case invalidWorkflow(String)
        /// The job ran and failed on the server.
        case executionFailed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .http(let code, let msg): "ComfyUI answered \(code): \(msg)"
            case .badResponse(let why): "Unexpected answer from ComfyUI: \(why)"
            case .invalidWorkflow(let why): "ComfyUI rejected the workflow: \(why)"
            case .executionFailed(let why): "The ComfyUI job failed: \(why)"
            case .timedOut: "ComfyUI did not finish in time. The job was stopped."
            }
        }
    }

    public let baseURL: URL
    /// Sent as a bearer token, for servers behind an authenticating proxy.
    public let token: String?
    let session: URLSession

    public init(baseURL: URL) { self.init(baseURL: baseURL, token: nil) }

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    /// Remote servers must use HTTPS; plain HTTP is allowed only for this Mac and the local network.
    public static func transportProblem(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return "Enter a full address, like http://127.0.0.1:8188." }
        if scheme == "https" { return nil }
        guard scheme == "http" else { return "Use http:// or https://." }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.") || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        return local ? nil : "Remote ComfyUI servers must use https:// so prompts and images are not sent in the clear."
    }

    public func systemStats() async throws -> SystemStats {
        let (data, _) = try await send(request("system_stats", timeout: 5))
        return try JSONDecoder().decode(SystemStats.self, from: data)
    }

    /// Checkpoint file names the server offers.
    public func checkpoints() async throws -> [String] {
        let (data, _) = try await send(request("object_info/CheckpointLoaderSimple"))
        let obj = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let names = obj.objectValue?["CheckpointLoaderSimple"]?.objectValue?["input"]?.objectValue?["required"]?
            .objectValue?["ckpt_name"]?.arrayValue?.first?.arrayValue else {
            throw ClientError.badResponse("no checkpoint list")
        }
        return names.compactMap(\.stringValue)
    }

    /// Queues a graph and returns its prompt id.
    public func submit(graph: [String: JSONValue], clientID: String) async throws -> String {
        let body = try JSONEncoder().encode(JSONValue.object(["prompt": .object(graph), "client_id": .string(clientID)]))
        var req = request("prompt", method: "POST")
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 { throw ClientError.invalidWorkflow(Self.nodeErrorText(data)) }
        guard (200..<300).contains(status) else { throw ClientError.http(status, Self.bodyText(data)) }
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?["prompt_id"]?.stringValue else {
            throw ClientError.badResponse("no prompt_id")
        }
        return id
    }

    /// The finished job's images, or nil while it is still queued or running.
    public func outputs(promptID: String) async throws -> [ComfyOutputImage]? {
        let (data, _) = try await send(request("history/\(promptID)"))
        let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let entry = root[promptID]?.objectValue else { return nil }
        if let status = entry["status"]?.objectValue, status["status_str"]?.stringValue == "error" {
            throw ClientError.executionFailed(Self.executionErrorText(status))
        }
        let outputs = entry["outputs"]?.objectValue ?? [:]
        var images: [ComfyOutputImage] = []
        for node in ComfyWorkflow.sortedIDs(outputs.keys) {
            // Images under "images"; core SaveVideo and SaveAudio too; VHS uses "gifs".
            let node = outputs[node]?.objectValue ?? [:]
            for item in ["images", "gifs", "videos", "audio"].flatMap({ node[$0]?.arrayValue ?? [] }) {
                guard let o = item.objectValue, let name = o["filename"]?.stringValue else { continue }
                images.append(ComfyOutputImage(filename: name, subfolder: o["subfolder"]?.stringValue ?? "", type: o["type"]?.stringValue ?? "output"))
            }
        }
        return images
    }

    public func image(_ o: ComfyOutputImage) async throws -> Data {
        let req = request("view", query: [
            URLQueryItem(name: "filename", value: o.filename), URLQueryItem(name: "subfolder", value: o.subfolder),
            URLQueryItem(name: "type", value: o.type),
        ], timeout: 60)
        return try await send(req).0
    }

    /// Stops the job that is running now.
    public func interrupt() async throws {
        _ = try await send(request("interrupt", method: "POST"))
    }

    /// Uploads an input image and returns the name to put in a LoadImage node.
    public func uploadImage(_ data: Data, filename: String) async throws -> String {
        let boundary = "SocialForge-\(UUID().uuidString)"
        let safeName = filename.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("upload/image", method: "POST", timeout: 120)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (resp, _) = try await send(req)
        guard let obj = (try? JSONDecoder().decode(JSONValue.self, from: resp))?.objectValue, let name = obj["name"]?.stringValue else {
            throw ClientError.badResponse("no stored name")
        }
        let sub = obj["subfolder"]?.stringValue ?? ""
        return sub.isEmpty ? name : "\(sub)/\(name)"
    }

    /// Progress messages for jobs submitted with this client id. Ends when the socket closes or fails.
    public func progress(clientID: String) -> AsyncStream<ComfyProgress> {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return AsyncStream { $0.finish() } }
        comps.scheme = comps.scheme?.lowercased() == "https" ? "wss" : "ws"
        var path = comps.path
        if !path.hasSuffix("/") { path += "/" }
        comps.path = path + "ws"
        comps.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        guard let url = comps.url else { return AsyncStream { $0.finish() } }
        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.webSocketTask(with: req)

        return AsyncStream { continuation in
            let reader = Task {
                task.resume()
                while !Task.isCancelled {
                    do {
                        let message = try await task.receive()
                        if case .string(let text) = message, let p = ComfyProgress.parse(text) { continuation.yield(p) }
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Submits the graph, waits for it, and downloads every output image.
    /// Cancelling the calling task, or running past `timeout`, stops the job on the server.
    /// Pass the same `clientID` to `progress(clientID:)` to watch this job's sampling steps.
    public func run(graph: [String: JSONValue], clientID: String = UUID().uuidString, pollEvery: Duration = .seconds(1), timeout: Duration = .seconds(600)) async throws -> [Data] {
        try await runFiles(graph: graph, clientID: clientID, pollEvery: pollEvery, timeout: timeout).map(\.data)
    }

    /// Like `run`, keeping each output's file name, so videos and audio keep their real type.
    public func runFiles(graph: [String: JSONValue], clientID: String = UUID().uuidString, pollEvery: Duration = .seconds(1),
                         timeout: Duration = .seconds(600)) async throws -> [ComfyOutputFile] {
        let promptID = try await submit(graph: graph, clientID: clientID)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while true {
                try Task.checkCancellation()
                if let images = try await outputs(promptID: promptID) {
                    var out: [ComfyOutputFile] = []
                    for o in images { out.append(ComfyOutputFile(filename: o.filename, data: try await image(o))) }
                    return out
                }
                if ContinuousClock.now >= deadline {
                    await stop(promptID: promptID)
                    throw ClientError.timedOut
                }
                try await Task.sleep(for: pollEvery)
            }
        } catch {
            if Task.isCancelled {
                await stop(promptID: promptID)
                throw CancellationError()
            }
            throw error
        }
    }

    // MARK: Plumbing

    /// Removes the prompt from the queue and interrupts it if it is running.
    /// Runs in its own task so it still goes out after the caller was cancelled.
    func stop(promptID: String) async {
        let client = self
        await Task {
            var del = client.request("queue", method: "POST")
            del.setValue("application/json", forHTTPHeaderField: "Content-Type")
            del.httpBody = try? JSONEncoder().encode(JSONValue.object(["delete": .array([.string(promptID)])]))
            _ = try? await client.send(del)
            var intr = client.request("interrupt", method: "POST")
            intr.setValue("application/json", forHTTPHeaderField: "Content-Type")
            intr.httpBody = try? JSONEncoder().encode(JSONValue.object(["prompt_id": .string(promptID)]))
            _ = try? await client.send(intr)
        }.value
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem]? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var url = baseURL.appending(path: path)
        if let query { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode, Self.bodyText(data)) }
        return (data, http)
    }

    static func bodyText(_ data: Data) -> String {
        if let obj = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue {
            if let m = obj["error"]?.objectValue?["message"]?.stringValue { return m }
            if let m = obj["error"]?.stringValue { return m }
        }
        let s = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "no details" : s
    }

    /// `{"error": {"message", "details"}, "node_errors": {id: {"class_type", "errors": [{"message", "details"}]}}}` as readable lines.
    static func nodeErrorText(_ data: Data) -> String {
        guard let obj = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else { return bodyText(data) }
        var lines: [String] = []
        if let e = obj["error"]?.objectValue {
            let msg = e["message"]?.stringValue ?? "Invalid workflow"
            let details = e["details"]?.stringValue ?? ""
            lines.append(details.isEmpty ? msg : "\(msg): \(details)")
        }
        let nodes = obj["node_errors"]?.objectValue ?? [:]
        for id in ComfyWorkflow.sortedIDs(nodes.keys) {
            guard let n = nodes[id]?.objectValue else { continue }
            let cls = n["class_type"]?.stringValue.map { " (\($0))" } ?? ""
            for err in n["errors"]?.arrayValue ?? [] {
                guard let e = err.objectValue else { continue }
                let msg = e["message"]?.stringValue ?? "error"
                let details = e["details"]?.stringValue ?? ""
                lines.append("Node \(id)\(cls): \(msg)" + (details.isEmpty ? "" : ": \(details)"))
            }
        }
        return lines.isEmpty ? bodyText(data) : lines.joined(separator: "\n")
    }

    static func executionErrorText(_ status: [String: JSONValue]) -> String {
        for msg in status["messages"]?.arrayValue ?? [] {
            guard let pair = msg.arrayValue, pair.count == 2, pair[0].stringValue == "execution_error", let d = pair[1].objectValue else { continue }
            let node = d["node_type"]?.stringValue.map { "\($0): " } ?? ""
            return node + (d["exception_message"]?.stringValue ?? "unknown error")
        }
        return "unknown error"
    }
}

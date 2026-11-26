import Foundation

// Text and image generation through the providers people bring their own keys for.
//
// UNVERIFIED: none of these live integrations has been run against the real
// services (no keys were available while writing them). The request and
// response shapes follow each provider's public documentation and are covered
// by stubbed tests only. Treat a first real call as the real test.
//
// Keys are only ever placed in request headers. They are never logged, never
// put in URLs, and never copied into error messages.

public enum AIProviderID: String, CaseIterable, Codable, Sendable {
    case openai, anthropic, gemini, openaiCompatible, comfyui

    public var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openaiCompatible: "OpenAI-compatible (local)"
        case .comfyui: "ComfyUI"
        }
    }

    /// Local OpenAI-compatible servers (Ollama, LM Studio) and ComfyUI work without a key.
    public var needsKey: Bool {
        switch self {
        case .openai, .anthropic, .gemini: true
        case .openaiCompatible, .comfyui: false
        }
    }

    public var supportsText: Bool { self != .comfyui }

    /// ComfyUI images go through `ComfyUIClient`, not `ImageProvider`.
    public var supportsImage: Bool {
        switch self {
        case .openai, .openaiCompatible, .comfyui: true
        case .anthropic, .gemini: false
        }
    }
}

public struct AIProviderConfig: Codable, Sendable, Equatable {
    public var id: AIProviderID
    /// Scheme and host, optionally with a path. `/v1` is added when missing.
    public var baseURL: String
    public var textModel: String
    public var imageModel: String

    public init(id: AIProviderID, baseURL: String, textModel: String, imageModel: String) {
        self.id = id; self.baseURL = baseURL; self.textModel = textModel; self.imageModel = imageModel
    }

    /// Starting values for Settings. Every model name except Anthropic's is a
    /// default; verify against the provider's current model list.
    public static func defaults(for id: AIProviderID) -> AIProviderConfig {
        switch id {
        case .openai:
            // Text model: default; verify against the provider's current model list.
            AIProviderConfig(id: id, baseURL: "https://api.openai.com", textModel: "gpt-5-mini", imageModel: "gpt-image-1")
        case .anthropic:
            // Claude Haiku 5.5, the current Haiku-class model. People can pick another in Settings.
            AIProviderConfig(id: id, baseURL: "https://api.anthropic.com", textModel: "claude-haiku-5-5", imageModel: "")
        case .gemini:
            // Default; verify against the provider's current model list.
            AIProviderConfig(id: id, baseURL: "https://generativelanguage.googleapis.com", textModel: "gemini-2.5-flash", imageModel: "")
        case .openaiCompatible:
            // Ollama's default port. Default; verify against the models installed on that server.
            AIProviderConfig(id: id, baseURL: "http://127.0.0.1:11434", textModel: "llama3.2", imageModel: "")
        case .comfyui:
            AIProviderConfig(id: id, baseURL: "http://127.0.0.1:8188", textModel: "", imageModel: "")
        }
    }
}

/// Token counts exactly as the provider reported them. Nil when it did not say.
/// SocialForge never estimates prices from these.
public struct AIUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cachedTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil, cachedTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedTokens = cachedTokens
    }
}

public struct AITextResult: Sendable, Equatable {
    public var text: String
    public var usage: AIUsage
    public init(text: String, usage: AIUsage) { self.text = text; self.usage = usage }
}

public enum AIError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case unreachable(String)
    case badResponse(String)
    case refused(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let why): "AI is not set up: \(why)"
        case .http(let code, let msg): "The AI service answered \(code): \(msg)"
        case .unreachable(let why): "Could not reach the AI service: \(why)"
        case .badResponse(let why): "The AI service sent an answer SocialForge could not use: \(why)"
        case .refused(let why): "The AI service declined this request: \(why)"
        case .cancelled: "The AI request was cancelled."
        }
    }
}

public protocol TextProvider: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws(AIError) -> AITextResult
}

public protocol ImageProvider: Sendable {
    func generate(prompt: String, width: Int, height: Int, count: Int) async throws(AIError) -> (images: [Data], usage: AIUsage)
}

/// Nil for ComfyUI, which has no text model.
public func makeTextProvider(_ config: AIProviderConfig, apiKey: String?, session: URLSession = .shared) -> (any TextProvider)? {
    let http = AIHTTP(config: config, apiKey: apiKey, session: session)
    switch config.id {
    case .openai, .openaiCompatible: return OpenAIChatProvider(http: http)
    case .anthropic: return AnthropicMessagesProvider(http: http)
    case .gemini: return GeminiProvider(http: http)
    case .comfyui: return nil
    }
}

/// OpenAI and OpenAI-compatible image servers. Nil for the rest; ComfyUI goes through `ComfyUIClient`.
public func makeImageProvider(_ config: AIProviderConfig, apiKey: String?, session: URLSession = .shared) -> (any ImageProvider)? {
    switch config.id {
    case .openai, .openaiCompatible:
        guard !config.imageModel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return OpenAIImageProvider(http: AIHTTP(config: config, apiKey: apiKey, session: session))
    case .anthropic, .gemini, .comfyui:
        return nil
    }
}

/// Discovers available models from the configured provider (OpenAI, Anthropic, Gemini, Ollama, LM Studio, or compatible endpoint).
public func discoverAIModels(_ config: AIProviderConfig, apiKey: String?, session: URLSession = .shared) async throws(AIError) -> [String] {
    let http = AIHTTP(config: config, apiKey: apiKey, session: session)
    let key = try http.requireKey()
    switch config.id {
    case .openai, .openaiCompatible:
        var headers: [String: String] = [:]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        do {
            let obj = try await http.getJSON(try http.url("models"), headers: headers, timeout: 15)
            if let data = obj["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.sorted()
                if !ids.isEmpty { return ids }
            }
        } catch {
            // Ollama also exposes /api/tags even if /v1/models is unavailable.
            if config.id == .openaiCompatible, let tagsURL = try? http.rawURL("api/tags") {
                let obj = try await http.getJSON(tagsURL, headers: headers, timeout: 15)
                if let models = obj["models"] as? [[String: Any]] {
                    return models.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }.sorted()
                }
            }
            throw error
        }
        return []
    case .anthropic:
        var headers = ["anthropic-version": AnthropicMessagesProvider.apiVersion]
        if let key { headers["x-api-key"] = key }
        let obj = try await http.getJSON(try http.url("models"), headers: headers, timeout: 15)
        let data = obj["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }.sorted()
    case .gemini:
        var headers: [String: String] = [:]
        if let key { headers["x-goog-api-key"] = key }
        let obj = try await http.getJSON(try http.url("models", version: "v1beta"), headers: headers, timeout: 15)
        let models = obj["models"] as? [[String: Any]] ?? []
        return models.compactMap { item -> String? in
            guard let name = item["name"] as? String else { return nil }
            let methods = item["supportedGenerationMethods"] as? [String] ?? []
            if !methods.isEmpty && !methods.contains("generateContent") { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }.sorted()
    case .comfyui:
        return []
    }
}

/// Validates that remote AI endpoints use HTTPS (HTTP is permitted only on localhost or private LAN).
public func aiEndpointTransportProblem(_ rawURL: String) -> String? {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
        return "Enter a full URL such as https://api.openai.com or http://127.0.0.1:11434."
    }
    if scheme == "https" { return nil }
    guard scheme == "http" else { return "Use https:// or http://." }
    let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
        || host.hasPrefix("192.168.") || host.hasPrefix("10.")
        || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
    return local ? nil : "Remote AI endpoints must use https:// so API keys and prompts are not sent in the clear."
}

// MARK: - HTTP plumbing

struct AIHTTP: Sendable {
    let config: AIProviderConfig
    let apiKey: String?
    let session: URLSession

    var key: String? {
        guard let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }

    func requireKey() throws(AIError) -> String? {
        if config.id.needsKey, key == nil { throw .notConfigured("Add a \(config.id.displayName) key in Connections or Settings.") }
        return key
    }

    private func validatedComponents() throws(AIError) -> URLComponents {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = aiEndpointTransportProblem(trimmed) {
            throw .notConfigured(problem)
        }
        guard let comps = URLComponents(string: trimmed), comps.host?.isEmpty == false else {
            throw .notConfigured("Enter a full address for \(config.id.displayName), like https://api.example.com.")
        }
        return comps
    }

    /// `{base}/{version}/{path}`, without doubling a version segment the person already typed.
    func url(_ path: String, version: String = "v1") throws(AIError) -> URL {
        var comps = try validatedComponents()
        var base = comps.path
        while base.hasSuffix("/") { base.removeLast() }
        let hasVersionSuffix = base.hasSuffix("/" + version)
            || base.range(of: #"/v\d+(beta)?$"#, options: .regularExpression) != nil
        if !hasVersionSuffix { base += "/" + version }
        comps.path = base + "/" + path
        comps.query = nil
        guard let url = comps.url else { throw .notConfigured("The address for \(config.id.displayName) is not valid.") }
        return url
    }

    /// `{base}/{path}` without inserting `/v1` (e.g. Ollama `/api/tags`).
    func rawURL(_ path: String) throws(AIError) -> URL {
        var comps = try validatedComponents()
        var base = comps.path
        while base.hasSuffix("/") { base.removeLast() }
        comps.path = base + "/" + path
        comps.query = nil
        guard let url = comps.url else { throw .notConfigured("The address for \(config.id.displayName) is not valid.") }
        return url
    }

    func getJSON(_ url: URL, headers: [String: String], timeout: TimeInterval = 30) async throws(AIError) -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await sendJSON(req)
    }

    func postJSON(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval = 120) async throws(AIError) -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do { req.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw .badResponse("could not encode the request") }
        return try await sendJSON(req)
    }

    private func sendJSON(_ req: URLRequest) async throws(AIError) -> [String: Any] {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: req) } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw .cancelled }
                throw .unreachable(redact(error.localizedDescription))
            }
            guard let http = response as? HTTPURLResponse else { throw .unreachable("no HTTP response") }
            if (200..<300).contains(http.statusCode) {
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw .badResponse("the answer was not JSON")
                }
                return obj
            }
            if http.statusCode == 401 {
                throw .http(401, "The key was rejected. Check the \(config.id.displayName) key in Connections or Settings.")
            }
            if http.statusCode == 403 {
                let detail = Self.errorMessage(data).map { redact($0) }
                let msg = detail.map { "Permission or billing denied: \($0)" }
                    ?? "Access forbidden for \(config.id.displayName). Check API permissions, billing, or region."
                throw .http(403, msg)
            }
            let retryable = [429, 502, 503, 504].contains(http.statusCode)
            if retryable && attempt < maxAttempts {
                let retryHeader = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = min(max(retryHeader ?? Double(attempt) * 1.5, 0.25), 10.0)
                do { try await Task.sleep(for: .seconds(delay)) } catch { throw .cancelled }
                continue
            }
            throw .http(http.statusCode, redact(Self.errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))
        }
        throw .unreachable("request failed after retries")
    }

    /// Never echo the key or bearer tokens back, even if a provider includes them in an error.
    func redact(_ s: String) -> String {
        var out = s
        if let key, key.count >= 4 { out = out.replacingOccurrences(of: key, with: "[key]") }
        out = DiagnosticRedactor.sanitize(out, secrets: key.map { [$0] } ?? [])
        return String(out.prefix(400))
    }

    /// `{"error":{"message":…}}` (OpenAI, Anthropic, Gemini) or `{"error":"…"}` (some local servers).
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let s = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = obj["error"] as? String { return e }
        if let m = obj["message"] as? String { return m }
        return nil
    }
}

func intValue(_ any: Any?) -> Int? {
    if let n = any as? NSNumber { return n.intValue }
    return nil
}

// MARK: - OpenAI Chat Completions (and compatible local servers)

/// `POST {base}/v1/chat/completions`. Unverified against the live service.
struct OpenAIChatProvider: TextProvider {
    let http: AIHTTP

    func complete(system: String, user: String, maxTokens: Int) async throws(AIError) -> AITextResult {
        let key = try http.requireKey()
        let model = http.config.textModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw .notConfigured("Choose a text model for \(http.config.id.displayName).") }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        // OpenAI's newer models take max_completion_tokens; local servers still read max_tokens.
        body[http.config.id == .openai ? "max_completion_tokens" : "max_tokens"] = maxTokens
        var headers: [String: String] = [:]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        let obj = try await http.postJSON(try http.url("chat/completions"), body: body, headers: headers)

        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw .badResponse("no choices in the answer")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw .refused(http.redact(refusal)) }
        if choice["finish_reason"] as? String == "content_filter" { throw .refused("The content filter stopped the answer.") }
        let text = message["content"] as? String ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .badResponse("the answer was empty") }
        let usage = obj["usage"] as? [String: Any]
        let compDetails = usage?["completion_tokens_details"] as? [String: Any]
        let promptDetails = usage?["prompt_tokens_details"] as? [String: Any]
        return AITextResult(text: text, usage: AIUsage(
            inputTokens: intValue(usage?["prompt_tokens"]),
            outputTokens: intValue(usage?["completion_tokens"]),
            reasoningTokens: intValue(compDetails?["reasoning_tokens"]),
            cachedTokens: intValue(promptDetails?["cached_tokens"])
        ))
    }
}

// MARK: - Anthropic Messages

/// `POST {base}/v1/messages` with `x-api-key` and `anthropic-version`. Unverified against the live service.
struct AnthropicMessagesProvider: TextProvider {
    static let apiVersion = "2026-10-21"
    let http: AIHTTP

    func complete(system: String, user: String, maxTokens: Int) async throws(AIError) -> AITextResult {
        let key = try http.requireKey()
        let model = http.config.textModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw .notConfigured("Choose a text model for Anthropic.") }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var headers = ["anthropic-version": Self.apiVersion]
        if let key { headers["x-api-key"] = key }
        let obj = try await http.postJSON(try http.url("messages"), body: body, headers: headers)

        let stop = obj["stop_reason"] as? String
        if stop == "refusal" {
            let details = obj["stop_details"] as? [String: Any]
            throw .refused(http.redact((details?["explanation"] as? String) ?? "The model declined to answer."))
        }
        // Thinking blocks are skipped; only text blocks are the answer.
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .badResponse(stop == "max_tokens" ? "the answer was cut off before any text" : "the answer was empty")
        }
        let usage = obj["usage"] as? [String: Any]
        return AITextResult(text: text, usage: AIUsage(
            inputTokens: intValue(usage?["input_tokens"]),
            outputTokens: intValue(usage?["output_tokens"]),
            cachedTokens: intValue(usage?["cache_read_input_tokens"])
        ))
    }
}

// MARK: - Gemini generateContent

/// `POST {base}/v1beta/models/{model}:generateContent` with `x-goog-api-key`. Unverified against the live service.
struct GeminiProvider: TextProvider {
    let http: AIHTTP

    func complete(system: String, user: String, maxTokens: Int) async throws(AIError) -> AITextResult {
        let key = try http.requireKey()
        let model = http.config.textModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, model.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else {
            throw .notConfigured("Choose a text model for Gemini.")
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": maxTokens],
        ]
        var headers: [String: String] = [:]
        if let key { headers["x-goog-api-key"] = key }
        let obj = try await http.postJSON(try http.url("models/\(model):generateContent", version: "v1beta"), body: body, headers: headers)

        if let feedback = obj["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw .refused("Blocked: \(reason)")
        }
        guard let candidate = (obj["candidates"] as? [[String: Any]])?.first else { throw .badResponse("no candidates in the answer") }
        if let reason = candidate["finishReason"] as? String, ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(reason) {
            throw .refused("Blocked: \(reason)")
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .badResponse("the answer was empty") }
        let usage = obj["usageMetadata"] as? [String: Any]
        return AITextResult(text: text, usage: AIUsage(
            inputTokens: intValue(usage?["promptTokenCount"]),
            outputTokens: intValue(usage?["candidatesTokenCount"]),
            reasoningTokens: intValue(usage?["thoughtsTokenCount"]),
            cachedTokens: intValue(usage?["cachedContentTokenCount"])
        ))
    }
}

// MARK: - OpenAI Images

/// `POST {base}/v1/images/generations`, reading `b64_json`. Unverified against the live service.
struct OpenAIImageProvider: ImageProvider {
    let http: AIHTTP

    /// Picks the closest accepted aspect size for OpenAI image models (gpt-image-1 vs dall-e-3 / dall-e-2).
    static func openAISize(width: Int, height: Int, model: String = "gpt-image-1") -> String {
        let lower = model.lowercased()
        let w = Double(max(width, 1)), h = Double(max(height, 1))
        if lower.hasPrefix("dall-e-2") { return "1024x1024" }
        if lower.hasPrefix("dall-e-3") {
            if w / h >= 1.2 { return "1792x1024" }
            if h / w >= 1.2 { return "1024x1792" }
            return "1024x1024"
        }
        if w / h >= 1.2 { return "1536x1024" }
        if h / w >= 1.2 { return "1024x1536" }
        return "1024x1024"
    }

    func generate(prompt: String, width: Int, height: Int, count: Int) async throws(AIError) -> (images: [Data], usage: AIUsage) {
        let key = try http.requireKey()
        let model = http.config.imageModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw .notConfigured("Choose an image model for \(http.config.id.displayName).") }
        let lower = model.lowercased()
        let effectiveCount = lower.hasPrefix("dall-e-3") ? 1 : max(1, min(count, 10))
        var body: [String: Any] = ["model": model, "prompt": prompt, "n": effectiveCount]
        if http.config.id == .openai {
            body["size"] = Self.openAISize(width: width, height: height, model: model)
            if lower.hasPrefix("dall-e-") {
                body["response_format"] = "b64_json"
            }
        } else {
            body["size"] = "\(width)x\(height)"
            body["response_format"] = "b64_json"
        }
        var headers: [String: String] = [:]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        let obj = try await http.postJSON(try http.url("images/generations"), body: body, headers: headers, timeout: 300)

        let items = obj["data"] as? [[String: Any]] ?? []
        let images = items.compactMap { ($0["b64_json"] as? String).flatMap { Data(base64Encoded: $0) } }
        guard !images.isEmpty else { throw .badResponse("no images in the answer") }
        let usage = obj["usage"] as? [String: Any]
        return (images, AIUsage(inputTokens: intValue(usage?["input_tokens"]), outputTokens: intValue(usage?["output_tokens"])))
    }
}

// MARK: - JSON in model answers

enum AIJSON {
    /// The first complete JSON object in a model answer, ignoring ```json fences and prose around it.
    static func firstObject(in text: String) -> [String: Any]? {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count {
            guard let open = scalars[start...].firstIndex(of: "{") else { return nil }
            var depth = 0, inString = false, escaped = false
            var i = open
            while i < scalars.count {
                let c = scalars[i]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        var s = String.UnicodeScalarView()
                        s.append(contentsOf: scalars[open...i])
                        if let obj = (try? JSONSerialization.jsonObject(with: Data(String(s).utf8))) as? [String: Any] { return obj }
                        break
                    }
                }
                i += 1
            }
            start = open + 1
        }
        return nil
    }

    /// JSON text for untrusted values, with `<` and `>` escaped so the value can never close a delimiting tag.
    static func dataBlock(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}

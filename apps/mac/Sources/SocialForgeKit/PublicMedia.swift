import CryptoKit
import Foundation

// Public media storage: an S3-compatible bucket (Cloudflare R2, AWS S3, MinIO…)
// whose files can be read at a public address. Instagram photos and Threads
// media are fetched by Meta from a URL, so they need it; Reels and Facebook
// uploads go straight from this Mac and do not.

/// A file placed where a platform can fetch it.
public struct PublicMedia: Sendable, Equatable {
    public let url: URL
    public let key: String
    public init(url: URL, key: String) { self.url = url; self.key = key }
}

public protocol PublicMediaHost: Sendable {
    func put(file: URL, contentType: String) async throws(PublishFailure) -> PublicMedia
    /// Best effort: removes a file once the platform has fetched it.
    func delete(key: String) async
}

public enum S3AddressingStyle: String, Sendable, Codable, CaseIterable {
    case auto
    case pathStyle
    case virtualHosted
}

public struct S3Config: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// The S3 API endpoint, such as https://<account>.r2.cloudflarestorage.com.
    public var endpoint: URL
    public var bucket: String
    /// "auto" for Cloudflare R2.
    public var region: String
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Where the bucket's files are readable, such as https://pub-xxxx.r2.dev or https://media.example.com.
    public var publicBaseURL: URL
    public var prefix: String
    public var addressingStyle: S3AddressingStyle

    public init(id: String = "default", name: String = "Default Storage", endpoint: URL, bucket: String, region: String,
                accessKeyID: String, secretAccessKey: String, publicBaseURL: URL, prefix: String = "socialforge",
                addressingStyle: S3AddressingStyle = .auto) {
        self.id = id; self.name = name
        self.endpoint = endpoint; self.bucket = bucket; self.region = region
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey
        self.publicBaseURL = publicBaseURL; self.prefix = prefix; self.addressingStyle = addressingStyle
    }

    /// Nil unless every field is filled and both addresses are https.
    public static func make(id: String = "default", name: String = "Default Storage", endpoint: String, bucket: String,
                            region: String, accessKeyID: String, secret: String, publicBase: String,
                            prefix: String = "socialforge", addressingStyle: S3AddressingStyle = .auto) -> S3Config? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func https(_ s: String) -> URL? {
            let trimmed = clean(s).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let u = URL(string: trimmed), u.scheme == "https", let h = u.host, !h.isEmpty else { return nil }
            return u
        }
        let b = clean(bucket).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let r = clean(region)
        let ak = clean(accessKeyID)
        let sk = clean(secret)
        let px = clean(prefix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let e = https(endpoint), let p = https(publicBase), !b.isEmpty, !r.isEmpty, !ak.isEmpty, !sk.isEmpty else { return nil }
        return S3Config(id: id, name: name, endpoint: e, bucket: b, region: r, accessKeyID: ak, secretAccessKey: sk,
                        publicBaseURL: p, prefix: px.isEmpty ? "socialforge" : px, addressingStyle: addressingStyle)
    }
}

public struct PublicMediaVerification: Sendable, Equatable {
    public let uploadOK: Bool
    public let downloadOK: Bool
    public let contentTypeOK: Bool
    public let deleteOK: Bool
    public let publicURL: String?
    public let summary: String
    public let error: String?

    public var passed: Bool { uploadOK && downloadOK && contentTypeOK && deleteOK }
}

/// AWS Signature Version 4 for S3 requests.
public enum SigV4 {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let dateLock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func hmac(_ key: Data, _ s: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: key))) }

    /// RFC 3986 encoding of each path segment, keeping "/".
    static func encodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/")
        return path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    public static func amzDate(_ date: Date) -> String {
        dateLock.withLock { formatter.string(from: date) }
    }

    /// The Authorization header value. `headers` must include host, x-amz-date, and x-amz-content-sha256
    /// (all are signed); `path` is the raw, unencoded path; `query` is already canonical.
    public static func authorization(method: String, path: String, query: String = "", headers: [String: String],
                                     payloadHash: String, region: String, service: String = "s3",
                                     accessKeyID: String, secret: String) -> String {
        var lower: [String: String] = [:]
        for (k, v) in headers {
            lower[k.lowercased()] = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = lower.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lower[$0] ?? "")\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [method, encodePath(path), query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let amzDate = lower["x-amz-date"] ?? ""
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(secret)".utf8), day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, toSign))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}

/// Puts files in an S3-compatible bucket (path-style or virtual-hosted) and returns their public address.
public struct S3Uploader: PublicMediaHost {
    public let config: S3Config
    let session: URLSession

    public init(config: S3Config, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    var usesVirtualHosted: Bool {
        switch config.addressingStyle {
        case .pathStyle: return false
        case .virtualHosted: return true
        case .auto:
            let host = config.endpoint.host?.lowercased() ?? ""
            return host.hasSuffix(".amazonaws.com") && !host.hasPrefix("\(config.bucket.lowercased()).")
        }
    }

    func objectURL(_ key: String) -> URL {
        if usesVirtualHosted, var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false),
           let host = comps.host {
            comps.host = "\(config.bucket).\(host)"
            if let base = comps.url {
                return base.appending(path: key)
            }
        }
        return config.endpoint.appending(path: config.bucket).appending(path: key)
    }

    func signed(_ method: String, key: String, payloadHash: String, contentType: String? = nil, now: Date = .now) throws(PublishFailure) -> URLRequest {
        let url = objectURL(key)
        guard let host = url.host, !host.isEmpty else {
            throw PublishFailure(.permanent, "Invalid media storage endpoint URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 300
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        var headers = ["host": hostHeader, "x-amz-date": SigV4.amzDate(now), "x-amz-content-sha256": payloadHash]
        if let contentType { headers["content-type"] = contentType }
        let auth = SigV4.authorization(method: method, path: url.path(percentEncoded: false), headers: headers, payloadHash: payloadHash,
                                       region: config.region, accessKeyID: config.accessKeyID, secret: config.secretAccessKey)
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        return req
    }

    /// Generates an unpredictable opaque object key that does not leak local filenames.
    static func opaqueKey(prefix: String, file: URL) -> String {
        let ext = file.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let id = UUID().uuidString.lowercased() + "-" + String(UUID().uuidString.prefix(8)).lowercased()
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = cleanPrefix.isEmpty ? id : "\(cleanPrefix)/\(id)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    public func put(file: URL, contentType: String) async throws(PublishFailure) -> PublicMedia {
        let hash: String
        do { hash = try ContentHash.sha256(of: file) } catch { throw PublishFailure(.permanent, "The file could not be read: \(error.localizedDescription)") }
        let key = Self.opaqueKey(prefix: config.prefix, file: file)
        let req = try signed("PUT", key: key, payloadHash: hash, contentType: contentType)
        let response: URLResponse, data: Data
        do { (data, response) = try await session.upload(for: req, fromFile: file) } catch {
            throw PublishFailure(.retryable, "Could not reach the media storage: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = body.firstMatch(of: /<Code>([^<]+)<\/Code>/).map { String($0.output.1) } ?? "HTTP \(status)"
            let kind: PublishFailure.Kind = status == 403 || status == 401 ? .permanent : PublishFailure.kind(forStatus: status)
            throw PublishFailure(kind, "The media storage refused the upload (\(code)). Check the bucket and keys in Connections › Media Storage.", httpStatus: status)
        }
        return PublicMedia(url: config.publicBaseURL.appending(path: key), key: key)
    }

    public func delete(key: String) async {
        _ = await deleteVerified(key: key)
    }

    /// Deletes an uploaded object and returns whether the storage backend confirmed deletion (2xx or 404).
    public func deleteVerified(key: String) async -> Bool {
        guard let req = try? signed("DELETE", key: key, payloadHash: SigV4.emptyPayloadHash) else { return false }
        guard let (_, response) = try? await session.data(for: req),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status) || status == 404
    }

    /// Full round-trip verification: PUT upload, public GET fetch + body + Content-Type check, and verified DELETE cleanup.
    public func verifyConnection() async -> PublicMediaVerification {
        let sentinel = "SocialForge media storage probe \(UUID().uuidString)\n"
        let temp = FileManager.default.temporaryDirectory.appending(path: "sf-probe-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try Data(sentinel.utf8).write(to: temp)
        } catch {
            return PublicMediaVerification(uploadOK: false, downloadOK: false, contentTypeOK: false, deleteOK: false,
                                           publicURL: nil, summary: "Could not write local probe file.", error: error.localizedDescription)
        }

        let uploaded: PublicMedia
        do {
            uploaded = try await put(file: temp, contentType: "text/plain")
        } catch {
            return PublicMediaVerification(uploadOK: false, downloadOK: false, contentTypeOK: false, deleteOK: false,
                                           publicURL: nil, summary: "Upload failed.", error: error.message)
        }

        var downloadOK = false
        var contentTypeOK = false
        var downloadError: String?
        do {
            var getReq = URLRequest(url: uploaded.url)
            getReq.timeoutInterval = 20
            let (data, resp) = try await session.data(for: getReq)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let ct = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let text = String(data: data, encoding: .utf8)
            downloadOK = status == 200 && text == sentinel
            contentTypeOK = ct.contains("text/plain")
            if !downloadOK {
                downloadError = status != 200
                    ? "Public URL returned HTTP \(status). Verify public bucket read access and Public Base URL."
                    : "Public URL returned unexpected content (possibly an HTML error page instead of the uploaded object)."
            } else if !contentTypeOK {
                downloadError = "Public URL returned Content-Type “\(ct)” instead of text/plain."
            }
        } catch {
            downloadError = "Could not fetch public URL: \(error.localizedDescription)"
        }

        let deleteOK = await deleteVerified(key: uploaded.key)
        let errParts = [downloadError, deleteOK ? nil : "DeleteObject failed — check bucket delete permissions so temporary files do not accumulate."].compactMap { $0 }
        let summary: String
        if downloadOK && contentTypeOK && deleteOK {
            summary = "Upload, public read, Content-Type, and delete cleanup all verified."
        } else if !downloadOK {
            summary = "Upload succeeded, but public read verification failed."
        } else if !contentTypeOK {
            summary = "Upload and read succeeded, but Content-Type header did not match."
        } else {
            summary = "Upload and public read succeeded, but delete cleanup failed."
        }
        return PublicMediaVerification(uploadOK: true, downloadOK: downloadOK, contentTypeOK: contentTypeOK,
                                       deleteOK: deleteOK, publicURL: uploaded.url.absoluteString,
                                       summary: summary, error: errParts.isEmpty ? nil : errParts.joined(separator: " "))
    }
}

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
}

public protocol PublicMediaHost: Sendable {
    func put(file: URL, contentType: String) async throws(PublishFailure) -> PublicMedia
    /// Best effort: removes a file once the platform has fetched it.
    func delete(key: String) async
}

public struct S3Config: Sendable, Equatable {
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

    public init(endpoint: URL, bucket: String, region: String, accessKeyID: String, secretAccessKey: String,
                publicBaseURL: URL, prefix: String = "socialforge") {
        self.endpoint = endpoint; self.bucket = bucket; self.region = region; self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey; self.publicBaseURL = publicBaseURL; self.prefix = prefix
    }

    /// Nil unless every field is filled and both addresses are https.
    public static func make(endpoint: String, bucket: String, region: String, accessKeyID: String, secret: String,
                            publicBase: String) -> S3Config? {
        func https(_ s: String) -> URL? {
            guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme == "https", u.host != nil else { return nil }
            return u
        }
        let b = bucket.trimmingCharacters(in: .whitespaces), r = region.trimmingCharacters(in: .whitespaces)
        guard let e = https(endpoint), let p = https(publicBase), !b.isEmpty, !r.isEmpty, !accessKeyID.isEmpty, !secret.isEmpty else { return nil }
        return S3Config(endpoint: e, bucket: b, region: r, accessKeyID: accessKeyID, secretAccessKey: secret, publicBaseURL: p)
    }
}

/// AWS Signature Version 4 for S3 requests.
public enum SigV4 {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func hmac(_ key: Data, _ s: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: key))) }

    /// RFC 3986 encoding of each path segment, keeping "/".
    static func encodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/")
        return path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    public static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// The Authorization header value. `headers` must include host, x-amz-date, and x-amz-content-sha256
    /// (all are signed); `path` is the raw, unencoded path; `query` is already canonical.
    public static func authorization(method: String, path: String, query: String = "", headers: [String: String],
                                     payloadHash: String, region: String, service: String = "s3",
                                     accessKeyID: String, secret: String) -> String {
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
        let names = lower.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(lower[$0]!)\n" }.joined()
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

/// Puts files in an S3-compatible bucket (path-style requests) and returns their public address.
public struct S3Uploader: PublicMediaHost {
    public let config: S3Config
    let session: URLSession

    public init(config: S3Config, session: URLSession = .shared) {
        self.config = config; self.session = session
    }

    func objectURL(_ key: String) -> URL {
        config.endpoint.appending(path: config.bucket).appending(path: key)
    }

    func signed(_ method: String, key: String, payloadHash: String, contentType: String? = nil, now: Date = .now) -> URLRequest {
        let url = objectURL(key)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 300
        let hostHeader = url.port.map { "\(url.host!):\($0)" } ?? url.host!
        var headers = ["host": hostHeader, "x-amz-date": SigV4.amzDate(now), "x-amz-content-sha256": payloadHash]
        if let contentType { headers["content-type"] = contentType }
        let auth = SigV4.authorization(method: method, path: url.path(percentEncoded: false), headers: headers, payloadHash: payloadHash,
                                       region: config.region, accessKeyID: config.accessKeyID, secret: config.secretAccessKey)
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        return req
    }

    public func put(file: URL, contentType: String) async throws(PublishFailure) -> PublicMedia {
        let hash: String
        do { hash = try ContentHash.sha256(of: file) } catch { throw PublishFailure(.permanent, "The file could not be read: \(error.localizedDescription)") }
        // A random folder keeps the address unguessable.
        let key = "\(config.prefix)/\(UUID().uuidString.lowercased())/\(file.lastPathComponent)"
        let req = signed("PUT", key: key, payloadHash: hash, contentType: contentType)
        let response: URLResponse, data: Data
        do { (data, response) = try await session.upload(for: req, fromFile: file) } catch {
            throw PublishFailure(.retryable, "Could not reach the media storage: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = body.firstMatch(of: /<Code>([^<]+)<\/Code>/).map { String($0.output.1) } ?? "HTTP \(status)"
            let kind: PublishFailure.Kind = status == 403 || status == 401 ? .permanent : PublishFailure.kind(forStatus: status)
            throw PublishFailure(kind, "The media storage refused the upload (\(code)). Check the bucket and keys in Settings › Publishing.", httpStatus: status)
        }
        return PublicMedia(url: config.publicBaseURL.appending(path: key), key: key)
    }

    public func delete(key: String) async {
        let req = signed("DELETE", key: key, payloadHash: SigV4.emptyPayloadHash)
        _ = try? await session.data(for: req)
    }
}

import Foundation

/// Capabilities advertised by a hosted stateless SocialForge OAuth Relay (e.g. deployed on Vercel).
public struct OAuthRelayProvider: Codable, Sendable, Equatable, Identifiable {
    public var id: String { platform }
    public let platform: String
    public let displayName: String
    public let enabled: Bool
    public let redirectURI: String
    public let pkceRequired: Bool
    public let supportsRefresh: Bool
    public let scopes: [String]
}

public struct OAuthRelayCapabilities: Codable, Sendable, Equatable {
    public let service: String
    public let version: String
    public let stateless: Bool
    public let origin: String
    public let providers: [OAuthRelayProvider]

    public func provider(_ platform: String) -> OAuthRelayProvider? {
        providers.first { $0.platform == platform }
    }

    public func isEnabled(_ platform: String) -> Bool {
        provider(platform)?.enabled == true
    }
}

public struct OAuthRelayToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let scope: String?
    public let tokenType: String?
    public let userID: String?
    public let sandbox: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
        case userID = "user_id"
        case sandbox
    }

    public var scopeList: [String] {
        guard let scope, !scope.isEmpty else { return [] }
        return scope.split { $0 == " " || $0 == "," }.map(String.init).filter { !$0.isEmpty }
    }
}

public struct OAuthRelayCallbackResult: Sendable, Equatable {
    public let platform: String
    public let code: String
    public let viaRelay: Bool
}

public enum OAuthRelayError: Error, Sendable, Equatable, CustomStringConvertible {
    case insecureURL(String)
    case invalidCallback(String)
    case providerDenied(String)
    case stateMismatch
    case serverError(Int, String)
    case network(String)

    public var description: String {
        switch self {
        case .insecureURL(let m): m
        case .invalidCallback(let m): m
        case .providerDenied(let m): m
        case .stateMismatch: "Authorization state did not match the session started by SocialForge. Try connecting again."
        case .serverError(let code, let m): "OAuth relay returned HTTP \(code): \(m)"
        case .network(let m): m
        }
    }
}

/// Client for SocialForge's stateless OAuth Relay (deployed on Vercel or any HTTPS host).
/// Never sends client secrets from the Mac; exchanges single-use authorization codes over TLS
/// and returns tokens straight into the local macOS Keychain.
public struct OAuthRelayClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || Self.isLocalhost(baseURL) else {
            throw OAuthRelayError.insecureURL("OAuth Relay URL must use https:// (plain http:// is allowed only for localhost testing).")
        }
        // Strip trailing slash for consistent path joining.
        let trimmed = baseURL.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let clean = URL(string: trimmed) else {
            throw OAuthRelayError.insecureURL("Invalid OAuth Relay URL.")
        }
        self.baseURL = clean
        self.session = session
    }

    public static func isLocalhost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Queries GET /api/providers to discover which platforms are enabled on the relay.
    public func fetchCapabilities() async throws -> OAuthRelayCapabilities {
        let url = baseURL.appendingPathComponent("api/providers")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthRelayError.network("Invalid HTTP response from OAuth relay.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthRelayError.serverError(http.statusCode, Self.extractError(data))
        }
        return try JSONDecoder().decode(OAuthRelayCapabilities.self, from: data)
    }

    /// Builds the browser authorization entry URL on the relay (GET /api/oauth/start).
    public func startURL(
        platform: String,
        state: String,
        codeChallenge: String? = nil,
        mode: String? = nil
    ) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/oauth/start"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "state", value: state),
        ]
        if let codeChallenge, !codeChallenge.isEmpty {
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
        }
        if let mode, !mode.isEmpty {
            items.append(URLQueryItem(name: "mode", value: mode))
        }
        comps.queryItems = items
        return comps.url!
    }

    /// Exchanges a single-use authorization code for OAuth tokens over TLS (POST /api/oauth/exchange).
    public func exchange(
        platform: String,
        code: String,
        redirectURI: String? = nil,
        codeVerifier: String? = nil,
        sandbox: Bool = false
    ) async throws -> OAuthRelayToken {
        var payload: [String: Any] = [
            "platform": platform,
            "code": code,
            "sandbox": sandbox,
        ]
        if let redirectURI, !redirectURI.isEmpty { payload["redirect_uri"] = redirectURI }
        if let codeVerifier, !codeVerifier.isEmpty { payload["code_verifier"] = codeVerifier }
        return try await postToken(path: "api/oauth/exchange", payload: payload)
    }

    /// Refreshes an expiring OAuth token statelessly via the relay (POST /api/oauth/refresh).
    public func refresh(
        platform: String,
        refreshToken: String? = nil,
        accessToken: String? = nil,
        sandbox: Bool = false
    ) async throws -> OAuthRelayToken {
        var payload: [String: Any] = [
            "platform": platform,
            "sandbox": sandbox,
        ]
        if let refreshToken, !refreshToken.isEmpty { payload["refresh_token"] = refreshToken }
        if let accessToken, !accessToken.isEmpty { payload["access_token"] = accessToken }
        return try await postToken(path: "api/oauth/refresh", payload: payload)
    }

    /// Parses a `socialforge://oauth/callback?...` deep-link URL and validates `state`.
    public static func parseCallbackURL(_ url: URL, expectedState: String) throws -> OAuthRelayCallbackResult {
        guard url.scheme?.lowercased() == "socialforge",
              url.host?.lowercased() == "oauth" else {
            throw OAuthRelayError.invalidCallback("Unrecognized callback URL scheme.")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let map = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        if let err = map["error"], !err.isEmpty {
            let desc = map["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? err
            throw OAuthRelayError.providerDenied(DiagnosticRedactor.sanitize(desc))
        }
        guard let state = map["state"], !state.isEmpty, state == expectedState else {
            throw OAuthRelayError.stateMismatch
        }
        guard let code = map["code"], !code.isEmpty else {
            throw OAuthRelayError.invalidCallback("Callback did not include an authorization code.")
        }
        let platform = (map["platform"] ?? "").lowercased()
        let viaRelay = map["relay"] == "1" || map["relay"]?.lowercased() == "true"
        return OAuthRelayCallbackResult(platform: platform, code: code, viaRelay: viaRelay)
    }

    private func postToken(path: String, payload: [String: Any]) async throws -> OAuthRelayToken {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthRelayError.network("Invalid HTTP response from OAuth relay.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthRelayError.serverError(http.statusCode, Self.extractError(data))
        }
        return try JSONDecoder().decode(OAuthRelayToken.self, from: data)
    }

    private func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw OAuthRelayError.network(DiagnosticRedactor.sanitize(error.localizedDescription))
        }
    }

    private static func extractError(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String, !msg.isEmpty {
            return DiagnosticRedactor.sanitize(msg)
        }
        let raw = String(data: data, encoding: .utf8) ?? "Request failed"
        return DiagnosticRedactor.sanitize(String(raw.prefix(240)))
    }
}

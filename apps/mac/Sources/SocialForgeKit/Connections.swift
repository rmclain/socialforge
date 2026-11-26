import CryptoKit
import Foundation

// Unified connection lifecycle, PKCE, token refresh deduplication, and sanitized diagnostics.

public enum ConnectionCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case social
    case aiProvider
    case mediaStorage
    case automationAndAgents
    case publishingInfra

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .social: "Social Accounts"
        case .aiProvider: "AI Providers"
        case .mediaStorage: "Media Storage"
        case .automationAndAgents: "Automation & Agents"
        case .publishingInfra: "Publishing Infrastructure"
        }
    }
}

public enum ConnectionStatus: String, Sendable, Codable, CaseIterable, Equatable {
    case notConfigured
    case configuredUntested
    case connecting
    case connected
    case connectedWithLimitations
    case expiringSoon
    case reauthRequired
    case missingPermissions
    case unreachable
    case rateLimited
    case configurationError
    case revoked
    case disabled

    public var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .configuredUntested: "Configured · not tested"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .connectedWithLimitations: "Connected with limitations"
        case .expiringSoon: "Expiring soon"
        case .reauthRequired: "Reauthentication required"
        case .missingPermissions: "Missing permissions"
        case .unreachable: "Unreachable"
        case .rateLimited: "Rate limited"
        case .configurationError: "Configuration error"
        case .revoked: "Revoked"
        case .disabled: "Disabled"
        }
    }

    public var isHealthy: Bool {
        self == .connected || self == .connectedWithLimitations || self == .expiringSoon
    }

    public var needsAttention: Bool {
        switch self {
        case .reauthRequired, .missingPermissions, .unreachable, .rateLimited, .configurationError, .revoked, .expiringSoon:
            true
        default:
            false
        }
    }

    /// Maps legacy `SocialAccount.status` strings plus token expiry / missing permissions to a rich status.
    public static func fromAccount(status: String, tokenExpiresAt: Date?, missingPermissions: [String],
                                   hasCredential: Bool, isMock: Bool = false, hasLimitations: Bool = false,
                                   now: Date = .now) -> ConnectionStatus {
        if status == "disabled" { return .disabled }
        if status == "revoked" { return .revoked }
        if status == "expired" || status == "reauthRequired" { return .reauthRequired }
        if status == "rateLimited" { return .rateLimited }
        if status == "unreachable" { return .unreachable }
        if status == "error" || status == "configurationError" { return .configurationError }
        if !isMock && !hasCredential { return .reauthRequired }
        if let exp = tokenExpiresAt {
            if exp <= now { return .reauthRequired }
            if exp <= now.addingTimeInterval(7 * 86_400) { return .expiringSoon }
        }
        if !missingPermissions.isEmpty { return .missingPermissions }
        if status == "configuredUntested" { return .configuredUntested }
        if status == "connecting" { return .connecting }
        return hasLimitations ? .connectedWithLimitations : .connected
    }
}

/// Dynamic account-level capability flags supplementing the static PlatformSpec rules.
public struct DynamicAccountCapabilities: Sendable, Codable, Equatable {
    public var accountType: String?
    public var grantedPermissions: [String]
    public var missingPermissions: [String]
    public var subscriptionTier: String?
    public var approvalStatus: String?
    public var isSandbox: Bool
    public var publishingRoute: String
    public var publicMediaHostingAvailable: Bool
    public var limitations: [String]

    public init(accountType: String? = nil, grantedPermissions: [String] = [], missingPermissions: [String] = [],
                subscriptionTier: String? = nil, approvalStatus: String? = nil, isSandbox: Bool = false,
                publishingRoute: String = "mac", publicMediaHostingAvailable: Bool = false, limitations: [String] = []) {
        self.accountType = accountType
        self.grantedPermissions = grantedPermissions
        self.missingPermissions = missingPermissions
        self.subscriptionTier = subscriptionTier
        self.approvalStatus = approvalStatus
        self.isSandbox = isSandbox
        self.publishingRoute = publishingRoute
        self.publicMediaHostingAvailable = publicMediaHostingAvailable
        self.limitations = limitations
    }
}

public struct ConnectionDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let category: ConnectionCategory
    public let providerID: String
    public let providerName: String
    public let accountIdentity: String
    public let status: ConnectionStatus
    public let supportLevel: PlatformSupportLevel?
    public let supportedCapabilities: [String]
    public let grantedPermissions: [String]
    public let missingPermissions: [String]
    public let limitations: [String]
    public let credentialExpiresAt: Date?
    public let lastVerifiedAt: Date?
    public let lastOperationAt: Date?
    public let lastError: String?
    public let setupURL: URL?
    public let setupSummary: String
    public let isMock: Bool

    public init(id: String, category: ConnectionCategory, providerID: String, providerName: String,
                accountIdentity: String, status: ConnectionStatus, supportLevel: PlatformSupportLevel? = nil,
                supportedCapabilities: [String] = [], grantedPermissions: [String] = [], missingPermissions: [String] = [],
                limitations: [String] = [], credentialExpiresAt: Date? = nil, lastVerifiedAt: Date? = nil,
                lastOperationAt: Date? = nil, lastError: String? = nil, setupURL: URL? = nil,
                setupSummary: String = "", isMock: Bool = false) {
        self.id = id; self.category = category; self.providerID = providerID; self.providerName = providerName
        self.accountIdentity = accountIdentity; self.status = status; self.supportLevel = supportLevel
        self.supportedCapabilities = supportedCapabilities; self.grantedPermissions = grantedPermissions
        self.missingPermissions = missingPermissions; self.limitations = limitations
        self.credentialExpiresAt = credentialExpiresAt; self.lastVerifiedAt = lastVerifiedAt
        self.lastOperationAt = lastOperationAt; self.lastError = lastError
        self.setupURL = setupURL; self.setupSummary = setupSummary; self.isMock = isMock
    }
}

// MARK: - PKCE (RFC 7636 S256)

public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method: String = "S256"

    public static func generate() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        return from(verifier: verifier)
    }

    public static func from(verifier: String) -> PKCEPair {
        let hash = Data(SHA256.hash(data: Data(verifier.utf8)))
        return PKCEPair(verifier: verifier, challenge: base64URL(hash))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Unified Token Lifecycle Manager (single-flight concurrent refresh & safe rotation)

public struct RefreshedToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String]? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

/// Coordinates proactive token refresh across the foreground app and background publisher so
/// simultaneous refresh attempts for the same credential key share one network call and never
/// clobber a newly rotated refresh token.
public actor TokenLifecycleManager {
    private var inFlight: [String: Task<RefreshedToken, Error>] = [:]
    private var lastRotatedAt: [String: Date] = [:]

    public init() {}

    /// Returns whether a token expiring at `expiresAt` should be proactively refreshed.
    public static func shouldRefresh(expiresAt: Date?, leeway: TimeInterval, now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    /// Deduplicates concurrent refresh calls for `credentialKey`.
    /// Callers provide the network refresh closure and the atomic persistence closure.
    public func refresh(
        credentialKey: String,
        operation: @Sendable @escaping () async throws -> RefreshedToken,
        persist: @Sendable @escaping (RefreshedToken) async throws -> Void
    ) async throws -> RefreshedToken {
        if let existing = inFlight[credentialKey] {
            return try await existing.value
        }
        let task = Task<RefreshedToken, Error> {
            let refreshed = try await operation()
            try await persist(refreshed)
            return refreshed
        }
        inFlight[credentialKey] = task
        defer {
            inFlight[credentialKey] = nil
            lastRotatedAt[credentialKey] = .now
        }
        return try await task.value
    }

    public func inFlightCount() -> Int { inFlight.count }
}

// MARK: - Sanitized Diagnostics

public enum DiagnosticRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // Bearer / OAuth / Basic authorization headers
            (#"(?i)(authorization\s*[:=]\s*(?:bearer|basic|oauth)\s+)[^\s\"',;]+"#, "$1[REDACTED]"),
            // Query or JSON token/secret/code fields
            (#"(?i)((?:access_token|refresh_token|client_secret|fb_exchange_token|api_key|apikey|secret_access_key|secret|password|token|code|x-amz-signature|x-amz-security-token|signature)\s*[=:]\s*\"?)[^&\s\"',;}]+"#, "$1[REDACTED]"),
            // AWS SigV4 Authorization header values
            (#"AWS4-HMAC-SHA256\s+Credential=[^\r\n\"]+"#, "AWS4-HMAC-SHA256 [REDACTED]"),
            // Common API key prefixes (OpenAI, Anthropic, Google, AWS)
            (#"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{12,}\b"#, "[REDACTED_KEY]"),
            (#"\bAIza[0-9A-Za-z_\-]{20,}\b"#, "[REDACTED_KEY]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_AWS_KEY]"),
        ]
        return defs.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    /// Removes secrets, bearer tokens, OAuth codes, signed URL query params, and explicit secret strings.
    public static func sanitize(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for secret in secrets where secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        for (regex, replacement) in patterns {
            let range = NSRange(location: 0, length: (out as NSString).length)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }
}

public struct ConnectionDiagnosticReport: Sendable, Equatable {
    public let generatedAt: Date
    public let appVersion: String
    public let providerName: String
    public let accountIdentity: String
    public let status: ConnectionStatus
    public let plainLanguageSummary: String
    public let recommendedAction: String
    public let technicalDetails: [String: String]

    public init(generatedAt: Date = .now, appVersion: String, providerName: String, accountIdentity: String,
                status: ConnectionStatus, plainLanguageSummary: String, recommendedAction: String,
                technicalDetails: [String: String], knownSecrets: [String] = []) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.providerName = providerName
        self.accountIdentity = accountIdentity
        self.status = status
        self.plainLanguageSummary = DiagnosticRedactor.sanitize(plainLanguageSummary, secrets: knownSecrets)
        self.recommendedAction = DiagnosticRedactor.sanitize(recommendedAction, secrets: knownSecrets)
        self.technicalDetails = technicalDetails.mapValues { DiagnosticRedactor.sanitize($0, secrets: knownSecrets) }
    }

    public func copyableText() -> String {
        var lines = [
            "SocialForge Connection Diagnostics",
            "Generated: \(ISO8601.format(generatedAt))",
            "App Version: \(appVersion)",
            "Provider: \(providerName)",
            "Account: \(accountIdentity)",
            "Status: \(status.label)",
            "Summary: \(plainLanguageSummary)",
            "Recommended Action: \(recommendedAction)",
            "",
            "Technical Details (Sanitized):",
        ]
        for key in technicalDetails.keys.sorted() {
            lines.append("  \(key): \(technicalDetails[key] ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}

import AppKit
import Foundation
import Network
import ServiceManagement
import SwiftData
import SocialForgeKit

/// Where approved posts are published from.
enum PublishMode: String, CaseIterable {
    /// This Mac: the app while open, the launch agent while closed. The default.
    case mac
    /// The optional publishing service in services/api (posts while the Mac sleeps).
    case service

    var title: String {
        switch self {
        case .mac: "This Mac"
        case .service: "Publishing service (optional)"
        }
    }
}

extension AppModel {
    var publishMode: PublishMode {
        get { PublishMode(rawValue: publishModeRaw) ?? .mac }
        set { publishModeRaw = newValue.rawValue; modeRevision += 1 }
    }

    /// Ready to activate: on-Mac always; the service only when an address is set.
    var canActivate: Bool { publishMode == .mac || client != nil }

    // MARK: Accounts on this Mac

    /// A clearly labeled stand-in for Pinterest, for trying the whole flow without credentials.
    @discardableResult
    func addMockAccount() -> SocialAccount? {
        guard let workspaceID else { return nil }
        let id = "mac-mock-\(workspaceID.uuidString.prefix(8).lowercased())"
        if let existing = accounts.first(where: { $0.serverID == id }) { return existing }
        let a = SocialAccount(serverID: id, workspaceID: workspaceID, platform: "pinterest", name: "Mock Pinterest", status: "connected")
        a.handle = "@mock"
        a.scopes = PinterestTarget.scopes
        a.isMock = true
        a.source = "mac"
        a.lastVerifiedAt = .now
        context.insert(a)
        saveContext("addMockAccount")
        boards[id] = MockPinterestTarget.boards
        log("Added the mock Pinterest account (testing only)", symbol: "person.badge.plus", category: "connection")
        return a
    }

    /// Dispatches Connect / Reconnect to the account's actual platform instead of hardcoding Pinterest.
    func connectPlatformOnMac(_ platform: String, authMode: String = "") async {
        switch platform {
        case "pinterest": await connectPinterestOnMac()
        case "facebook": await connectMeta(.facebook)
        case "instagram":
            if authMode == "instagram_login" { await connectMeta(.instagramLogin) }
            else { await connectMeta(.facebook) }
        case "threads": await connectMeta(.threads)
        case "linkedin": await connectLinkedInOnMac(includeOrganizations: authMode == "organization")
        case "x": await connectXOnMac()
        case "tiktok": await connectTikTokOnMac()
        case "youtube": await connectYouTubeOnMac()
        default:
            lastError = "No OAuth connection flow available for \(platform)."
        }
    }

    /// Verifies and refreshes destinations/tokens for accounts connected on this Mac.
    func refreshLocalAccounts() async {
        for a in accounts where a.source == "mac" && a.status == "connected" {
            // Proactively refresh expiring tokens across all platforms.
            let token = await runner.ensureFreshToken(for: a, ctx: context)
            guard let target = PublishRunner.target(for: a, storage: libraryStorage) else { continue }
            do {
                boards[a.serverID] = try await target.boards(accessToken: a.isMock ? nil : token)
                a.lastVerifiedAt = .now
                a.lastError = nil
            } catch {
                if error.kind == .auth { a.status = "expired" }
                a.lastError = DiagnosticRedactor.sanitize(error.message)
                lastError = "\(a.name): \(a.lastError ?? error.message)"
            }
        }
        saveContext("refreshLocalAccounts")
        modeRevision += 1
    }

    /// Actively tests one account's live connection (never assumes a saved token works).
    func testAccountConnection(_ account: SocialAccount) async -> ConnectionDiagnosticReport {
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0"
        let providerName = PlatformRegistry.spec(account.platform)?.name ?? account.platform.capitalized
        if account.isMock {
            boards[account.serverID] = MockPinterestTarget.boards
            account.lastVerifiedAt = .now
            account.lastError = nil
            saveContext("testMockAccount")
            return ConnectionDiagnosticReport(
                appVersion: appVer, providerName: providerName, accountIdentity: "\(account.name) (Mock)",
                status: .connected, plainLanguageSummary: "Mock account is active for local testing only.",
                recommendedAction: "Connect a real developer app in Connections when ready to publish live.",
                technicalDetails: ["source": "mock", "platform": account.platform, "scopes": account.scopes.joined(separator: ", ")]
            )
        }
        if account.source == "service" {
            await checkBackend()
            let ok = if case .up = backendStatus { true } else { false }
            return ConnectionDiagnosticReport(
                appVersion: appVer, providerName: providerName, accountIdentity: account.name,
                status: ok ? account.connectionStatus : .unreachable,
                plainLanguageSummary: ok ? "Account is managed by the connected publishing service." : "Publishing service is unreachable.",
                recommendedAction: ok ? "No action required." : "Check the publishing service URL and token in Connections.",
                technicalDetails: ["source": "service", "platform": account.platform, "status": account.status]
            )
        }
        guard let target = PublishRunner.target(for: account, storage: libraryStorage) else {
            return ConnectionDiagnosticReport(
                appVersion: appVer, providerName: providerName, accountIdentity: account.name,
                status: .configurationError, plainLanguageSummary: "No local adapter is configured for \(providerName).",
                recommendedAction: "Verify provider settings in Connections.",
                technicalDetails: ["platform": account.platform]
            )
        }
        let token = await runner.ensureFreshToken(for: account, ctx: context)
        let secrets = [token, Keychain.read(account.refreshTokenKey)].compactMap { $0 }
        do {
            let discovered = try await target.boards(accessToken: token)
            boards[account.serverID] = discovered
            account.status = "connected"
            account.lastVerifiedAt = .now
            account.lastError = nil
            saveContext("testAccountOK")
            return ConnectionDiagnosticReport(
                appVersion: appVer, providerName: providerName, accountIdentity: account.name,
                status: account.connectionStatus,
                plainLanguageSummary: "Verified live API access. Discovered \(discovered.count) destination(s).",
                recommendedAction: account.connectionStatus == .connectedWithLimitations
                    ? "Check platform limitations (e.g., public media storage or sandbox mode) before scheduling."
                    : "Connection is healthy.",
                technicalDetails: [
                    "platform": account.platform,
                    "authMode": account.authMode.isEmpty ? "default" : account.authMode,
                    "destinations": String(discovered.count),
                    "scopes": account.scopes.joined(separator: ", "),
                    "expiresAt": account.tokenExpiresAt.map(ISO8601.format) ?? "none",
                ],
                knownSecrets: secrets
            )
        } catch {
            if error.kind == .auth { account.status = "expired" }
            let clean = DiagnosticRedactor.sanitize(error.message, secrets: secrets)
            account.lastError = clean
            saveContext("testAccountFail")
            let status: ConnectionStatus = switch error.kind {
            case .auth: .reauthRequired
            case .permission: .missingPermissions
            case .rateLimited: .rateLimited
            case .retryable, .uncertain: .unreachable
            case .permanent: .configurationError
            }
            return ConnectionDiagnosticReport(
                appVersion: appVer, providerName: providerName, accountIdentity: account.name,
                status: status,
                plainLanguageSummary: clean,
                recommendedAction: error.kind == .auth
                    ? "Reconnect this account to obtain a fresh token."
                    : error.kind == .permission
                        ? "Check granted scopes and provider app approval status in your developer console."
                        : "Verify network connectivity and provider status, then test again.",
                technicalDetails: [
                    "platform": account.platform,
                    "httpStatus": error.httpStatus.map(String.init) ?? "none",
                    "requestID": error.requestID ?? "none",
                    "errorKind": error.kind.rawValue,
                ],
                knownSecrets: secrets
            )
        }
    }

    // MARK: - Helper to upsert workspace-scoped accounts cleanly (even if user switches workspace mid-OAuth)

    @discardableResult
    func upsertMacAccount(workspaceID: UUID, platform: String, platformID: String, name: String, handle: String,
                          token: String, refreshToken: String? = nil, expiresIn: Int?, scopes: [String],
                          accountType: String = "", authMode: String = "") throws -> SocialAccount {
        let serverID = "mac-\(platform)-\(platformID)"
        let credentialProfile = "\(platform)-\(platformID)"
        let existing = (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate {
            $0.workspaceID == workspaceID && $0.serverID == serverID
        })))?.first
        let a = existing ?? {
            let n = SocialAccount(serverID: serverID, workspaceID: workspaceID, platform: platform, name: name, status: "connected")
            context.insert(n)
            return n
        }()
        a.name = name
        a.handle = handle
        a.status = "connected"
        a.source = "mac"
        a.credentialProfileID = credentialProfile
        a.scopes = scopes
        a.accountType = accountType
        a.authMode = authMode
        a.tokenExpiresAt = expiresIn.map { Date.now.addingTimeInterval(Double($0)) }
        a.lastVerifiedAt = .now
        a.lastError = nil
        try Keychain.writeStrict(token, for: a.tokenKey)
        if let refreshToken, !refreshToken.isEmpty {
            try Keychain.writeStrict(refreshToken, for: a.refreshTokenKey)
        }
        return a
    }

    /// Associates an already-authenticated Mac account with another brand workspace without duplicating tokens.
    @discardableResult
    func shareAccount(_ sourceAccount: SocialAccount, intoWorkspace targetWorkspaceID: UUID) -> SocialAccount? {
        guard sourceAccount.source == "mac" else { return nil }
        let sid = sourceAccount.serverID
        if let existing = (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate {
            $0.workspaceID == targetWorkspaceID && $0.serverID == sid
        })))?.first {
            return existing
        }
        let sharedProfile = sourceAccount.credentialProfileID.isEmpty ? "\(sourceAccount.platform)-\(sourceAccount.platformID)" : sourceAccount.credentialProfileID
        if sourceAccount.credentialProfileID.isEmpty {
            Keychain.migrate(from: sourceAccount.tokenKey, to: "cred.\(sharedProfile)")
            Keychain.migrate(from: sourceAccount.refreshTokenKey, to: "cred.\(sharedProfile).refresh")
            sourceAccount.credentialProfileID = sharedProfile
        }
        let copy = SocialAccount(serverID: sourceAccount.serverID, workspaceID: targetWorkspaceID,
                                 platform: sourceAccount.platform, name: sourceAccount.name, status: sourceAccount.status)
        copy.handle = sourceAccount.handle
        copy.scopes = sourceAccount.scopes
        copy.tokenExpiresAt = sourceAccount.tokenExpiresAt
        copy.lastVerifiedAt = sourceAccount.lastVerifiedAt
        copy.isMock = sourceAccount.isMock
        copy.source = sourceAccount.source
        copy.credentialProfileID = sharedProfile
        copy.accountType = sourceAccount.accountType
        copy.authMode = sourceAccount.authMode
        context.insert(copy)
        saveContext("shareAccount")
        log("Associated \(copy.name) with workspace", symbol: "person.2", category: "connection", workspace: targetWorkspaceID)
        return copy
    }

    // MARK: - Pinterest OAuth

    func connectPinterestOnMac() async {
        guard let targetWorkspace = workspaceID else { return }
        guard let clientID = Keychain.read("pinterest.clientID"), !clientID.isEmpty,
              let secret = Keychain.read("pinterest.clientSecret"), !secret.isEmpty else {
            lastError = "Add your Pinterest app's ID and secret in Connections first."
            page = .accounts
            return
        }
        let callbackPath = "/pinterest/callback"
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)\(callbackPath)"
        let state = UUID().uuidString
        busyMessage = "Waiting for Pinterest in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback(service: "Pinterest", expectedPath: callbackPath)
            try await loopback.start()
            NSWorkspace.shared.open(PinterestTarget.authorizeURL(clientID: clientID, redirectURI: redirect, state: state))
            let code = try await loopback.waitForCode(state: state)
            let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:)) ?? URL(string: "https://api.pinterest.com")!
            let target = PinterestTarget(apiBase: base)
            let tokens = try await target.exchange(code: code, redirectURI: redirect, clientID: clientID, clientSecret: secret)
            let user = try await target.userAccount(accessToken: tokens.access)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "pinterest", platformID: user.id,
                name: user.name, handle: "@\(user.username)", token: tokens.access,
                refreshToken: tokens.refresh, expiresIn: tokens.expiresIn,
                scopes: tokens.scopes.isEmpty ? PinterestTarget.scopes : tokens.scopes,
                accountType: "business", authMode: target.isSandbox ? "sandbox" : "production"
            )
            saveContext("connectPinterest")
            log("Connected Pinterest as \(user.name)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = DiagnosticRedactor.sanitize(e.message)
        } catch {
            lastError = "Pinterest connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    // MARK: - LinkedIn OAuth

    func connectLinkedInOnMac(includeOrganizations: Bool = false) async {
        guard let targetWorkspace = workspaceID else { return }
        guard let clientID = Keychain.read("linkedin.clientID"), !clientID.isEmpty,
              let secret = Keychain.read("linkedin.clientSecret"), !secret.isEmpty else {
            lastError = "Add your LinkedIn app's Client ID and secret in Connections first."
            page = .accounts
            return
        }
        let callbackPath = "/linkedin/callback"
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)\(callbackPath)"
        let state = UUID().uuidString
        busyMessage = "Waiting for LinkedIn in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback(service: "LinkedIn", expectedPath: callbackPath)
            try await loopback.start()
            NSWorkspace.shared.open(LinkedInAuth.authorizeURL(clientID: clientID, redirectURI: redirect, state: state, includeOrganizations: includeOrganizations))
            let code = try await loopback.waitForCode(state: state)
            let auth = LinkedInAuth()
            let tokens = try await auth.exchange(code: code, redirectURI: redirect, clientID: clientID, clientSecret: secret)
            let identity = try await auth.discoverIdentity(accessToken: tokens.accessToken)
            let granted = tokens.scopes.isEmpty ? (includeOrganizations ? LinkedInAuth.organizationScopes : LinkedInAuth.memberScopes) : tokens.scopes
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "linkedin", platformID: identity.memberURN,
                name: identity.name, handle: identity.name, token: tokens.accessToken,
                refreshToken: tokens.refreshToken, expiresIn: tokens.expiresIn,
                scopes: granted, accountType: identity.organizations.isEmpty ? "personal" : "organization", authMode: "oauth2"
            )
            saveContext("connectLinkedIn")
            log("Connected LinkedIn as \(identity.name)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = DiagnosticRedactor.sanitize(e.message)
        } catch {
            lastError = "LinkedIn connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    // MARK: - X OAuth 2.0 PKCE

    func connectXOnMac() async {
        guard let targetWorkspace = workspaceID else { return }
        guard let clientID = Keychain.read("x.clientID"), !clientID.isEmpty else {
            lastError = "Add your X app's Client ID in Connections first."
            page = .accounts
            return
        }
        let secret = Keychain.read("x.clientSecret")
        let callbackPath = "/x/callback"
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)\(callbackPath)"
        let state = UUID().uuidString
        let pkce = PKCEPair.generate()
        busyMessage = "Waiting for X in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback(service: "X", expectedPath: callbackPath)
            try await loopback.start()
            NSWorkspace.shared.open(XAuth.authorizeURL(clientID: clientID, redirectURI: redirect, state: state, pkce: pkce))
            let code = try await loopback.waitForCode(state: state)
            let auth = XAuth()
            let tokens = try await auth.exchange(code: code, redirectURI: redirect, clientID: clientID, clientSecret: secret, codeVerifier: pkce.verifier)
            let user = try await auth.currentUser(accessToken: tokens.accessToken)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "x", platformID: user.id,
                name: user.name, handle: "@\(user.username)", token: tokens.accessToken,
                refreshToken: tokens.refreshToken, expiresIn: tokens.expiresIn,
                scopes: tokens.scopes.isEmpty ? XAuth.scopes : tokens.scopes,
                accountType: "user", authMode: "oauth2_pkce"
            )
            saveContext("connectX")
            log("Connected X as @\(user.username)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = DiagnosticRedactor.sanitize(e.message)
        } catch {
            lastError = "X connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    // MARK: - TikTok OAuth 2.0 PKCE

    func connectTikTokOnMac() async {
        guard let targetWorkspace = workspaceID else { return }
        guard let clientKey = Keychain.read("tiktok.clientKey"), !clientKey.isEmpty,
              let secret = Keychain.read("tiktok.clientSecret"), !secret.isEmpty else {
            lastError = "Add your TikTok app's Client Key and secret in Connections first."
            page = .accounts
            return
        }
        let callbackPath = "/tiktok/callback"
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)\(callbackPath)"
        let state = UUID().uuidString
        let pkce = PKCEPair.generate()
        busyMessage = "Waiting for TikTok in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback(service: "TikTok", expectedPath: callbackPath)
            try await loopback.start()
            NSWorkspace.shared.open(TikTokAuth.authorizeURL(clientKey: clientKey, redirectURI: redirect, state: state, pkce: pkce))
            let code = try await loopback.waitForCode(state: state)
            let auth = TikTokAuth()
            let tokens = try await auth.exchange(code: code, redirectURI: redirect, clientKey: clientKey, clientSecret: secret, codeVerifier: pkce.verifier)
            let creator = try? await auth.queryCreatorInfo(accessToken: tokens.accessToken)
            let name = creator?.nickname ?? "TikTok Creator"
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "tiktok", platformID: tokens.openID,
                name: name, handle: "@\(name)", token: tokens.accessToken,
                refreshToken: tokens.refreshToken, expiresIn: tokens.expiresIn,
                scopes: tokens.scopes.isEmpty ? TikTokAuth.scopes : tokens.scopes,
                accountType: "creator", authMode: "oauth2_pkce"
            )
            saveContext("connectTikTok")
            log("Connected TikTok as \(name)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = DiagnosticRedactor.sanitize(e.message)
        } catch {
            lastError = "TikTok connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    // MARK: - YouTube Google OAuth 2.0 PKCE

    func connectYouTubeOnMac() async {
        guard let targetWorkspace = workspaceID else { return }
        guard let clientID = Keychain.read("youtube.clientID"), !clientID.isEmpty else {
            lastError = "Add your Google OAuth Client ID in Connections first."
            page = .accounts
            return
        }
        let secret = Keychain.read("youtube.clientSecret")
        let callbackPath = "/youtube/callback"
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)\(callbackPath)"
        let state = UUID().uuidString
        let pkce = PKCEPair.generate()
        busyMessage = "Waiting for Google/YouTube in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback(service: "YouTube", expectedPath: callbackPath)
            try await loopback.start()
            NSWorkspace.shared.open(YouTubeAuth.authorizeURL(clientID: clientID, redirectURI: redirect, state: state, pkce: pkce))
            let code = try await loopback.waitForCode(state: state)
            let auth = YouTubeAuth()
            let tokens = try await auth.exchange(code: code, redirectURI: redirect, clientID: clientID, clientSecret: secret, codeVerifier: pkce.verifier)
            let channels = try await auth.channels(accessToken: tokens.accessToken)
            let primary = channels.first
            let channelID = primary?.id ?? "mine"
            let channelName = primary?.name ?? "YouTube Channel"
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "youtube", platformID: channelID,
                name: channelName, handle: channelName, token: tokens.accessToken,
                refreshToken: tokens.refreshToken, expiresIn: tokens.expiresIn,
                scopes: tokens.scopes.isEmpty ? YouTubeAuth.scopes : tokens.scopes,
                accountType: "channel", authMode: "oauth2_pkce"
            )
            saveContext("connectYouTube")
            log("Connected YouTube channel \(channelName)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = DiagnosticRedactor.sanitize(e.message)
        } catch {
            lastError = "YouTube connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    // MARK: Background helper

    static let agentPlist = "com.socialforge.app.publisher.plist"

    var helperService: SMAppService { SMAppService.agent(plistName: Self.agentPlist) }

    var helperStatusText: String {
        switch helperService.status {
        case .enabled: "On: posts go out while SocialForge is closed and the Mac is awake."
        case .requiresApproval: "Waiting for your approval in System Settings > General > Login Items."
        case .notRegistered, .notFound: "Off: posts go out only while SocialForge is open."
        @unknown default: "Unknown"
        }
    }

    func setHelper(enabled: Bool) {
        do {
            if enabled {
                try helperService.register()
                if helperService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try helperService.unregister()
            }
        } catch {
            lastError = "Could not \(enabled ? "turn on" : "turn off") the background publisher: \(error.localizedDescription)"
        }
        modeRevision += 1
    }
}

/// Hardened loopback OAuth receiver: binds before the browser opens, accepts IPv4 & IPv6 localhost,
/// validates HTTP method & callback path, ignores stray browser requests (like /favicon.ico),
/// frames headers completely, and cleans up immediately on cancellation or timeout.
nonisolated final class OAuthLoopback: @unchecked Sendable {
    static let port: UInt16 = 8085
    let service: String
    let expectedPath: String?
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var callbackHandler: (@Sendable (Result<String, Error>) -> Void)?
    private var expectedState: String = ""

    init(service: String = "Pinterest", expectedPath: String? = nil) {
        self.service = service
        self.expectedPath = expectedPath
    }

    nonisolated enum LoopbackError: LocalizedError {
        case timeout, denied(String), badState, portBusy, cancelled
        var errorDescription: String? {
            switch self {
            case .timeout: "No answer from the browser within 5 minutes."
            case .denied(let why): "Access was not granted: \(why)"
            case .badState: "The sign-in state did not match this request."
            case .portBusy: "Port \(OAuthLoopback.port) is in use. Close what is using it and try again."
            case .cancelled: "Sign-in was canceled."
            }
        }
    }

    /// Binds the loopback port and waits until the listener is `.ready` BEFORE the caller opens the browser.
    func start() async throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { throw LoopbackError.portBusy }
        let ipv4Params = NWParameters.tcp
        ipv4Params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        guard let v4 = try? NWListener(using: ipv4Params) else { throw LoopbackError.portBusy }

        try await withCheckedThrowingContinuation { (readyCont: CheckedContinuation<Void, Error>) in
            let readyBox = OnceBox<Void>(readyCont)
            v4.stateUpdateHandler = { state in
                switch state {
                case .ready: readyBox.resume(.success(()))
                case .failed: readyBox.resume(.failure(LoopbackError.portBusy))
                case .cancelled: readyBox.resume(.failure(LoopbackError.cancelled))
                default: break
                }
            }
            v4.newConnectionHandler = { [weak self] conn in self?.handle(connection: conn) }
            v4.start(queue: .global())
        }

        // Best-effort IPv6 loopback listener so http://localhost:8085 also succeeds on macOS.
        let ipv6Params = NWParameters.tcp
        ipv6Params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "::1", port: port)
        var active = [v4]
        if let v6 = try? NWListener(using: ipv6Params) {
            v6.newConnectionHandler = { [weak self] conn in self?.handle(connection: conn) }
            v6.start(queue: .global())
            active.append(v6)
        }
        lock.withLock { self.listeners = active }
    }

    func stop() {
        let toCancel = lock.withLock { () -> [NWListener] in
            let copy = listeners
            listeners = []
            callbackHandler = nil
            return copy
        }
        for l in toCancel { l.cancel() }
    }

    func waitForCode(state: String, timeoutSeconds: TimeInterval = 300) async throws -> String {
        if lock.withLock({ listeners.isEmpty }) {
            try await start()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let box = OnceBox<String>(cont)
                lock.withLock {
                    self.expectedState = state
                    self.callbackHandler = { result in
                        box.resume(result)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    box.resume(.failure(LoopbackError.timeout))
                    self?.stop()
                }
            }
        } onCancel: {
            let handler = self.lock.withLock { self.callbackHandler }
            handler?(.failure(LoopbackError.cancelled))
            self.stop()
        }
    }

    private func handle(connection conn: NWConnection) {
        conn.start(queue: .global())
        receiveHeaders(on: conn, buffer: Data())
    }

    private func receiveHeaders(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var combined = buffer
            if let data { combined.append(data) }
            let marker = Data("\r\n\r\n".utf8)
            if combined.range(of: marker) == nil && !isComplete && combined.count < 32_768 {
                self.receiveHeaders(on: conn, buffer: combined)
                return
            }
            self.processRequest(combined, on: conn)
        }
    }

    private func processRequest(_ data: Data, on conn: NWConnection) {
        let request = String(data: data, encoding: .utf8) ?? ""
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawTarget = parts.dropFirst().first.map(String.init) ?? ""
        let comps = URLComponents(string: "http://127.0.0.1\(rawTarget)")
        let reqPath = comps?.path ?? ""

        // Ignore stray browser requests (e.g. /favicon.ico, preconnects, HEAD) without aborting OAuth!
        if method != "GET" || reqPath == "/favicon.ico" {
            sendResponse(status: "204 No Content", body: "", on: conn)
            return
        }
        if let expectedPath, !expectedPath.isEmpty, reqPath != expectedPath {
            sendResponse(status: "404 Not Found", body: "Not the callback path.", on: conn)
            return
        }

        let items = comps?.queryItems ?? []
        let value = { (n: String) in items.first { $0.name == n }?.value }
        let (state, handler) = lock.withLock { (expectedState, callbackHandler) }

        let body: String
        var finishResult: Result<String, Error>?
        if let err = value("error_description") ?? value("error") {
            body = "\(service) did not grant access. You can close this tab."
            finishResult = .failure(LoopbackError.denied(err))
        } else if value("state") != state {
            body = "This sign-in state does not match. Start again from SocialForge."
            finishResult = .failure(LoopbackError.badState)
        } else if let code = value("code"), !code.isEmpty {
            body = "\(service) is connected. You can close this tab and return to SocialForge."
            finishResult = .success(code)
        } else {
            body = "Waiting for \(service)…"
        }
        sendResponse(status: "200 OK", body: body, on: conn)
        if let finishResult {
            handler?(finishResult)
            stop()
        }
    }

    private func sendResponse(status: String, body: String, on conn: NWConnection) {
        let html = body.isEmpty ? "" : "<!doctype html><meta charset=utf-8><meta name=referrer content=no-referrer><body style='font:16px -apple-system;margin:20vh auto;max-width:28em'><p>\(body)</p>"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((headers + html).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private nonisolated final class OnceBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { cont = c }
        func resume(_ r: Result<T, Error>) {
            let c: CheckedContinuation<T, Error>? = lock.withLock { let c = cont; cont = nil; return c }
            c?.resume(with: r)
        }
    }
}

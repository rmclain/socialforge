import AppKit
import Foundation
import SwiftData
import SocialForgeKit

// Connecting social platforms via either:
// 1. Hosted Stateless OAuth Relay (e.g. Vercel) — One-Click Sign In via socialforge:// deep link.
// 2. Bring-Your-Own-Credentials (BYOK) — your own developer apps in the macOS Keychain.
// Access tokens, refresh tokens, app secrets, and storage keys always remain in the local Keychain.

/// Settings for the optional hosted stateless OAuth Relay (Vercel or any HTTPS host).
nonisolated enum OAuthRelaySettings {
    static let urlKey = "oauthRelay.url"

    static var bundledURL: String {
        (Bundle.main.infoDictionary?["SFOAuthRelayURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var initialURL: String {
        if Store.isOverridden { return bundledURL }
        let saved = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? bundledURL : saved
    }

    static var configuredURL: URL? {
        let raw = initialURL
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    /// Maps SocialForge platform + auth variant to the relay's provider identifier.
    static func relayPlatformKey(platform: String, authVariant: String = "default") -> String {
        if platform == "instagram" {
            return authVariant == "instagram_login" ? "instagram_login" : "facebook"
        }
        return platform
    }
}

/// A sign-in started in the browser, waiting for either a `socialforge://oauth/callback` deep link
/// or a pasted callback URL.
struct PendingOAuth: Equatable {
    enum Kind: String {
        case pinterest, facebook, instagramLogin, threads, linkedin, x, tiktok, youtube
        var relayProviderKey: String {
            switch self {
            case .instagramLogin: "instagram_login"
            default: rawValue
            }
        }
    }
    let kind: Kind
    let state: String
    let redirectURI: String
    /// Captured at OAuth start so switching workspaces never attaches accounts to the wrong brand.
    let workspaceID: UUID
    /// True when started through a hosted stateless OAuth Relay instead of local BYOK app secrets.
    let viaRelay: Bool
    let relayBaseURL: URL?
    let codeVerifier: String?
    let authVariant: String

    init(
        kind: Kind,
        state: String,
        redirectURI: String,
        workspaceID: UUID,
        viaRelay: Bool = false,
        relayBaseURL: URL? = nil,
        codeVerifier: String? = nil,
        authVariant: String = "default"
    ) {
        self.kind = kind
        self.state = state
        self.redirectURI = redirectURI
        self.workspaceID = workspaceID
        self.viaRelay = viaRelay
        self.relayBaseURL = relayBaseURL
        self.codeVerifier = codeVerifier
        self.authVariant = authVariant
    }

    var serviceName: String {
        switch kind {
        case .pinterest: "Pinterest"
        case .facebook: "Facebook & Instagram"
        case .instagramLogin: "Instagram"
        case .threads: "Threads"
        case .linkedin: "LinkedIn"
        case .x: "X"
        case .tiktok: "TikTok"
        case .youtube: "YouTube"
        }
    }

    var relayProviderKey: String {
        switch kind {
        case .instagramLogin: "instagram_login"
        default: kind.rawValue
        }
    }
}

/// The public media storage settings (an S3-compatible bucket such as Cloudflare R2 or AWS S3).
nonisolated enum PublicMediaSettings {
    static let endpointKey = "media.endpoint", bucketKey = "media.bucket", regionKey = "media.region", publicKey = "media.publicBase"
    static let styleKey = "media.addressingStyle", prefixKey = "media.prefix"
    static let accessKeyItem = "media.accessKeyID", secretItem = "media.secretAccessKey"

    static func config() -> S3Config? {
        let d = UserDefaults.standard
        let style = S3AddressingStyle(rawValue: d.string(forKey: styleKey) ?? "") ?? .auto
        let prefix = d.string(forKey: prefixKey) ?? "socialforge"
        return S3Config.make(
            endpoint: d.string(forKey: endpointKey) ?? "",
            bucket: d.string(forKey: bucketKey) ?? "",
            region: d.string(forKey: regionKey) ?? "auto",
            accessKeyID: Keychain.read(accessKeyItem) ?? "",
            secret: Keychain.read(secretItem) ?? "",
            publicBase: d.string(forKey: publicKey) ?? "",
            prefix: prefix,
            addressingStyle: style
        )
    }

    /// Nil when storage is not set up; Instagram photos and Threads media are then refused with the reason.
    static func host() -> S3Uploader? { config().map { S3Uploader(config: $0) } }
}

enum MetaSettings {
    static let appIDItem = "meta.appID", secretItem = "meta.appSecret"
    static let instagramIDItem = "instagram.appID", instagramSecretItem = "instagram.appSecret"
    static let threadsIDItem = "threads.appID", threadsSecretItem = "threads.appSecret"
    static let configKey = "meta.configID", redirectKey = "meta.redirect"
    static let instagramRedirectKey = "instagram.redirect"
    static let threadsRedirectKey = "threads.redirect"
    static let pinterestRedirectKey = "pinterest.redirect"
    static let defaultHTTPSRedirect = "https://rmclain.github.io/socialforge/"
    static let defaultThreadsRedirect = defaultHTTPSRedirect

    static var redirect: String {
        if Store.isOverridden { return Meta.desktopRedirect }
        return UserDefaults.standard.string(forKey: redirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? Meta.desktopRedirect
    }
    static var instagramRedirect: String {
        if Store.isOverridden { return defaultHTTPSRedirect }
        return UserDefaults.standard.string(forKey: instagramRedirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultHTTPSRedirect
    }
    static var threadsRedirect: String {
        if Store.isOverridden { return defaultHTTPSRedirect }
        return UserDefaults.standard.string(forKey: threadsRedirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultHTTPSRedirect
    }
    static var pinterestRedirect: String {
        if Store.isOverridden { return defaultHTTPSRedirect }
        let raw = UserDefaults.standard.string(forKey: pinterestRedirectKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "http://127.0.0.1:\(OAuthLoopback.port)/pinterest/callback" {
            return defaultHTTPSRedirect
        }
        return (raw?.isEmpty == false ? raw! : defaultHTTPSRedirect)
    }

    /// A redirect to http://127.0.0.1:8085 or http://localhost:8085 is answered by SocialForge itself.
    static func isLoopback(_ redirect: String) -> Bool {
        guard let u = URL(string: redirect), u.scheme == "http", ["127.0.0.1", "localhost"].contains(u.host ?? "") else { return false }
        return u.port == Int(OAuthLoopback.port)
    }
}

extension AppModel {
    /// Checks the configured stateless OAuth Relay (GET /api/providers) and caches enabled platforms.
    func checkOAuthRelay() async {
        let raw = oauthRelayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            oauthRelayCapabilities = nil
            oauthRelayStatus = .unconfigured
            return
        }
        guard let url = URL(string: raw) else {
            oauthRelayCapabilities = nil
            oauthRelayStatus = .error("Enter a valid https:// URL for your OAuth Relay.")
            return
        }
        oauthRelayStatus = .checking
        do {
            let client = try OAuthRelayClient(baseURL: url)
            let caps = try await client.fetchCapabilities()
            oauthRelayCapabilities = caps
            let enabledCount = caps.providers.filter(\.enabled).count
            oauthRelayStatus = .ready(enabledCount: enabledCount)
            log("Verified OAuth Relay (\(enabledCount) one-click platform\(enabledCount == 1 ? "" : "s") enabled)", symbol: "bolt.shield", category: "connection")
        } catch {
            oauthRelayCapabilities = nil
            oauthRelayStatus = .error(DiagnosticRedactor.sanitize(error.localizedDescription))
        }
    }

    /// Returns true if the hosted OAuth Relay is reachable and has this platform enabled.
    func relaySupports(platform: String, authVariant: String = "default") -> Bool {
        guard let caps = oauthRelayCapabilities else { return false }
        let key = OAuthRelaySettings.relayPlatformKey(platform: platform, authVariant: authVariant)
        return caps.isEnabled(key)
    }

    /// Starts One-Click OAuth sign-in through the configured stateless OAuth Relay (e.g. Vercel).
    func connectViaRelay(_ platform: String, authMode: String = "default") async {
        guard let targetWorkspace = workspaceID else { return }
        let raw = oauthRelayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relayURL = URL(string: raw) else {
            lastError = "Configure your OAuth Relay URL in Connections › Publishing Infrastructure first."
            return
        }
        let kind: PendingOAuth.Kind
        switch platform {
        case "pinterest": kind = .pinterest
        case "facebook": kind = .facebook
        case "instagram": kind = authMode == "instagram_login" ? .instagramLogin : .facebook
        case "threads": kind = .threads
        case "linkedin": kind = .linkedin
        case "x": kind = .x
        case "tiktok": kind = .tiktok
        case "youtube": kind = .youtube
        default:
            lastError = "Unsupported OAuth relay platform: \(platform)."
            return
        }
        do {
            let client = try OAuthRelayClient(baseURL: relayURL)
            if oauthRelayCapabilities == nil {
                oauthRelayCapabilities = try await client.fetchCapabilities()
            }
            let relayKey = kind.relayProviderKey
            guard let provider = oauthRelayCapabilities?.provider(relayKey), provider.enabled else {
                lastError = "\(kind.rawValue.capitalized) is not enabled on this OAuth Relay yet. Configure its environment variables in Vercel or use My Own Developer App (BYOK)."
                return
            }
            let state = UUID().uuidString
            let pkce: PKCEPair? = provider.pkceRequired ? PKCEPair.generate() : nil
            let startURL = client.startURL(
                platform: relayKey,
                state: state,
                codeChallenge: pkce?.challenge,
                mode: authMode == "default" ? nil : authMode
            )
            pendingOAuth = PendingOAuth(
                kind: kind,
                state: state,
                redirectURI: provider.redirectURI,
                workspaceID: targetWorkspace,
                viaRelay: true,
                relayBaseURL: client.baseURL,
                codeVerifier: pkce?.verifier,
                authVariant: authMode
            )
            metaMessage = "Waiting for \(pendingOAuth?.serviceName ?? platform) in your browser… SocialForge will finish automatically when redirected."
            NSWorkspace.shared.open(startURL)
        } catch {
            lastError = "OAuth Relay sign-in failed: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    /// Handles incoming `socialforge://oauth/callback?...` deep links from both the Vercel OAuth Relay
    /// and the GitHub Pages BYOK callback page.
    func handleIncomingOAuthURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "socialforge",
              url.host?.lowercased() == "oauth" else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let pending = pendingOAuth else {
            metaMessage = "Received an OAuth callback, but no sign-in session is active. Start connecting from Connections."
            return
        }
        do {
            let result = try OAuthRelayClient.parseCallbackURL(url, expectedState: pending.state)
            if !result.platform.isEmpty && result.platform != pending.relayProviderKey && result.platform != pending.kind.rawValue {
                metaMessage = "Callback platform (\(result.platform)) did not match active \(pending.serviceName) session."
                return
            }
            // Consume the single-use pending session before exchanging.
            pendingOAuth = nil
            await finishOAuth(pending, code: result.code)
        } catch {
            metaMessage = DiagnosticRedactor.sanitize(error.localizedDescription)
        }
    }

    /// Starts BYOK OAuth for Pinterest, Facebook (Pages & linked Instagram), direct Instagram Business Login, or Threads.
    func connectMeta(_ kind: PendingOAuth.Kind) async {
        guard let targetWorkspace = workspaceID else { return }
        let (idItem, secretItem, label): (String, String, String) = switch kind {
        case .pinterest: ("pinterest.clientID", "pinterest.clientSecret", "Pinterest")
        case .facebook: (MetaSettings.appIDItem, MetaSettings.secretItem, "Meta")
        case .instagramLogin: (MetaSettings.instagramIDItem, MetaSettings.instagramSecretItem, "Instagram")
        case .threads: (MetaSettings.threadsIDItem, MetaSettings.threadsSecretItem, "Threads")
        default: ("\(kind.rawValue).clientID", "\(kind.rawValue).clientSecret", kind.rawValue.capitalized)
        }
        guard let appID = Keychain.read(idItem), !appID.isEmpty, Keychain.read(secretItem)?.isEmpty == false else {
            lastError = "Add your \(label) app's ID and secret in Connections first."
            page = .accounts
            return
        }
        let redirect: String = switch kind {
        case .pinterest: MetaSettings.pinterestRedirect
        case .facebook: MetaSettings.redirect
        case .instagramLogin: MetaSettings.instagramRedirect
        case .threads: MetaSettings.threadsRedirect
        default: MetaSettings.defaultHTTPSRedirect
        }
        let state = UUID().uuidString
        let url: URL = switch kind {
        case .pinterest:
            PinterestTarget.authorizeURL(clientID: appID, redirectURI: redirect, state: state)
        case .facebook:
            MetaAuth.facebookAuthorizeURL(appID: appID, redirectURI: redirect, state: state,
                                          configID: UserDefaults.standard.string(forKey: MetaSettings.configKey))
        case .instagramLogin:
            MetaAuth.instagramLoginAuthorizeURL(appID: appID, redirectURI: redirect, state: state)
        case .threads:
            MetaAuth.threadsAuthorizeURL(appID: appID, redirectURI: redirect, state: state)
        default:
            PinterestTarget.authorizeURL(clientID: appID, redirectURI: redirect, state: state)
        }
        let pending = PendingOAuth(kind: kind, state: state, redirectURI: redirect, workspaceID: targetWorkspace, viaRelay: false)
        if MetaSettings.isLoopback(redirect) {
            busyMessage = "Waiting for \(pending.serviceName) in your browser…"
            defer { busyMessage = nil }
            do {
                let path = URL(string: redirect)?.path
                let loopback = OAuthLoopback(service: pending.serviceName, expectedPath: path?.isEmpty == false ? path : nil)
                try await loopback.start()
                NSWorkspace.shared.open(url)
                let code = try await loopback.waitForCode(state: state)
                await finishOAuth(pending, code: code)
            } catch {
                lastError = "\(pending.serviceName) sign-in did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
            }
        } else {
            pendingOAuth = pending
            metaMessage = nil
            NSWorkspace.shared.open(url)
        }
    }

    /// Validates a manually pasted callback URL (including state & redirect URI) and completes token exchange.
    func finishMeta(pasted: String) async {
        guard let pending = pendingOAuth else { return }
        do {
            let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            let code: String
            if trimmed.lowercased().hasPrefix("socialforge://"), let u = URL(string: trimmed) {
                code = try OAuthRelayClient.parseCallbackURL(u, expectedState: pending.state).code
            } else {
                code = try OAuthRedirect.code(from: trimmed, state: pending.state, expectedRedirectURI: pending.redirectURI)
            }
            // Single-use code is now consumed regardless of downstream outcome.
            pendingOAuth = nil
            await finishOAuth(pending, code: code)
        } catch {
            metaMessage = DiagnosticRedactor.sanitize(error.localizedDescription)
        }
    }

    private func finishOAuth(_ pending: PendingOAuth, code: String) async {
        let targetWorkspace = pending.workspaceID
        busyMessage = "Connecting \(pending.serviceName)…"
        defer { busyMessage = nil }
        do {
            if pending.viaRelay {
                try await finishViaRelay(pending, code: code, targetWorkspace: targetWorkspace)
            } else {
                try await finishBYOK(pending, code: code, targetWorkspace: targetWorkspace)
            }
            saveContext("finishOAuth")
            log(metaMessage ?? "Connected \(pending.serviceName)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            metaMessage = "\(pending.serviceName) connection did not finish: \(DiagnosticRedactor.sanitize(e.message))"
        } catch {
            metaMessage = "\(pending.serviceName) connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
        }
    }

    private func finishViaRelay(_ pending: PendingOAuth, code: String, targetWorkspace: UUID) async throws {
        guard let relayBase = pending.relayBaseURL ?? OAuthRelaySettings.configuredURL else {
            throw OAuthRelayError.invalidCallback("OAuth Relay URL is no longer configured.")
        }
        let client = try OAuthRelayClient(baseURL: relayBase)
        let isPinterestSandbox = (UserDefaults.standard.string(forKey: "pinterest.apiBase") ?? "").contains("sandbox")
        let token = try await client.exchange(
            platform: pending.relayProviderKey,
            code: code,
            redirectURI: pending.redirectURI,
            codeVerifier: pending.codeVerifier,
            sandbox: pending.kind == .pinterest && isPinterestSandbox
        )

        switch pending.kind {
        case .pinterest:
            let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:)) ?? URL(string: "https://api.pinterest.com")!
            let target = PinterestTarget(apiBase: base)
            let user = try await target.userAccount(accessToken: token.accessToken)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "pinterest", platformID: user.id,
                name: user.name, handle: "@\(user.username)", token: token.accessToken,
                refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                scopes: token.scopeList.isEmpty ? PinterestTarget.scopes : token.scopeList,
                accountType: "business", authMode: target.isSandbox ? "relay:sandbox" : "relay:production"
            )
            metaMessage = "Connected Pinterest as \(user.name) via One-Click Relay."

        case .facebook:
            let auth = MetaAuth()
            let granted = (try? await auth.grantedPermissions(token.accessToken)) ?? Meta.facebookScopes
            let pages = try await auth.pages(token.accessToken)
            guard !pages.isEmpty else {
                metaMessage = "Facebook connected, but no Pages came back. Verify that your account manages a Page and granted pages_show_list."
                return
            }
            var names: [String] = []
            for page in pages {
                try upsertMacAccount(
                    workspaceID: targetWorkspace, platform: "facebook", platformID: page.id,
                    name: page.name, handle: page.name, token: page.token,
                    expiresIn: nil, scopes: granted, accountType: "page", authMode: "relay:facebook_login"
                )
                names.append(page.name)
                if let ig = page.instagramID {
                    let handle = page.instagramUsername.map { "@\($0)" } ?? page.name
                    try upsertMacAccount(
                        workspaceID: targetWorkspace, platform: "instagram", platformID: ig,
                        name: page.instagramUsername ?? page.name, handle: handle, token: token.accessToken,
                        expiresIn: token.expiresIn, scopes: granted, accountType: "business", authMode: "relay:facebook_login"
                    )
                    names.append(handle)
                }
            }
            metaMessage = "Connected \(names.joined(separator: ", ")) via One-Click Relay."

        case .instagramLogin:
            let profile = try await MetaAuth().instagramProfile(token.accessToken)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "instagram", platformID: token.userID ?? profile.id,
                name: profile.username, handle: "@\(profile.username)", token: token.accessToken,
                expiresIn: token.expiresIn, scopes: Meta.instagramLoginScopes,
                accountType: profile.accountType?.lowercased() ?? "business", authMode: "relay:instagram_login"
            )
            metaMessage = "Connected @\(profile.username) via One-Click Relay."

        case .threads:
            let profile = try await MetaAuth().threadsProfile(token.accessToken)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "threads", platformID: token.userID ?? profile.id,
                name: profile.username, handle: "@\(profile.username)", token: token.accessToken,
                expiresIn: token.expiresIn, scopes: Meta.threadsScopes,
                accountType: "profile", authMode: "relay:threads"
            )
            metaMessage = "Connected @\(profile.username) on Threads via One-Click Relay."

        case .linkedin:
            let identity = try await LinkedInAuth().discoverIdentity(accessToken: token.accessToken)
            let includeOrgs = pending.authVariant == "organization"
            let granted = token.scopeList.isEmpty ? (includeOrgs ? LinkedInAuth.organizationScopes : LinkedInAuth.memberScopes) : token.scopeList
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "linkedin", platformID: identity.memberURN,
                name: identity.name, handle: identity.name, token: token.accessToken,
                refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                scopes: granted, accountType: identity.organizations.isEmpty ? "personal" : "organization", authMode: "relay:oauth2"
            )
            for org in identity.organizations {
                try upsertMacAccount(
                    workspaceID: targetWorkspace, platform: "linkedin", platformID: org.id,
                    name: org.name, handle: org.name, token: token.accessToken,
                    refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                    scopes: granted, accountType: "organization", authMode: "relay:oauth2"
                )
            }
            metaMessage = "Connected LinkedIn as \(identity.name) via One-Click Relay."

        case .x:
            let user = try await XAuth().currentUser(accessToken: token.accessToken)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "x", platformID: user.id,
                name: user.name, handle: "@\(user.username)", token: token.accessToken,
                refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                scopes: token.scopeList.isEmpty ? XAuth.scopes : token.scopeList,
                accountType: "account", authMode: "relay:pkce"
            )
            metaMessage = "Connected X as @\(user.username) via One-Click Relay."

        case .tiktok:
            let creator = try? await TikTokAuth().queryCreatorInfo(accessToken: token.accessToken)
            let displayName = creator?.nickname.isEmpty == false ? creator!.nickname : "TikTok Creator"
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "tiktok", platformID: token.userID ?? displayName,
                name: displayName, handle: "@\(displayName)", token: token.accessToken,
                refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                scopes: token.scopeList.isEmpty ? TikTokAuth.scopes : token.scopeList,
                accountType: "creator", authMode: "relay:pkce"
            )
            metaMessage = "Connected TikTok as \(displayName) via One-Click Relay."

        case .youtube:
            let channels = try await YouTubeAuth().channels(accessToken: token.accessToken)
            guard !channels.isEmpty else {
                metaMessage = "Google signed in, but no YouTube channels were found on this account."
                return
            }
            for ch in channels {
                try upsertMacAccount(
                    workspaceID: targetWorkspace, platform: "youtube", platformID: ch.id,
                    name: ch.name, handle: ch.name, token: token.accessToken,
                    refreshToken: token.refreshToken, expiresIn: token.expiresIn,
                    scopes: token.scopeList.isEmpty ? YouTubeAuth.scopes : token.scopeList,
                    accountType: "channel", authMode: "relay:pkce"
                )
            }
            metaMessage = "Connected YouTube channel \(channels.map(\.name).joined(separator: ", ")) via One-Click Relay."
        }
    }

    private func finishBYOK(_ pending: PendingOAuth, code: String, targetWorkspace: UUID) async throws {
        let auth = MetaAuth()
        switch pending.kind {
        case .pinterest:
            let clientID = Keychain.read("pinterest.clientID") ?? ""
            let secret = Keychain.read("pinterest.clientSecret") ?? ""
            let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:)) ?? URL(string: "https://api.pinterest.com")!
            let target = PinterestTarget(apiBase: base)
            let tokens = try await target.exchange(code: code, redirectURI: pending.redirectURI, clientID: clientID, clientSecret: secret)
            let user = try await target.userAccount(accessToken: tokens.access)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "pinterest", platformID: user.id,
                name: user.name, handle: "@\(user.username)", token: tokens.access,
                refreshToken: tokens.refresh, expiresIn: tokens.expiresIn,
                scopes: tokens.scopes.isEmpty ? PinterestTarget.scopes : tokens.scopes,
                accountType: "business", authMode: target.isSandbox ? "sandbox" : "production"
            )
            metaMessage = "Connected Pinterest as \(user.name)."
        case .facebook:
            let token = try await auth.facebookToken(code: code, redirectURI: pending.redirectURI,
                                                     appID: Keychain.read(MetaSettings.appIDItem) ?? "",
                                                     secret: Keychain.read(MetaSettings.secretItem) ?? "")
            let granted = (try? await auth.grantedPermissions(token.token)) ?? Meta.facebookScopes
            let pages = try await auth.pages(token.token)
            guard !pages.isEmpty else {
                metaMessage = "Facebook connected, but no Pages came back. SocialForge only publishes to Facebook Pages (personal profiles are not supported by Meta's API). Verify that your account manages a Page and granted pages_show_list."
                return
            }
            var names: [String] = []
            for page in pages {
                try upsertMacAccount(
                    workspaceID: targetWorkspace, platform: "facebook", platformID: page.id,
                    name: page.name, handle: page.name, token: page.token,
                    expiresIn: nil, scopes: granted, accountType: "page", authMode: "facebook_login"
                )
                names.append(page.name)
                if let ig = page.instagramID {
                    let handle = page.instagramUsername.map { "@\($0)" } ?? page.name
                    try upsertMacAccount(
                        workspaceID: targetWorkspace, platform: "instagram", platformID: ig,
                        name: page.instagramUsername ?? page.name, handle: handle, token: token.token,
                        expiresIn: token.expiresIn, scopes: granted, accountType: "business", authMode: "facebook_login"
                    )
                    names.append(handle)
                }
            }
            let noIG = !pages.contains { $0.instagramID != nil }
            metaMessage = "Connected \(names.joined(separator: ", "))."
                + (noIG ? " No Instagram professional account is linked to these Pages (or connect directly with Instagram Business Login)." : "")
        case .instagramLogin:
            let token = try await auth.instagramLoginToken(
                code: code, redirectURI: pending.redirectURI,
                appID: Keychain.read(MetaSettings.instagramIDItem) ?? "",
                secret: Keychain.read(MetaSettings.instagramSecretItem) ?? ""
            )
            let profile = try await auth.instagramProfile(token.token)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "instagram", platformID: token.userID ?? profile.id,
                name: profile.username, handle: "@\(profile.username)", token: token.token,
                expiresIn: token.expiresIn, scopes: Meta.instagramLoginScopes,
                accountType: profile.accountType?.lowercased() ?? "business", authMode: "instagram_login"
            )
            metaMessage = "Connected @\(profile.username) via Instagram Business Login."
        case .threads:
            let token = try await auth.threadsToken(code: code, redirectURI: pending.redirectURI,
                                                    appID: Keychain.read(MetaSettings.threadsIDItem) ?? "",
                                                    secret: Keychain.read(MetaSettings.threadsSecretItem) ?? "")
            let profile = try await auth.threadsProfile(token.token)
            try upsertMacAccount(
                workspaceID: targetWorkspace, platform: "threads", platformID: token.userID ?? profile.id,
                name: profile.username, handle: "@\(profile.username)", token: token.token,
                expiresIn: token.expiresIn, scopes: Meta.threadsScopes,
                accountType: "profile", authMode: "threads_oauth"
            )
            metaMessage = "Connected @\(profile.username) on Threads."
        default:
            throw PublishFailure(.permanent, "Use the dedicated loopback flow or OAuth Relay for \(pending.serviceName).")
        }
    }

    /// Full round-trip S3/R2 storage test: PUT, public GET content & Content-Type check, and verified DELETE cleanup.
    func testPublicMedia() async {
        guard let host = PublicMediaSettings.host() else {
            publicMediaVerification = nil
            metaMessage = "Fill in every storage field (both addresses must start with https://) and save the keys first."
            return
        }
        busyMessage = "Testing public media storage…"
        defer { busyMessage = nil }
        let report = await host.verifyConnection()
        publicMediaVerification = report
        if report.passed {
            metaMessage = report.summary
            log("Verified public media storage (upload, public read, delete)", symbol: "externaldrive.badge.checkmark", category: "connection")
        } else {
            metaMessage = [report.summary, report.error].compactMap { $0 }.joined(separator: " ")
        }
        modeRevision += 1
    }
}

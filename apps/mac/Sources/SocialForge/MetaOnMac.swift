import AppKit
import Foundation
import SwiftData
import SocialForgeKit

// Connecting Facebook Pages, Instagram professional accounts (via Facebook Login or
// direct Instagram Business Login), and Threads with your own Meta apps.
// App ids and secrets, account tokens, and storage keys stay in the Keychain.

/// A sign-in started in the browser, waiting for the address it lands on.
struct PendingOAuth: Equatable {
    enum Kind: String { case facebook, instagramLogin, threads }
    let kind: Kind
    let state: String
    let redirectURI: String
    /// Captured at OAuth start so switching workspaces never attaches accounts to the wrong brand.
    let workspaceID: UUID

    var serviceName: String {
        switch kind {
        case .facebook: "Facebook & Instagram"
        case .instagramLogin: "Instagram"
        case .threads: "Threads"
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
    static let defaultThreadsRedirect = "https://rmclain.github.io/socialforge/"

    static var redirect: String { UserDefaults.standard.string(forKey: redirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? Meta.desktopRedirect }
    static var instagramRedirect: String {
        UserDefaults.standard.string(forKey: instagramRedirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultThreadsRedirect
    }
    static var threadsRedirect: String {
        UserDefaults.standard.string(forKey: threadsRedirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultThreadsRedirect
    }

    /// A redirect to http://127.0.0.1:8085 or http://localhost:8085 is answered by SocialForge itself.
    static func isLoopback(_ redirect: String) -> Bool {
        guard let u = URL(string: redirect), u.scheme == "http", ["127.0.0.1", "localhost"].contains(u.host ?? "") else { return false }
        return u.port == Int(OAuthLoopback.port)
    }
}

extension AppModel {
    /// Starts Facebook (Pages & linked Instagram), direct Instagram Business Login, or Threads sign-in.
    func connectMeta(_ kind: PendingOAuth.Kind) async {
        guard let targetWorkspace = workspaceID else { return }
        let (idItem, secretItem, label): (String, String, String) = switch kind {
        case .facebook: (MetaSettings.appIDItem, MetaSettings.secretItem, "Meta")
        case .instagramLogin: (MetaSettings.instagramIDItem, MetaSettings.instagramSecretItem, "Instagram")
        case .threads: (MetaSettings.threadsIDItem, MetaSettings.threadsSecretItem, "Threads")
        }
        guard let appID = Keychain.read(idItem), !appID.isEmpty, Keychain.read(secretItem)?.isEmpty == false else {
            lastError = "Add your \(label) app's ID and secret in Connections first."
            page = .accounts
            return
        }
        let redirect: String = switch kind {
        case .facebook: MetaSettings.redirect
        case .instagramLogin: MetaSettings.instagramRedirect
        case .threads: MetaSettings.threadsRedirect
        }
        let state = UUID().uuidString
        let url: URL = switch kind {
        case .facebook:
            MetaAuth.facebookAuthorizeURL(appID: appID, redirectURI: redirect, state: state,
                                          configID: UserDefaults.standard.string(forKey: MetaSettings.configKey))
        case .instagramLogin:
            MetaAuth.instagramLoginAuthorizeURL(appID: appID, redirectURI: redirect, state: state)
        case .threads:
            MetaAuth.threadsAuthorizeURL(appID: appID, redirectURI: redirect, state: state)
        }
        let pending = PendingOAuth(kind: kind, state: state, redirectURI: redirect, workspaceID: targetWorkspace)
        if MetaSettings.isLoopback(redirect) {
            busyMessage = "Waiting for \(pending.serviceName) in your browser…"
            defer { busyMessage = nil }
            do {
                let path = URL(string: redirect)?.path
                let loopback = OAuthLoopback(service: pending.serviceName, expectedPath: path?.isEmpty == false ? path : nil)
                try await loopback.start()
                NSWorkspace.shared.open(url)
                let code = try await loopback.waitForCode(state: state)
                await finishMeta(pending, code: code)
            } catch {
                lastError = "\(pending.serviceName) sign-in did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
            }
        } else {
            pendingOAuth = pending
            metaMessage = nil
            NSWorkspace.shared.open(url)
        }
    }

    /// Validates the complete pasted callback URL (including state & redirect URI) and completes token exchange.
    func finishMeta(pasted: String) async {
        guard let pending = pendingOAuth else { return }
        do {
            let code = try OAuthRedirect.code(from: pasted, state: pending.state, expectedRedirectURI: pending.redirectURI)
            // Single-use code is now consumed regardless of downstream outcome.
            pendingOAuth = nil
            await finishMeta(pending, code: code)
        } catch {
            metaMessage = error.description
        }
    }

    private func finishMeta(_ pending: PendingOAuth, code: String) async {
        let targetWorkspace = pending.workspaceID
        let auth = MetaAuth()
        busyMessage = "Connecting \(pending.serviceName)…"
        defer { busyMessage = nil }
        do {
            switch pending.kind {
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
            }
            saveContext("finishMeta")
            log(metaMessage ?? "Connected \(pending.serviceName)", symbol: "link", category: "connection", workspace: targetWorkspace)
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            metaMessage = "\(pending.serviceName) connection did not finish: \(DiagnosticRedactor.sanitize(e.message))"
        } catch {
            metaMessage = "\(pending.serviceName) connection did not finish: \(DiagnosticRedactor.sanitize(error.localizedDescription))"
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

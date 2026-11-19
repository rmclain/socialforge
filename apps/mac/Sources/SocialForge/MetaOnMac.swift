import AppKit
import Foundation
import SwiftData
import SocialForgeKit

// Connecting Facebook Pages, Instagram professional accounts, and Threads with
// your own Meta apps. App ids and secrets, account tokens, and storage keys stay
// in the Keychain. See docs/META_SETUP.md.

/// A sign-in started in the browser, waiting for the address it lands on.
struct PendingOAuth: Equatable {
    enum Kind: String { case facebook, threads }
    let kind: Kind
    let state: String
    let redirectURI: String

    var serviceName: String { kind == .facebook ? "Facebook" : "Threads" }
}

/// The public media storage settings (an S3-compatible bucket such as Cloudflare R2).
enum PublicMediaSettings {
    static let endpointKey = "media.endpoint", bucketKey = "media.bucket", regionKey = "media.region", publicKey = "media.publicBase"
    static let accessKeyItem = "media.accessKeyID", secretItem = "media.secretAccessKey"

    static var config: S3Config? {
        let d = UserDefaults.standard
        return S3Config.make(endpoint: d.string(forKey: endpointKey) ?? "", bucket: d.string(forKey: bucketKey) ?? "",
                             region: d.string(forKey: regionKey) ?? "auto", accessKeyID: Keychain.read(accessKeyItem) ?? "",
                             secret: Keychain.read(secretItem) ?? "", publicBase: d.string(forKey: publicKey) ?? "")
    }

    /// Nil when storage is not set up; Instagram photos and Threads media are then refused with the reason.
    static func host() -> S3Uploader? { config.map { S3Uploader(config: $0) } }
}

enum MetaSettings {
    static let appIDItem = "meta.appID", secretItem = "meta.appSecret"
    static let threadsIDItem = "threads.appID", threadsSecretItem = "threads.appSecret"
    static let configKey = "meta.configID", redirectKey = "meta.redirect", threadsRedirectKey = "threads.redirect"
    static let defaultThreadsRedirect = "https://rmclain.github.io/socialforge/"

    static var redirect: String { UserDefaults.standard.string(forKey: redirectKey).flatMap { $0.isEmpty ? nil : $0 } ?? Meta.desktopRedirect }
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
    /// Starts Facebook (Pages and Instagram) or Threads sign-in in the browser.
    func connectMeta(_ kind: PendingOAuth.Kind) async {
        guard workspaceID != nil else { return }
        let (idItem, secretItem) = kind == .facebook ? (MetaSettings.appIDItem, MetaSettings.secretItem)
                                                     : (MetaSettings.threadsIDItem, MetaSettings.threadsSecretItem)
        guard let appID = Keychain.read(idItem), !appID.isEmpty, Keychain.read(secretItem)?.isEmpty == false else {
            lastError = "Add your \(kind == .facebook ? "Meta" : "Threads") app's ID and secret in Settings › Publishing first."
            settingsTab = .publishing
            page = .settings
            return
        }
        let redirect = kind == .facebook ? MetaSettings.redirect : MetaSettings.threadsRedirect
        let state = UUID().uuidString
        let url = kind == .facebook
            ? MetaAuth.facebookAuthorizeURL(appID: appID, redirectURI: redirect, state: state,
                                            configID: UserDefaults.standard.string(forKey: MetaSettings.configKey))
            : MetaAuth.threadsAuthorizeURL(appID: appID, redirectURI: redirect, state: state)
        let pending = PendingOAuth(kind: kind, state: state, redirectURI: redirect)
        if MetaSettings.isLoopback(redirect) {
            busyMessage = "Waiting for \(pending.serviceName) in your browser…"
            defer { busyMessage = nil }
            do {
                let loopback = OAuthLoopback()
                loopback.service = pending.serviceName
                let codeTask = Task { try await loopback.waitForCode(state: state) }
                NSWorkspace.shared.open(url)
                await finishMeta(pending, code: try await codeTask.value)
            } catch {
                lastError = "\(pending.serviceName) sign-in did not finish: \(error.localizedDescription)"
            }
        } else {
            // The browser lands on an https page; the person pastes that address back (Settings shows the field).
            pendingOAuth = pending
            metaMessage = nil
            settingsTab = .publishing
            NSWorkspace.shared.open(url)
        }
    }

    /// The address the browser landed on (or the code), pasted into Settings.
    func finishMeta(pasted: String) async {
        guard let pending = pendingOAuth else { return }
        do {
            let code = try OAuthRedirect.code(from: pasted, state: pending.state)
            await finishMeta(pending, code: code)
            if metaMessage?.hasPrefix("Connected") == true { pendingOAuth = nil }
        } catch {
            metaMessage = error.description
        }
    }

    private func finishMeta(_ pending: PendingOAuth, code: String) async {
        guard let workspaceID else { return }
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
                    metaMessage = "Facebook connected, but no Pages came back. Allow access to your Pages when Facebook asks, or check that your account manages a Page."
                    return
                }
                var names: [String] = []
                for page in pages {
                    // Page tokens made from a long-lived user token do not expire.
                    upsertAccount(workspaceID, platform: "facebook", id: page.id, name: page.name, handle: page.name,
                                  token: page.token, expiresIn: nil, scopes: granted)
                    names.append(page.name)
                    if let ig = page.instagramID {
                        let handle = page.instagramUsername.map { "@\($0)" } ?? page.name
                        upsertAccount(workspaceID, platform: "instagram", id: ig, name: page.instagramUsername ?? page.name, handle: handle,
                                      token: token.token, expiresIn: token.expiresIn, scopes: granted)
                        names.append(handle)
                    }
                }
                let noIG = !pages.contains { $0.instagramID != nil }
                metaMessage = "Connected \(names.joined(separator: ", "))."
                    + (noIG ? " No Instagram professional account is linked to these Pages; link one in the Instagram app (Settings › Account type and tools) to post there." : "")
            case .threads:
                let token = try await auth.threadsToken(code: code, redirectURI: pending.redirectURI,
                                                        appID: Keychain.read(MetaSettings.threadsIDItem) ?? "",
                                                        secret: Keychain.read(MetaSettings.threadsSecretItem) ?? "")
                let profile = try await auth.threadsProfile(token.token)
                upsertAccount(workspaceID, platform: "threads", id: token.userID ?? profile.id, name: profile.username, handle: "@\(profile.username)",
                              token: token.token, expiresIn: token.expiresIn, scopes: Meta.threadsScopes)
                metaMessage = "Connected @\(profile.username) on Threads."
            }
            try? context.save()
            log(metaMessage ?? "Connected \(pending.serviceName)", symbol: "link")
            await refreshLocalAccounts()
        } catch {
            metaMessage = "\(pending.serviceName) connection did not finish: \(error.message)"
        }
    }

    private func upsertAccount(_ workspaceID: UUID, platform: String, id: String, name: String, handle: String, token: String,
                               expiresIn: Int?, scopes: [String]) {
        let serverID = "mac-\(platform)-\(id)"
        let a = accounts.first { $0.serverID == serverID } ?? {
            let n = SocialAccount(serverID: serverID, workspaceID: workspaceID, platform: platform, name: name, status: "connected")
            context.insert(n)
            return n
        }()
        a.name = name; a.handle = handle; a.status = "connected"; a.source = "mac"; a.scopes = scopes
        a.tokenExpiresAt = expiresIn.map { Date.now.addingTimeInterval(Double($0)) }
        Keychain.write(a.tokenKey, token)
    }

    /// Threads tokens last 60 days; refresh them in their last ten days.
    func refreshThreadsTokens() async {
        for a in accounts where a.source == "mac" && a.platform == "threads" && a.status == "connected" {
            guard let expires = a.tokenExpiresAt, expires.timeIntervalSinceNow < 10 * 86_400, let token = Keychain.read(a.tokenKey) else { continue }
            if let fresh = try? await MetaAuth().refreshThreadsToken(token) {
                Keychain.write(a.tokenKey, fresh.token)
                a.tokenExpiresAt = fresh.expiresIn.map { Date.now.addingTimeInterval(Double($0)) }
            } else if expires < .now {
                a.status = "expired"
            }
        }
        try? context.save()
    }

    /// Puts a tiny file in the bucket and reads it back from the public address.
    func testPublicMedia() async {
        guard let host = PublicMediaSettings.host() else {
            metaMessage = "Fill in every storage field (both addresses must start with https://) and save the keys first."
            return
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "socialforge-storage-check.txt")
        try? Data("SocialForge storage check\n".utf8).write(to: file)
        do {
            let put = try await host.put(file: file, contentType: "text/plain")
            let (_, response) = try await URLSession.shared.data(from: put.url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            await host.delete(key: put.key)
            metaMessage = status == 200
                ? "Storage works: the test file uploaded and was readable at \(put.url.host() ?? "the public address")."
                : "The upload worked, but the public address answered \(status). Make the bucket public (R2: Settings › Public access) and check the public URL."
        } catch let e as PublishFailure {
            metaMessage = e.message
        } catch {
            metaMessage = "The public address could not be read: \(error.localizedDescription)"
        }
    }
}

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
        context.insert(a)
        try? context.save()
        boards[id] = MockPinterestTarget.boards
        log("Added the mock Pinterest account (testing only)", symbol: "person.badge.plus")
        return a
    }

    /// Boards for accounts this Mac holds tokens for.
    func refreshLocalAccounts() async {
        await refreshThreadsTokens()
        for a in accounts where a.source == "mac" && a.status == "connected" {
            guard let target = PublishRunner.target(for: a, storage: storage) else { continue }
            do {
                boards[a.serverID] = try await target.boards(accessToken: a.isMock ? nil : Keychain.read(a.tokenKey))
            } catch {
                if error.kind == .auth { a.status = "expired" }
                lastError = "\(a.name): \(error.message)"
            }
        }
        try? context.save()
    }

    /// Connect Pinterest with your own Pinterest app (its id and secret are in the Keychain).
    /// The browser returns to http://127.0.0.1:8085/pinterest/callback, which must be a
    /// redirect URI of that app.
    func connectPinterestOnMac() async {
        guard let workspaceID else { return }
        guard let clientID = Keychain.read("pinterest.clientID"), !clientID.isEmpty,
              let secret = Keychain.read("pinterest.clientSecret"), !secret.isEmpty else {
            lastError = "Add your Pinterest app's ID and secret in Settings > Publishing first."
            settingsTab = .publishing
            page = .settings
            return
        }
        let redirect = "http://127.0.0.1:\(OAuthLoopback.port)/pinterest/callback"
        let state = UUID().uuidString
        busyMessage = "Waiting for Pinterest in your browser…"
        defer { busyMessage = nil }
        do {
            let loopback = OAuthLoopback()
            let codeTask = Task { try await loopback.waitForCode(state: state) }
            NSWorkspace.shared.open(PinterestTarget.authorizeURL(clientID: clientID, redirectURI: redirect, state: state))
            let code = try await codeTask.value
            let target = PinterestTarget()
            let tokens = try await target.exchange(code: code, redirectURI: redirect, clientID: clientID, clientSecret: secret)
            let user = try await target.userAccount(accessToken: tokens.access)
            let id = "mac-pinterest-\(user.id)"
            let a = accounts.first { $0.serverID == id } ?? {
                let n = SocialAccount(serverID: id, workspaceID: workspaceID, platform: "pinterest", name: user.name, status: "connected")
                context.insert(n)
                return n
            }()
            a.name = user.name; a.handle = "@\(user.username)"; a.status = "connected"; a.source = "mac"
            a.scopes = tokens.scopes.isEmpty ? PinterestTarget.scopes : tokens.scopes
            a.tokenExpiresAt = tokens.expiresIn.map { Date.now.addingTimeInterval(Double($0)) }
            Keychain.write(a.tokenKey, tokens.access)
            if let r = tokens.refresh { Keychain.write(a.tokenKey + ".refresh", r) }
            try? context.save()
            log("Connected Pinterest as \(user.name)", symbol: "link")
            await refreshLocalAccounts()
        } catch let e as PublishFailure {
            lastError = e.message
        } catch {
            lastError = "Pinterest connection did not finish: \(error.localizedDescription)"
        }
    }

    // MARK: Background helper

    static let agentPlist = "com.socialforge.app.publisher.plist"

    var helperService: SMAppService { SMAppService.agent(plistName: Self.agentPlist) }

    var helperStatusText: String {
        switch helperService.status {
        case .enabled: "On: posts go out while SocialForge is closed and the Mac is awake."
        case .requiresApproval: "Waiting for your approval in System Settings > General > Login Items."
        // An agent that was never registered reports notFound.
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

/// Receives the OAuth redirect on 127.0.0.1 only, once, then stops listening.
nonisolated final class OAuthLoopback: @unchecked Sendable {
    static let port: UInt16 = 8085
    /// The name shown on the page the browser lands on.
    var service = "Pinterest"

    nonisolated enum LoopbackError: LocalizedError {
        case timeout, denied(String), badState, portBusy
        var errorDescription: String? {
            switch self {
            case .timeout: "No answer from the browser within 5 minutes."
            case .denied(let why): "Access was not granted: \(why)"
            case .badState: "The answer did not match this request."
            case .portBusy: "Port \(OAuthLoopback.port) is in use. Quit what is using it and try again."
            }
        }
    }

    func waitForCode(state: String) async throws -> String {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: params) else { throw LoopbackError.portBusy }
        let service = self.service
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let box = OnceBox(cont)
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                    let value = { (n: String) in items.first { $0.name == n }?.value }
                    let body: String
                    if let err = value("error") {
                        body = "\(service) did not grant access. You can close this tab."
                        box.resume(.failure(LoopbackError.denied(err)))
                    } else if value("state") != state {
                        body = "This answer does not match. Start again from SocialForge."
                        box.resume(.failure(LoopbackError.badState))
                    } else if let code = value("code") {
                        body = "\(service) is connected. You can close this tab and return to SocialForge."
                        box.resume(.success(code))
                    } else {
                        body = "Waiting for \(service)…"
                    }
                    let html = "<!doctype html><meta charset=utf-8><body style='font:16px -apple-system;margin:20vh auto;max-width:28em'><p>\(body)</p>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if box.done { listener.cancel() }
                }
            }
            listener.stateUpdateHandler = { s in
                if case .failed = s { box.resume(.failure(LoopbackError.portBusy)) }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                box.resume(.failure(LoopbackError.timeout))
                listener.cancel()
            }
        }
    }

    private nonisolated final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String, Error>?
        init(_ c: CheckedContinuation<String, Error>) { cont = c }
        var done: Bool { lock.withLock { cont == nil } }
        func resume(_ r: Result<String, Error>) {
            let c: CheckedContinuation<String, Error>? = lock.withLock { let c = cont; cont = nil; return c }
            c?.resume(with: r)
        }
    }
}

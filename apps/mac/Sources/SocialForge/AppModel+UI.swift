import Foundation
import SwiftData
import SwiftUI
import SocialForgeKit

enum ComfyState: Equatable {
    case unknown, checking, notConfigured
    case connected(String)
    case offline(String)

    var color: Color {
        switch self {
        case .connected: DS.green
        case .offline: DS.amber
        default: DS.text3
        }
    }

    var detail: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .notConfigured: "Not set up"
        case .connected(let d): d
        case .offline: "Offline"
        }
    }

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

extension AppModel {
    // MARK: Header text

    var pageSubtitle: String {
        let ws = workspace?.name ?? ""
        let pubs = workspacePublications
        switch page {
        case .home: return "\(ws) · \(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        case .calendar:
            let review = pubs.filter { $0.status == .needsReview }.count
            return "\(pubs.filter { $0.status != .canceled }.count) posts · \(review) awaiting approval"
        case .composer: return composer.subtitle
        case .media: return "\(workspaceAssetCount) items"
        case .studio: return studio.document.map { "\($0.name) · \($0.width) × \($0.height)" } ?? "Designs and brand templates"
        case .ai: return "Backgrounds, video, music, copy, and history"
        case .bulk: return "Drag images in, pick platforms, set a cadence"
        case .automations: return "Triggers and steps that prepare posts for your approval"
        case .campaigns: return "Goals, dates, UTM links, and the posts in each campaign"
        case .analytics: return "Publishing activity from this workspace"
        case .accounts: return "Connections, permissions, and capabilities"
        case .brandKits: return "Colors, fonts, logo, voice, and templates"
        case .settings: return "Publishing, AI providers, ComfyUI, appearance"
        }
    }

    var workspacePublications: [Publication] {
        guard let workspaceID else { return [] }
        return (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == workspaceID }))) ?? []
    }

    var workspaceAssetCount: Int {
        guard let workspaceID else { return 0 }
        return (try? context.fetchCount(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == workspaceID }))) ?? 0
    }

    var notificationCount: Int {
        workspacePublications.filter { $0.status == .failed || $0.status == .needsReview }.count
    }

    var brandKit: BrandKit? {
        guard let workspaceID else { return nil }
        return (try? context.fetch(FetchDescriptor<BrandKit>(predicate: #Predicate { $0.workspaceID == workspaceID })))?.first
    }

    // MARK: ComfyUI

    var comfyURLString: String { UserDefaults.standard.string(forKey: "comfy.url") ?? "http://127.0.0.1:8188" }
    var comfyIsLocal: Bool {
        let host = URL(string: comfyURLString)?.host() ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    var comfyClient: ComfyUIClient? {
        guard let url = URL(string: comfyURLString), ComfyUIClient.transportProblem(url) == nil else { return nil }
        return ComfyUIClient(baseURL: url, token: Keychain.read("comfy.token"))
    }

    func checkComfy() async {
        guard let client = comfyClient else { comfyState = .notConfigured; return }
        comfyState = .checking
        do {
            let stats = try await client.systemStats()
            let host = URL(string: comfyURLString)?.host() ?? ""
            let port = URL(string: comfyURLString)?.port.map { ":\($0)" } ?? ""
            comfyState = .connected("\(host)\(port) · \(stats.devices.first?.name ?? "ready")")
        } catch {
            comfyState = .offline(error.localizedDescription)
        }
    }

    // MARK: AI providers

    static func loadAIConfigs() -> [AIProviderID: AIProviderConfig] {
        var out = Dictionary(uniqueKeysWithValues: AIProviderID.allCases.map { ($0, AIProviderConfig.defaults(for: $0)) })
        if !Store.isOverridden, let d = UserDefaults.standard.data(forKey: "ai.configs"),
           let saved = try? JSONDecoder().decode([AIProviderConfig].self, from: d) {
            for c in saved { out[c.id] = c }
        }
        return out
    }

    func aiKey(_ id: AIProviderID) -> String? { Keychain.read("ai.key.\(id.rawValue)") }

    func setAIKey(_ id: AIProviderID, _ key: String) {
        Keychain.write("ai.key.\(id.rawValue)", key.trimmingCharacters(in: .whitespacesAndNewlines))
        aiRevision += 1
    }

    /// Configured means a key is stored (or none is needed); it does not mean the key works.
    func isConfigured(_ id: AIProviderID) -> Bool {
        let _ = aiRevision
        if id == .comfyui { return comfyState.isConnected }
        return !id.needsKey || !(aiKey(id) ?? "").isEmpty
    }

    var textProvider: (any TextProvider)? {
        guard isConfigured(textProviderID), let config = aiConfigs[textProviderID] else { return nil }
        return makeTextProvider(config, apiKey: aiKey(textProviderID))
    }
}

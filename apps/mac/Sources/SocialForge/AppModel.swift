import AppKit
import Foundation
import Observation
import Security
import SwiftData
import SocialForgeKit

/// App-wide state that menus, toolbars, and views share.
@Observable
final class AppModel {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    var page: AppPage = .home
    var showInspector = true
    var showSidebar = true
    var showCommandPanel = false
    var searchText = ""
    var comfyState: ComfyState = .unknown
    /// AI provider settings (no keys; keys live in the Keychain).
    var aiConfigs: [AIProviderID: AIProviderConfig] = AppModel.loadAIConfigs() {
        didSet { if !Store.isOverridden, let d = try? JSONEncoder().encode(Array(aiConfigs.values)) { UserDefaults.standard.set(d, forKey: "ai.configs") } }
    }
    var textProviderID: AIProviderID = AIProviderID(rawValue: UserDefaults.standard.string(forKey: "ai.text") ?? "") ?? .anthropic {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(textProviderID.rawValue, forKey: "ai.text") } }
    }
    var imageProviderID: AIProviderID = AIProviderID(rawValue: UserDefaults.standard.string(forKey: "ai.image") ?? "") ?? .comfyui {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(imageProviderID.rawValue, forKey: "ai.image") } }
    }
    var aiRevision = 0
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }

    /// The workspace everything is filtered to.
    var workspaceID: UUID? {
        didSet {
            if !Store.isOverridden { UserDefaults.standard.set(workspaceID?.uuidString, forKey: "workspace.current") }
            mediaSelection = []
            publicationSelection = []
        }
    }
    var mediaSelection: Set<UUID> = []
    var publicationSelection: Set<PersistentIdentifier> = []
    var brandKitSelection: UUID?
    var campaignSelection: UUID?
    var automationSelection: UUID?
    var showNewWorkspace = false

    // Long-running work, shown in the toolbar.
    var importProgress: (done: Int, total: Int)?
    var lastImportSummary: String?
    var variantProgress: (done: Int, total: Int)?
    var busyMessage: String?
    var lastError: String?

    // Publishing service.
    var backendURLString: String {
        didSet { UserDefaults.standard.set(backendURLString, forKey: "backend.url") }
    }
    var backendStatus: BackendStatus = .unknown
    var boards: [String: [API.Board]] = [:]
    var lastSync: Date?

    enum BackendStatus: Equatable {
        case unknown, checking
        case up(version: String)
        case down(String)
    }

    let bulk = BulkSession()
    let studio = StudioModel()
    let composer = ComposerModel()
    let aiStudio = AIStudioModel()
    /// Bumped when the publish mode or helper changes, so views re-read them.
    var modeRevision = 0
    /// Saved in UserDefaults, except in test and snapshot runs.
    var publishModeRaw: String = Store.isOverridden ? "mac" : (UserDefaults.standard.string(forKey: "publish.mode") ?? "mac") {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(publishModeRaw, forKey: "publish.mode") } }
    }
    @ObservationIgnored lazy var runner = PublishRunner(container: container, storage: storage)

    init(container: ModelContainer) {
        self.container = container
        backendURLString = UserDefaults.standard.string(forKey: "backend.url") ?? "http://127.0.0.1:8787"
        if let saved = UserDefaults.standard.string(forKey: "workspace.current"), !Store.isOverridden {
            workspaceID = UUID(uuidString: saved)
        }
        ensureWorkspace()
    }

    // MARK: - Workspaces

    var workspaces: [Workspace] {
        (try? context.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    var workspace: Workspace? { workspaces.first { $0.uuid == workspaceID } }

    /// There is always one workspace to work in.
    func ensureWorkspace() {
        let all = workspaces
        if all.isEmpty {
            let w = Workspace(name: "My Brand")
            context.insert(w)
            try? context.save()
            workspaceID = w.uuid
        } else if workspace == nil {
            workspaceID = all[0].uuid
        }
    }

    @discardableResult
    func createWorkspace(name: String, colorHex: Int) -> Workspace {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = Workspace(name: clean.isEmpty ? "New Workspace" : clean, colorHex: colorHex)
        context.insert(w)
        try? context.save()
        workspaceID = w.uuid
        log("Created workspace \(w.name)", symbol: "plus.circle")
        return w
    }

    func log(_ text: String, symbol: String) {
        guard let workspaceID else { return }
        context.insert(ActivityEntry(workspaceID: workspaceID, text: text, symbol: symbol))
        try? context.save()
    }

    // MARK: - Storage

    var storage: ManagedStorage { Self.storage(for: Store.url) }

    /// Library files sit next to the store: Application Support/SocialForge/Library, or <store>-library for test stores.
    nonisolated static func storage(for storeURL: URL) -> ManagedStorage {
        if !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty {
            return ManagedStorage(root: storeURL.deletingLastPathComponent().appending(path: storeURL.lastPathComponent + "-library", directoryHint: .isDirectory))
        }
        return ManagedStorage(root: URL.applicationSupportDirectory.appending(path: "SocialForge/Library", directoryHint: .isDirectory))
    }

    func assets(_ ids: some Sequence<UUID>) -> [MediaAsset] {
        let set = Set(ids)
        let all = (try? context.fetch(FetchDescriptor<MediaAsset>())) ?? []
        return all.filter { set.contains($0.uuid) }
    }

    func asset(_ id: UUID?) -> MediaAsset? {
        guard let id else { return nil }
        var d = FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.uuid == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func variants(of assetID: UUID) -> [MediaVariant] {
        (try? context.fetch(FetchDescriptor<MediaVariant>(predicate: #Predicate { $0.assetID == assetID }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    // MARK: - Import

    /// Imports files and folders into the current workspace. Returns the new assets.
    @discardableResult
    func importMedia(_ urls: [URL]) async -> [MediaAsset] {
        guard let workspaceID else { return [] }
        let scan = MediaScanner.scan(urls)
        let csvs = urls.flatMap { url -> [URL] in
            if url.pathExtension.lowercased() == "csv" { return [url] }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "csv" }
        }
        let wsAssets = (try? context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == workspaceID }))) ?? []
        let known = Set(wsAssets.map(\.sha256))
        importProgress = (0, scan.files.count)
        let storage = self.storage
        let outcome = await MediaImporter.run(scan.files, storage: storage, known: known) { done, total in
            Task { @MainActor in self.importProgress = (done, total) }
        }
        var created: [MediaAsset] = []
        for item in outcome.imported {
            let a = MediaAsset(workspaceID: workspaceID, filename: item.source.lastPathComponent, storedPath: item.stored.path,
                               sourcePath: item.source.path, sha256: item.hash, bytes: item.bytes)
            a.kind = item.kind.rawValue
            if let info = item.info {
                a.width = info.width; a.height = info.height; a.format = info.format; a.hasAlpha = info.hasAlpha
            }
            context.insert(a)
            created.append(a)
        }
        try? context.save()
        importProgress = nil
        var parts = ["Imported \(outcome.imported.count)"]
        if !outcome.duplicates.isEmpty { parts.append("\(outcome.duplicates.count) duplicates skipped") }
        let failed = outcome.failed.count + scan.skipped.count
        if failed > 0 { parts.append("\(failed) not imported") }
        lastImportSummary = parts.joined(separator: " · ")
        var reasons = (scan.skipped + outcome.failed).prefix(5).map { "\($0.url.lastPathComponent): \($0.reason)" }
        if failed > 5 { reasons.append("…and \(failed - 5) more") }
        if !reasons.isEmpty { lastImportSummary! += "\n" + reasons.joined(separator: "\n") }
        if !created.isEmpty { log("Imported \(created.count) images", symbol: "photo.on.rectangle") }
        mediaSelection = Set(created.map(\.uuid))
        if let csv = csvs.first { bulk.loadCSV(csv) }
        return created
    }

    // MARK: - Variants

    /// Makes one variant per asset off the main actor, at most four at a time.
    @discardableResult
    func makeVariants(_ assets: [MediaAsset], preset: ExportPreset) async -> [MediaVariant] {
        let jobs = assets.map { (id: $0.uuid, src: $0.storedURL, focus: CGPoint(x: 0.5, y: 0.5)) }
        let out = storage.variants
        variantProgress = (0, jobs.count)
        var made: [MediaVariant] = []
        var failures: [String] = []
        await withTaskGroup(of: (UUID, Result<TransformResult, ImageTransformer.TransformError>).self) { group in
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    let dest = out.appending(path: "\(job.id.uuidString)/\(preset.id).\(preset.format.fileExtension)")
                    do { return (job.id, .success(try ImageTransformer.apply(preset, to: job.src, output: dest, focus: job.focus))) }
                    catch { return (job.id, .failure(error as? ImageTransformer.TransformError ?? .cannotWrite)) }
                }
            }
            for _ in 0..<4 { add() }
            var done = 0
            while let (id, result) = await group.next() {
                done += 1
                variantProgress = (done, jobs.count)
                switch result {
                case .success(let r):
                    // Replace an older variant from the same preset.
                    for old in variants(of: id) where old.presetID == preset.id { context.delete(old) }
                    let v = MediaVariant(assetID: id, preset: preset, result: r)
                    context.insert(v)
                    made.append(v)
                case .failure:
                    failures.append(asset(id)?.filename ?? id.uuidString)
                }
                add()
            }
        }
        try? context.save()
        variantProgress = nil
        if !failures.isEmpty { lastError = "Could not make \(preset.name) for: \(failures.joined(separator: ", "))" }
        if !made.isEmpty { log("Made \(made.count) \(preset.name) variants", symbol: "aspectratio") }
        return made
    }

    // MARK: - Publishing service

    var client: BackendClient? {
        guard let url = URL(string: backendURLString), url.scheme != nil else { return nil }
        return BackendClient(baseURL: url, token: Keychain.read("backend.token"))
    }

    var token: String {
        get { Keychain.read("backend.token") ?? "" }
        set { Keychain.write("backend.token", newValue) }
    }

    func checkBackend() async {
        guard let client else { backendStatus = .down("Enter an address like http://127.0.0.1:8787."); return }
        backendStatus = .checking
        do {
            let h = try await client.health()
            let v = try await client.version()
            backendStatus = h.status == "ok" ? .up(version: v.version + (v.commit.map { " (\($0.prefix(7)))" } ?? "")) : .down("Health is \(h.status)")
        } catch {
            backendStatus = .down(error.localizedDescription)
        }
    }

    var accounts: [SocialAccount] {
        guard let workspaceID else { return [] }
        return (try? context.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate { $0.workspaceID == workspaceID }, sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    func refreshAccounts() async {
        await refreshLocalAccounts()
        guard publishMode == .service, let client, let workspaceID else { return }
        do {
            let remote = try await client.accounts()
            let local = accounts
            for r in remote {
                let a = local.first { $0.serverID == r.id } ?? {
                    let n = SocialAccount(serverID: r.id, workspaceID: workspaceID, platform: r.platform, name: r.name, status: r.status)
                    n.source = "service"
                    context.insert(n)
                    return n
                }()
                a.name = r.name; a.handle = r.handle ?? ""; a.status = r.status; a.scopes = r.scopes
                a.tokenExpiresAt = r.tokenExpiresAt; a.lastPublishedAt = r.lastPublishedAt; a.isMock = r.isMock; a.refreshedAt = .now
                if r.status == "connected", let b = try? await client.boards(account: r.id) { boards[r.id] = b }
            }
            for gone in local where gone.source == "service" && !remote.contains(where: { $0.id == gone.serverID }) { context.delete(gone) }
            try? context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func connect(platform: String) async {
        guard let client else { lastError = BackendClient.ClientError.notConfigured.localizedDescription; return }
        do { NSWorkspace.shared.open(try await client.connect(platform: platform)) } catch { lastError = error.localizedDescription }
    }

    /// Sends approved posts to the service. Each post's image (variant if any)
    /// is uploaded by hash first. Posts the service accepted become Scheduled.
    func activate(_ pubs: [Publication]) async -> (sent: Int, failed: [String]) {
        if publishMode == .mac {
            var n = 0
            for p in pubs where p.status == .approved {
                p.status = .scheduled
                p.nextAttemptAt = nil
                n += 1
            }
            try? context.save()
            if n > 0 { log("Scheduled \(n) posts to publish from this Mac", symbol: "clock.badge.checkmark") }
            runner.kick()
            return (n, [])
        }
        guard let client else { return (0, [BackendClient.ClientError.notConfigured.localizedDescription]) }
        var failed: [String] = []
        var batch: [API.NewPublication] = []
        var byClient: [String: Publication] = [:]
        busyMessage = "Uploading media…"
        for p in pubs where p.status == .approved {
            var mediaID: String?
            if let a = asset(p.assetID) {
                let v = variants(of: a.uuid).first { $0.uuid == p.variantID }
                let file = v?.url ?? a.storedURL
                let type = (v?.format ?? a.format) == "png" ? "image/png" : "image/jpeg"
                do {
                    let hash = try ContentHash.sha256(of: file)
                    mediaID = try await client.upload(file: file, sha256: hash, contentType: type).mediaId
                } catch {
                    failed.append("\(p.title.isEmpty ? a.filename : p.title): \(error.localizedDescription)")
                    continue
                }
            }
            let n = API.NewPublication(clientId: p.uuid.uuidString.lowercased(), idempotencyKey: p.idempotencyKey, accountId: p.accountID,
                                       platform: p.platform, scheduledAt: p.scheduledAt, timeZone: p.timeZoneID, mediaId: mediaID,
                                       payload: .init(title: p.title, description: p.desc, link: p.link, altText: p.altText, boardId: p.boardID))
            batch.append(n)
            byClient[n.clientId] = p
        }
        busyMessage = "Scheduling \(batch.count) posts…"
        defer { busyMessage = nil }
        guard !batch.isEmpty else { return (0, failed) }
        do {
            let created = try await client.create(batch)
            for c in created {
                guard let p = byClient[c.clientId] else { continue }
                p.serverID = c.id
                p.status = PublicationStatus(server: c.status)
            }
            try? context.save()
            log("Scheduled \(created.count) posts with the publishing service", symbol: "clock.badge.checkmark")
            return (created.count, failed)
        } catch {
            failed.append(error.localizedDescription)
            return (0, failed)
        }
    }

    /// Pulls results for every post the service holds (scenario D).
    func sync() async {
        guard publishMode == .service, let client, let workspaceID else { return }
        do {
            let result = try await client.publications(updatedSince: nil)
            let local = (try? context.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.workspaceID == workspaceID }))) ?? []
            let states = local.map { LocalPublicationState(clientId: $0.uuid.uuidString.lowercased(), serverId: $0.serverID, status: $0.statusRaw,
                                                           publishedUrl: $0.publishedURL, lastError: $0.lastError, attempts: $0.attempts) }
            let (merged, changed) = SyncMerge.merge(local: states, server: result.publications)
            let byClient = Dictionary(local.map { ($0.uuid.uuidString.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            for m in merged {
                guard let p = byClient[m.clientId], p.statusRaw != m.status || p.publishedURL != m.publishedUrl || p.attempts != m.attempts else { continue }
                let was = p.status
                p.serverID = m.serverId; p.statusRaw = m.status; p.publishedURL = m.publishedUrl; p.lastError = m.lastError
                p.attempts = m.attempts; p.updatedAt = .now
                if was != p.status, p.status == .published { log("Published “\(p.title)”", symbol: "checkmark.seal") }
                if was != p.status, p.status == .failed { log("Failed “\(p.title)”: \(p.lastError ?? "unknown error")", symbol: "exclamationmark.triangle") }
            }
            if changed > 0 { try? context.save() }
            lastSync = .now
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelOnServer(_ p: Publication) async {
        guard let client, let id = p.serverID else {
            p.status = .canceled
            try? context.save()
            return
        }
        do {
            let r = try await client.cancel(publication: id)
            p.status = PublicationStatus(server: r.status)
            try? context.save()
        } catch { lastError = error.localizedDescription }
    }
}

/// Secrets in the login Keychain, never in UserDefaults or files.
enum Keychain {
    static let service = "com.socialforge.app"

    static func read(_ key: String) -> String? {
        if Store.isOverridden { return key == "backend.token" ? ProcessInfo.processInfo.environment["APP_BACKEND_TOKEN"] : nil }
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        if Store.isOverridden { return }
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

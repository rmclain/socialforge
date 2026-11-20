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
    /// Media waiting for the Library's Delete confirmation (context menu, selection bar, or Edit › Delete).
    var mediaPendingDelete: [UUID] = []
    var publicationSelection: Set<PersistentIdentifier> = []
    var brandKitSelection: UUID?
    var campaignSelection: UUID?
    var automationSelection: UUID?
    var showNewWorkspace = false
    /// First launch: the Welcome sheet that sets up the first brand, then opens Accounts.
    var showWelcome = false
    /// The collection the Media Library shows; nil for all media. Other pages set it to point there.
    var mediaCollection: String?

    // Long-running work, shown in the toolbar.
    var importProgress: (done: Int, total: Int)?
    var lastImportSummary: String?
    var variantProgress: (done: Int, total: Int)?
    var busyMessage: String?
    var lastError: String?
    /// A Meta or Threads sign-in waiting for the address the browser landed on.
    var pendingOAuth: PendingOAuth?
    var metaMessage: String?

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
    @ObservationIgnored lazy var runner = PublishRunner(container: container, storage: libraryStorage)

    init(container: ModelContainer) {
        self.container = container
        backendURLString = UserDefaults.standard.string(forKey: "backend.url") ?? "http://127.0.0.1:8787"
        if let saved = UserDefaults.standard.string(forKey: "workspace.current"), !Store.isOverridden {
            workspaceID = UUID(uuidString: saved)
        }
        ensureWorkspace()
        // Tests and snapshots use a /tmp store and never see it, unless APP_WELCOME=1 asks for it.
        if !Store.isOverridden || ProcessInfo.processInfo.environment["APP_WELCOME"] == "1" {
            showWelcome = needsBrandSetup
        }
    }

    // MARK: - First brand

    static let brandSetupDoneKey = "onboarding.brandSetupDone"

    /// A new library: one workspace, no brand kit, nothing imported or scheduled yet.
    /// Someone who already has work in SocialForge never sees the Welcome sheet.
    var needsBrandSetup: Bool {
        if !Store.isOverridden, UserDefaults.standard.bool(forKey: Self.brandSetupDoneKey) { return false }
        guard workspaces.count == 1 else { return false }
        let kits = (try? context.fetchCount(FetchDescriptor<BrandKit>())) ?? 0
        let assets = (try? context.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0
        let posts = (try? context.fetchCount(FetchDescriptor<Publication>())) ?? 0
        return kits == 0 && assets == 0 && posts == 0
    }

    /// The Welcome sheet's Create: names the workspace and makes its brand kit, then opens Accounts.
    @discardableResult
    func completeBrandSetup(name: String, colorHex: Int, voice: String, hashtags: [String], logo: URL?, folder: URL? = nil) async -> BrandKit? {
        guard let ws = workspace else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { ws.name = clean }
        ws.colorHex = colorHex
        let kit = brandKit ?? {
            let k = BrandKit(workspaceID: ws.uuid, name: ws.name)
            context.insert(k)
            return k
        }()
        kit.name = ws.name
        kit.colors = [0x2A211C, 0xF4EFE8, colorHex, 0x7A5C48, 0xC9B8A6]
        kit.headlineFont = FontRegistry.hasInstrumentSerif ? "Instrument Serif" : "Baskerville"
        kit.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        kit.hashtags = hashtags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty }
        // The folder first, so the logo is saved there too.
        if let folder { setBrandFolder(folder, for: kit) }
        if let logo {
            let selection = mediaSelection
            let added = await importMedia([logo])
            mediaSelection = selection
            if let a = added.first {
                a.collection = "Brand"
                kit.logoPath = a.storedPath
            }
        }
        try? context.save()
        log("Set up the brand \(ws.name)", symbol: "paintpalette")
        finishBrandSetup()
        return kit
    }

    /// The Welcome sheet's Import Brand Kit: the workspace takes the imported kit's name and accent.
    func completeBrandImport(_ kit: BrandKit) {
        if let ws = workspace {
            let clean = kit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { ws.name = clean }
            if kit.colors.count > 2 { ws.colorHex = kit.colors[2] }
        }
        try? context.save()
        log("Imported the brand \(kit.name)", symbol: "paintpalette")
        finishBrandSetup()
    }

    /// Create, Import, or Skip: the sheet does not come back, and Accounts opens,
    /// the next step: connecting where posts go.
    func finishBrandSetup() {
        if !Store.isOverridden { UserDefaults.standard.set(true, forKey: Self.brandSetupDoneKey) }
        showWelcome = false
        page = .accounts
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

    /// Where new media for the current brand goes: the brand kit's folder when it has
    /// one (Brand Kits > Save files to), else the library next to the store.
    /// Files already in the library stay where they are.
    var storage: ManagedStorage { workspaceID.map(storage(forWorkspace:)) ?? libraryStorage }

    /// The same, for any brand (agent requests can name a brand that is not the one open).
    func storage(forWorkspace id: UUID) -> ManagedStorage {
        let kit = (try? context.fetch(FetchDescriptor<BrandKit>(predicate: #Predicate { $0.workspaceID == id })))?.first
        if let path = kit?.folderPath, !path.isEmpty {
            return ManagedStorage(root: URL(fileURLWithPath: path, isDirectory: true))
        }
        return libraryStorage
    }

    /// The app's own library: the publisher's lock and the mock account live here, whatever the brand folder.
    var libraryStorage: ManagedStorage { Self.storage(for: Store.url) }

    func aiJobOutputs(_ jobID: UUID) -> [UUID] {
        ((try? context.fetch(FetchDescriptor<AIJob>()))?.first { $0.uuid == jobID })?.outputAssetIDs ?? []
    }

    /// Deletes generated or imported media: the library records, their variants, and,
    /// with `trashFiles`, the library's copy of each file (moved to the Trash, never
    /// the original the person imported from). AI jobs forget the deleted outputs.
    func deleteMedia(_ targets: [MediaAsset], trashFiles: Bool) {
        let ids = Set(targets.map(\.uuid))
        // Two records can share one stored copy (the same file imported twice): keep it while another still uses it.
        let kept = Set(((try? context.fetch(FetchDescriptor<MediaAsset>())) ?? []).filter { !ids.contains($0.uuid) }.map(\.storedPath))
        for t in targets {
            if trashFiles, t.storedPath.contains("/Originals/"), t.storedPath != t.sourcePath, !kept.contains(t.storedPath) {
                let file = t.storedURL
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                // Its content-hash folder, once empty.
                let dir = file.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
            }
            for v in variants(of: t.uuid) { context.delete(v) }
            context.delete(t)
        }
        for job in (try? context.fetch(FetchDescriptor<AIJob>())) ?? [] where job.outputAssetIDs.contains(where: ids.contains) {
            job.outputAssetIDs.removeAll { ids.contains($0) }
        }
        mediaSelection.subtract(ids)
        try? context.save()
        log(targets.count == 1 ? "Deleted \(targets[0].filename)" : "Deleted \(targets.count) files", symbol: "trash")
    }

    /// Where media is still used, so Delete can warn first: posts not yet sent and Studio designs or templates that show the file.
    func mediaUsage(_ targets: [MediaAsset]) -> (posts: Int, designs: Int) {
        let ids = Set(targets.map(\.uuid))
        let open: Set<PublicationStatus> = [.draft, .needsReview, .approved, .scheduled, .preparing, .publishing, .failed, .paused]
        let posts = ((try? context.fetch(FetchDescriptor<Publication>())) ?? [])
            .filter { $0.assetID.map(ids.contains) == true && open.contains($0.status) }.count
        // Designs keep image paths in their JSON, where "/" may be written as "\/".
        let needles = targets.flatMap { [$0.storedPath, $0.storedPath.replacingOccurrences(of: "/", with: "\\/")] }
        func uses(_ json: Data) -> Bool {
            guard let text = String(data: json, encoding: .utf8) else { return false }
            return needles.contains { text.contains($0) }
        }
        let designs = ((try? context.fetch(FetchDescriptor<Design>())) ?? []).filter { uses($0.json) }.count
            + ((try? context.fetch(FetchDescriptor<CreativeTemplate>())) ?? []).filter { uses($0.json) }.count
        return (posts, designs)
    }

    /// The folder a brand would get under Documents: ~/Documents/<brand name>.
    static func suggestedFolder(for brandName: String) -> URL {
        let clean = brandName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return URL.documentsDirectory.appending(path: clean.isEmpty ? "SocialForge" : clean, directoryHint: .isDirectory)
    }

    /// Sets the brand's folder and makes sure it exists; nil goes back to the app's library.
    @discardableResult
    func setBrandFolder(_ url: URL?, for kit: BrandKit) -> Bool {
        guard let url else { kit.folderPath = ""; try? context.save(); return true }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            lastError = "SocialForge could not use \(url.path): \(error.localizedDescription)"
            return false
        }
        kit.folderPath = url.standardizedFileURL.path
        try? context.save()
        log("\(kit.name) now saves files to \(url.path)", symbol: "folder")
        return true
    }

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

    /// Puts media in a collection, or takes it out with an empty name.
    ///
    /// Studio exports are filed in a "Branded…" collection and tagged "branded",
    /// and the Library's Branded filter goes by the tag. Taking one out of its
    /// Branded collection drops the tag too, or it stayed on screen under Branded
    /// and removing looked like it did nothing.
    func setCollection(_ name: String, for targets: [MediaAsset]) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        for a in targets {
            if clean.isEmpty, a.collection.hasPrefix("Branded") { a.tags.removeAll { $0 == "branded" } }
            a.collection = clean
        }
        try? context.save()
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

    /// Imports files and folders into the current workspace, or into `target`. Returns the new assets.
    @discardableResult
    func importMedia(_ urls: [URL], into target: UUID? = nil) async -> [MediaAsset] {
        guard let workspaceID = target ?? self.workspaceID else { return [] }
        let isCurrent = workspaceID == self.workspaceID
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
        let storage = storage(forWorkspace: workspaceID)
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
            if let av = item.av {
                a.width = av.width; a.height = av.height; a.format = av.format; a.duration = av.duration
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
        if !created.isEmpty { log("Imported \(created.count) \(created.count == 1 ? "file" : "files")", symbol: "photo.on.rectangle") }
        guard isCurrent else { return created }
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

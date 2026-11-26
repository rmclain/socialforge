import AppKit
import Foundation
import SwiftData
import SocialForgeKit

/// Publishes due posts from this Mac. One runner at a time across the app and
/// the launch agent: whoever holds the lock file publishes. The app takes the
/// lock for as long as it is open; the agent takes it only for one pass.
@MainActor
final class PublishRunner {
    let container: ModelContainer
    let storage: ManagedStorage
    let policy: RetryPolicy
    let tokenManager = TokenLifecycleManager()
    private(set) var lastPass: Date?
    private(set) var lastError: String?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lock: RunnerLock?
    private var running = false
    private var inFlightTask: Task<Void, Never>?
    var onLog: (String) -> Void = { _ in }

    init(container: ModelContainer, storage: ManagedStorage, policy: RetryPolicy = RetryPolicy(jitterFraction: 0.15)) {
        self.container = container
        self.storage = storage
        self.policy = policy
    }

    isolated deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Where the mock provider keeps its "Pins": next to the store, shared by app and agent.
    static func mockFile(storage: ManagedStorage) -> URL { storage.root.appending(path: "MockPinterest/pins.json") }

    static var missedPostPolicy: MissedPostPolicy {
        let raw = UserDefaults.standard.string(forKey: "publish.missedPolicy") ?? ""
        return MissedPostPolicy(rawValue: raw) ?? .publishWhenAvailable
    }

    static var missedPostWindowSeconds: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: "publish.missedWindowMinutes")
        return TimeInterval((minutes > 0 ? minutes : 60) * 60)
    }

    static func target(for account: SocialAccount?, storage: ManagedStorage) -> (any PublishTarget)? {
        guard let account else { return nil }
        if account.isMock { return MockPinterestTarget(file: mockFile(storage: storage)) }
        switch account.platform {
        case "pinterest":
            let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:))
                ?? URL(string: "https://api.pinterest.com")!
            return PinterestTarget(apiBase: base)
        case "facebook":
            return FacebookPageTarget()
        case "instagram":
            let graphBase = account.authMode == "instagram_login"
                ? URL(string: "https://graph.instagram.com/\(Meta.graphVersion)")!
                : URL(string: "https://graph.facebook.com/\(Meta.graphVersion)")!
            return InstagramTarget(graph: graphBase, media: PublicMediaSettings.host())
        case "threads":
            return ThreadsTarget(media: PublicMediaSettings.host())
        case "linkedin":
            return LinkedInTarget()
        case "x":
            return XTarget()
        case "tiktok":
            return TikTokTarget()
        case "youtube":
            return YouTubeTarget()
        default:
            return nil
        }
    }

    /// The app: hold the lock while open, publish every 30 seconds and on wake.
    func startInApp() {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        kick()
    }

    func kick() {
        guard !running else { return }
        if lock == nil { lock = RunnerLock.acquire(at: lockURL) }
        guard lock != nil else { return }  // the agent is mid-pass; try again on the next tick
        inFlightTask = Task { [weak self] in
            _ = await self?.passNow()
        }
    }

    var lockURL: URL { storage.root.appending(path: "publisher.lock") }

    /// Lets the launch agent take over (self-test only; the app normally keeps the lock while open).
    func releaseLock() { lock = nil }
    var holdsLock: Bool { lock != nil }

    /// Recovers publications left stuck in active publishing states after a crash or power loss.
    func recoverInterrupted(in ctx: ModelContext, now: Date = .now) {
        let activeRaw = [
            PublicationStatus.preparing.rawValue,
            PublicationStatus.uploading.rawValue,
            PublicationStatus.awaitingProcessing.rawValue,
            PublicationStatus.publishing.rawValue,
            PublicationStatus.verifying.rawValue,
        ]
        let all = (try? ctx.fetch(FetchDescriptor<Publication>())) ?? []
        let stuck = all.filter { p in
            p.serverID == nil && p.publishOwner == .mac && activeRaw.contains(p.statusRaw)
                && now.timeIntervalSince(p.updatedAt) > 300
        }
        guard !stuck.isEmpty else { return }
        for p in stuck {
            let pubID = p.uuid
            let attempts = (try? ctx.fetch(FetchDescriptor<PublishAttempt>(predicate: #Predicate { $0.publicationID == pubID }))) ?? []
            for a in attempts where a.finishedAt == nil {
                a.finishedAt = now
                a.outcome = "uncertain"
                a.error = "Interrupted before confirmation (app or Mac restarted)."
            }
            p.status = .outcomeUnknown
            p.lastError = "Publishing was interrupted before confirmation. Reconcile or inspect the platform before retrying so a duplicate is not posted."
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Interrupted publish “\(p.title)” moved to Outcome Unknown", symbol: "questionmark.diamond.fill", category: "publishing"))
        }
        save(ctx, context: "recoverInterrupted")
    }

    /// One pass: every Mac-owned scheduled/retryScheduled post that is due.
    @discardableResult
    func passNow(now: Date = .now) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false; lastPass = .now }
        // A fresh context reads what the other process wrote.
        let ctx = ModelContext(container)
        recoverInterrupted(in: ctx, now: now)

        let scheduled = PublicationStatus.scheduled.rawValue
        let retryScheduled = PublicationStatus.retryScheduled.rawValue
        let all = (try? ctx.fetch(FetchDescriptor<Publication>(
            predicate: #Predicate { ($0.statusRaw == scheduled || $0.statusRaw == retryScheduled) && $0.scheduledAt <= now && $0.serverID == nil },
            sortBy: [SortDescriptor(\.scheduledAt)]))) ?? []
        let due = all.filter { $0.publishOwner == .mac && ($0.nextAttemptAt ?? .distantPast) <= now }

        var done = 0
        for p in due {
            if Task.isCancelled { break }
            // Handle missed-post policy when overdue beyond the configured window on first try.
            let lateness = now.timeIntervalSince(p.scheduledAt)
            if p.attempts == 0 && lateness > Self.missedPostWindowSeconds {
                switch Self.missedPostPolicy {
                case .publishWhenAvailable:
                    break
                case .skipForReview:
                    p.status = .needsReview
                    p.lastError = "Missed scheduled time by \(Int(lateness / 60)) min while Mac was unavailable; returned to Needs Review."
                    ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Skipped overdue post “\(p.title)” for review", symbol: "clock.badge.exclamationmark", category: "publishing"))
                    save(ctx, context: "missedPostSkip")
                    continue
                case .rescheduleInWindow:
                    let nextSlot = now.addingTimeInterval(300)
                    p.scheduledAt = nextSlot
                    p.lastError = "Rescheduled after Mac wake."
                    ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Rescheduled overdue post “\(p.title)”", symbol: "calendar.badge.clock", category: "publishing"))
                    save(ctx, context: "missedPostReschedule")
                    continue
                }
            }
            await publish(p.uuid, now: now)
            done += 1
        }
        return done
    }

    /// Refreshes an account's access token proactively when expiring soon, deduplicated across callers.
    func ensureFreshToken(for account: SocialAccount, ctx: ModelContext) async -> String? {
        if account.isMock { return nil }
        let existing = Keychain.read(account.tokenKey)
        let leeway: TimeInterval = account.platform == "threads" || account.platform == "instagram" ? 10 * 86_400 : 10 * 60
        guard TokenLifecycleManager.shouldRefresh(expiresAt: account.tokenExpiresAt, leeway: leeway) else {
            return existing
        }
        let tokenKey = account.tokenKey
        let refreshKey = account.refreshTokenKey
        let platform = account.platform
        let authMode = account.authMode
        let refreshSecret = Keychain.read(refreshKey)

        do {
            let refreshed = try await tokenManager.refresh(credentialKey: tokenKey, operation: {
                switch platform {
                case "pinterest":
                    guard let rt = refreshSecret, !rt.isEmpty,
                          let clientID = UserDefaults.standard.string(forKey: "pinterest.clientID"), !clientID.isEmpty,
                          let secret = Keychain.read("pinterest.clientSecret"), !secret.isEmpty else {
                        throw PublishFailure(.auth, "Pinterest refresh credentials unavailable.")
                    }
                    let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:))
                        ?? URL(string: "https://api.pinterest.com")!
                    let t = try await PinterestTarget(apiBase: base).refreshToken(rt, clientID: clientID, clientSecret: secret)
                    return RefreshedToken(accessToken: t.access, refreshToken: t.refresh,
                                          expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }, scopes: t.scopes)
                case "threads":
                    guard let current = existing, !current.isEmpty else { throw PublishFailure(.auth, "Missing Threads token") }
                    let t = try await MetaAuth().refreshThreadsToken(current)
                    return RefreshedToken(accessToken: t.token, expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) })
                case "instagram" where authMode == "instagram_login":
                    guard let current = existing, !current.isEmpty else { throw PublishFailure(.auth, "Missing Instagram token") }
                    let t = try await MetaAuth().refreshInstagramLoginToken(current)
                    return RefreshedToken(accessToken: t.token, expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) })
                case "linkedin":
                    guard let rt = refreshSecret, !rt.isEmpty,
                          let cid = UserDefaults.standard.string(forKey: "linkedin.clientID"),
                          let cs = Keychain.read("linkedin.clientSecret") else {
                        throw PublishFailure(.auth, "LinkedIn refresh credentials unavailable.")
                    }
                    let t = try await LinkedInAuth().refresh(rt, clientID: cid, clientSecret: cs)
                    return RefreshedToken(accessToken: t.accessToken, refreshToken: t.refreshToken,
                                          expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }, scopes: t.scopes)
                case "x":
                    guard let rt = refreshSecret, !rt.isEmpty,
                          let cid = UserDefaults.standard.string(forKey: "x.clientID") else {
                        throw PublishFailure(.auth, "X refresh credentials unavailable.")
                    }
                    let t = try await XAuth().refresh(rt, clientID: cid, clientSecret: Keychain.read("x.clientSecret"))
                    return RefreshedToken(accessToken: t.accessToken, refreshToken: t.refreshToken,
                                          expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }, scopes: t.scopes)
                case "tiktok":
                    guard let rt = refreshSecret, !rt.isEmpty,
                          let ck = UserDefaults.standard.string(forKey: "tiktok.clientKey"),
                          let cs = Keychain.read("tiktok.clientSecret") else {
                        throw PublishFailure(.auth, "TikTok refresh credentials unavailable.")
                    }
                    let t = try await TikTokAuth().refresh(rt, clientKey: ck, clientSecret: cs)
                    return RefreshedToken(accessToken: t.accessToken, refreshToken: t.refreshToken,
                                          expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }, scopes: t.scopes)
                case "youtube":
                    guard let rt = refreshSecret, !rt.isEmpty,
                          let cid = UserDefaults.standard.string(forKey: "youtube.clientID") else {
                        throw PublishFailure(.auth, "YouTube refresh credentials unavailable.")
                    }
                    let t = try await YouTubeAuth().refresh(rt, clientID: cid, clientSecret: Keychain.read("youtube.clientSecret"))
                    return RefreshedToken(accessToken: t.accessToken, refreshToken: t.refreshToken,
                                          expiresAt: t.expiresIn.map { Date.now.addingTimeInterval(TimeInterval($0)) }, scopes: t.scopes)
                default:
                    throw PublishFailure(.permanent, "No refresh flow for \(platform)")
                }
            }, persist: { token in
                try Keychain.writeStrict(token.accessToken, for: tokenKey)
                if let rt = token.refreshToken, !rt.isEmpty {
                    try Keychain.writeStrict(rt, for: refreshKey)
                }
            })
            account.tokenExpiresAt = refreshed.expiresAt
            account.lastVerifiedAt = .now
            account.lastError = nil
            if let scopes = refreshed.scopes, !scopes.isEmpty { account.scopes = scopes }
            save(ctx, context: "tokenRefresh")
            return refreshed.accessToken
        } catch {
            // If the existing token hasn't expired yet, allow using it while logging the refresh failure.
            if let exp = account.tokenExpiresAt, exp > .now { return existing }
            account.lastError = DiagnosticRedactor.sanitize(error.localizedDescription)
            return existing
        }
    }

    private func publish(_ pubID: UUID, now: Date) async {
        // Re-read fresh state right before network work so pause/cancel edits in the UI are never overwritten.
        let ctx = ModelContext(container)
        guard let p = try? ctx.fetch(FetchDescriptor<Publication>(predicate: #Predicate { $0.uuid == pubID })).first else { return }
        guard p.status.isQueuedForPublish, p.serverID == nil, p.publishOwner == .mac else { return }

        let accountID = p.accountID
        let wsID = p.workspaceID
        let account = try? ctx.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate {
            $0.serverID == accountID && $0.workspaceID == wsID
        })).first

        p.status = .preparing
        p.attempts += 1
        if p.firstTriedAt == nil { p.firstTriedAt = now }
        let attemptNo = p.attempts
        let previous = (try? ctx.fetch(FetchDescriptor<PublishAttempt>(predicate: #Predicate { $0.publicationID == pubID }))) ?? []
        let record = PublishAttempt(publicationID: p.uuid, attempt: attemptNo)
        record.idempotencyKey = p.idempotencyKey
        record.provider = p.platform
        record.accountID = p.accountID
        record.route = p.publishOwner.rawValue
        record.operation = "publish"
        record.containerID = p.containerID
        ctx.insert(record)
        save(ctx, context: "publishStart")

        guard let account, account.status == "connected", let target = Self.target(for: account, storage: storage) else {
            finish(p, record, AttemptResult(outcome: "auth", next: .failed(message: "The account is disconnected. Reconnect it in Connections.", expireAccount: false),
                                            httpStatus: nil, requestID: nil, error: "Account not connected"), account: account, ctx: ctx)
            return
        }

        let token = await ensureFreshToken(for: account, ctx: ctx)

        var image: Data?
        var contentType = "image/jpeg"
        var mediaFile: URL?
        var extraFiles: [URL] = []
        var isVideo = false
        if let assetID = p.assetID, let asset = try? ctx.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.uuid == assetID && $0.workspaceID == wsID })).first {
            if asset.kind == "video" {
                let file = asset.storedURL
                guard FileManager.default.fileExists(atPath: file.path) else {
                    finish(p, record, AttemptResult(outcome: "permanent", next: .failed(message: "Media file “\(asset.filename)” is missing from disk.", expireAccount: false),
                                                    httpStatus: nil, requestID: nil, error: "Missing video file"), account: account, ctx: ctx)
                    return
                }
                mediaFile = file
                isVideo = true
                contentType = MediaFormats.mimeType(for: file)
            } else {
                let variantID = p.variantID
                let variant = variantID.flatMap { id in try? ctx.fetch(FetchDescriptor<MediaVariant>(predicate: #Predicate { $0.uuid == id })).first }
                let file = variant?.url ?? asset.storedURL
                guard FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else {
                    finish(p, record, AttemptResult(outcome: "permanent", next: .failed(message: "Image file “\(asset.filename)” is missing or unreadable.", expireAccount: false),
                                                    httpStatus: nil, requestID: nil, error: "Unreadable image file"), account: account, ctx: ctx)
                    return
                }
                mediaFile = file
                image = data
                contentType = MediaFormats.mimeType(for: file)
            }
        }
        for extraID in p.extraAssetIDs {
            if let extra = try? ctx.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.uuid == extraID && $0.workspaceID == wsID })).first,
               FileManager.default.fileExists(atPath: extra.storedPath) {
                extraFiles.append(extra.storedURL)
            }
        }

        p.status = .publishing
        save(ctx, context: "publishTransition")

        // Route destination ID appropriately per platform.
        let destination: String
        switch account.platform {
        case "facebook", "instagram", "threads":
            destination = account.platformID
        case "linkedin":
            destination = p.boardID.isEmpty || p.boardID == "member" ? account.platformID : p.boardID
        default:
            destination = p.boardID
        }
        var input = PublishInput(idempotencyKey: p.idempotencyKey, accountID: account.serverID,
                                 accessToken: token, title: p.title, description: p.desc, link: p.link,
                                 altText: p.altText, boardID: destination, image: image, contentType: contentType)
        input.boardSectionID = p.boardSectionID.isEmpty ? nil : p.boardSectionID
        input.mediaFile = mediaFile
        input.extraMediaFiles = extraFiles
        input.isVideo = isVideo
        input.metadata = p.metadata
        input.existingContainerID = p.containerID

        let result = await PublishEngine.attempt(input, target: target, attempt: attemptNo,
                                                 hadUncertain: previous.contains { $0.outcome == "uncertain" },
                                                 firstTriedAt: p.firstTriedAt ?? now, policy: policy)
        finish(p, record, result, account: account, ctx: ctx)
    }

    private func finish(_ p: Publication, _ record: PublishAttempt, _ r: AttemptResult, account: SocialAccount?, ctx: ModelContext) {
        record.finishedAt = .now
        record.outcome = r.outcome
        record.httpStatus = r.httpStatus
        record.requestID = r.requestID
        record.error = r.error.map { DiagnosticRedactor.sanitize($0) }
        let late = Date.now.timeIntervalSince(p.scheduledAt)
        switch r.next {
        case .published(let out):
            p.status = .published
            p.publishedAt = .now
            p.publishedURL = out.url
            p.providerPostID = out.providerPostID
            p.containerID = out.containerID ?? p.containerID
            record.containerID = out.containerID ?? record.containerID
            p.lastError = nil
            p.nextAttemptAt = nil
            account?.lastPublishedAt = .now
            account?.lastVerifiedAt = .now
            account?.lastError = nil
            var text = "Published “\(p.title)”"
            if late > 600 { text += " \(Int(late / 60)) min late (the Mac was asleep or SocialForge was not running)" }
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: text, symbol: "checkmark.seal", category: "publishing"))
        case .retry(let at):
            p.status = .retryScheduled
            p.nextAttemptAt = at
            record.nextRetryAt = at
            p.lastError = record.error
        case .outcomeUnknown(let message):
            p.status = .outcomeUnknown
            p.lastError = DiagnosticRedactor.sanitize(message)
            p.nextAttemptAt = nil
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Outcome unknown for “\(p.title)”: verify on platform before retrying", symbol: "questionmark.diamond.fill", category: "publishing"))
        case .actionRequired(let message):
            p.status = .actionRequired
            p.lastError = DiagnosticRedactor.sanitize(message)
            p.nextAttemptAt = nil
            account?.lastError = p.lastError
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Action required for “\(p.title)”: \(p.lastError ?? "")", symbol: "exclamationmark.circle", category: "publishing"))
        case .failed(let message, let expire):
            let clean = DiagnosticRedactor.sanitize(message)
            p.status = expire ? .authRequired : .failed
            p.lastError = clean
            p.nextAttemptAt = nil
            if expire {
                account?.status = "expired"
                account?.lastError = clean
            }
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Failed “\(p.title)”: \(clean)", symbol: "exclamationmark.triangle", category: "publishing"))
        }
        save(ctx, context: "publishFinish")
        onLog("\(p.title): \(r.outcome)")
    }

    private func save(_ ctx: ModelContext, context label: String) {
        do {
            try ctx.save()
        } catch {
            lastError = "Database save failed (\(label)): \(error.localizedDescription)"
            onLog(lastError ?? "")
            fputs("PublishRunner save error (\(label)): \(error)\n", stderr)
        }
    }
}

/// An advisory lock on a file (flock). Released when the process exits, even after a crash.
final class RunnerLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire(at url: URL) -> RunnerLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return RunnerLock(fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// `SocialForge --publish-agent`: the launch agent. No window. Every 60 seconds
/// (and right after the Mac wakes) it takes the lock if the app is not running,
/// publishes what is due, and lets go. `--once` does one pass and exits (tests).
enum PublishAgent {
    static var requested: Bool { CommandLine.arguments.contains("--publish-agent") }
    @MainActor private static var passActive = false

    /// One pass, only if the app is not holding the lock and no local pass is already running.
    @MainActor
    static func pass(_ runner: PublishRunner) async -> Bool {
        guard !passActive else { return false }
        passActive = true
        defer { passActive = false }
        guard let lock = RunnerLock.acquire(at: runner.lockURL) else {
            print("publish-agent: SocialForge is open and publishing; standing by")
            return false
        }
        let n = await runner.passNow()
        print("publish-agent: pass done, \(n) due")
        withExtendedLifetime(lock) {}
        return true
    }

    @MainActor
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let container = Store.makeContainer()
        let storage = AppModel.storage(for: Store.url)
        let runner = PublishRunner(container: container, storage: storage)
        runner.onLog = { print("publish-agent: \($0)") }
        let once = CommandLine.arguments.contains("--once")
        Task { @MainActor in
            if once {
                _ = await pass(runner)
                exit(0)
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in _ = await pass(runner) }
            }
            while true {
                _ = await pass(runner)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}

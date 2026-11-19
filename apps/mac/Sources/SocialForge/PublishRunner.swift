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
    private(set) var lastPass: Date?
    private var timer: Timer?
    private var lock: RunnerLock?
    private var running = false
    var onLog: (String) -> Void = { _ in }

    init(container: ModelContainer, storage: ManagedStorage, policy: RetryPolicy = RetryPolicy()) {
        self.container = container
        self.storage = storage
        self.policy = policy
    }

    /// Where the mock provider keeps its "Pins": next to the store, shared by app and agent.
    static func mockFile(storage: ManagedStorage) -> URL { storage.root.appending(path: "MockPinterest/pins.json") }

    static func target(for account: SocialAccount?, storage: ManagedStorage) -> (any PublishTarget)? {
        guard let account else { return nil }
        if account.isMock { return MockPinterestTarget(file: mockFile(storage: storage)) }
        if account.platform == "pinterest" {
            let base = UserDefaults.standard.string(forKey: "pinterest.apiBase").flatMap(URL.init(string:)) ?? URL(string: "https://api.pinterest.com")!
            return PinterestTarget(apiBase: base)
        }
        return nil
    }

    /// The app: hold the lock while open, publish every 30 seconds and on wake.
    func startInApp() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        kick()
    }

    func kick() {
        guard !running else { return }
        if lock == nil { lock = RunnerLock.acquire(at: lockURL) }
        guard lock != nil else { return }  // the agent is mid-pass; try again on the next tick
        Task { await passNow() }
    }

    var lockURL: URL { storage.root.appending(path: "publisher.lock") }

    /// Lets the launch agent take over (self-test only; the app normally keeps the lock while open).
    func releaseLock() { lock = nil }
    var holdsLock: Bool { lock != nil }

    /// One pass: every scheduled post that is due and not waiting for a retry.
    @discardableResult
    func passNow(now: Date = .now) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false; lastPass = .now }
        // A fresh context reads what the other process wrote.
        let ctx = ModelContext(container)
        let scheduled = PublicationStatus.scheduled.rawValue
        let due = (try? ctx.fetch(FetchDescriptor<Publication>(
            predicate: #Predicate { $0.statusRaw == scheduled && $0.scheduledAt <= now && $0.serverID == nil },
            sortBy: [SortDescriptor(\.scheduledAt)]))) ?? []
        var done = 0
        for p in due where (p.nextAttemptAt ?? .distantPast) <= now {
            await publish(p, ctx: ctx)
            done += 1
        }
        return done
    }

    private func publish(_ p: Publication, ctx: ModelContext) async {
        let accountID = p.accountID
        let account = try? ctx.fetch(FetchDescriptor<SocialAccount>(predicate: #Predicate { $0.serverID == accountID })).first
        p.status = .publishing
        p.attempts += 1
        if p.firstTriedAt == nil { p.firstTriedAt = .now }
        let attemptNo = p.attempts
        let pubID = p.uuid
        let previous = (try? ctx.fetch(FetchDescriptor<PublishAttempt>(predicate: #Predicate { $0.publicationID == pubID }))) ?? []
        let record = PublishAttempt(publicationID: p.uuid, attempt: attemptNo)
        ctx.insert(record)
        try? ctx.save()

        guard let account, account.status == "connected", let target = Self.target(for: account, storage: storage) else {
            finish(p, record, AttemptResult(outcome: "auth", next: .failed(message: "The account is disconnected. Reconnect it in Social Accounts.", expireAccount: false),
                                            httpStatus: nil, requestID: nil, error: "Account not connected"), account: account, ctx: ctx)
            return
        }
        var image: Data?
        var contentType = "image/jpeg"
        if let assetID = p.assetID, let asset = try? ctx.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.uuid == assetID })).first {
            let variantID = p.variantID
            let variant = variantID.flatMap { id in try? ctx.fetch(FetchDescriptor<MediaVariant>(predicate: #Predicate { $0.uuid == id })).first }
            image = try? Data(contentsOf: variant?.url ?? asset.storedURL)
            contentType = (variant?.format ?? asset.format) == "png" ? "image/png" : "image/jpeg"
        }
        let input = PublishInput(idempotencyKey: p.idempotencyKey, accountID: account.serverID,
                                 accessToken: account.isMock ? nil : Keychain.read(account.tokenKey),
                                 title: p.title, description: p.desc, link: p.link, altText: p.altText, boardID: p.boardID,
                                 image: image, contentType: contentType)
        let result = await PublishEngine.attempt(input, target: target, attempt: attemptNo,
                                                 hadUncertain: previous.contains { $0.outcome == "uncertain" },
                                                 firstTriedAt: p.firstTriedAt ?? .now, policy: policy)
        finish(p, record, result, account: account, ctx: ctx)
    }

    private func finish(_ p: Publication, _ record: PublishAttempt, _ r: AttemptResult, account: SocialAccount?, ctx: ModelContext) {
        record.finishedAt = .now
        record.outcome = r.outcome
        record.httpStatus = r.httpStatus
        record.requestID = r.requestID
        record.error = r.error
        let late = Date.now.timeIntervalSince(p.scheduledAt)
        switch r.next {
        case .published(let out):
            p.status = .published
            p.publishedURL = out.url
            p.providerPostID = out.providerPostID
            p.lastError = nil
            p.nextAttemptAt = nil
            account?.lastPublishedAt = .now
            var text = "Published “\(p.title)”"
            if late > 600 { text += " \(Int(late / 60)) min late (the Mac was asleep or SocialForge was not running)" }
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: text, symbol: "checkmark.seal"))
        case .retry(let at):
            p.status = .scheduled
            p.nextAttemptAt = at
            p.lastError = r.error
        case .failed(let message, let expire):
            p.status = .failed
            p.lastError = message
            p.nextAttemptAt = nil
            if expire { account?.status = "expired" }
            ctx.insert(ActivityEntry(workspaceID: p.workspaceID, text: "Failed “\(p.title)”: \(message)", symbol: "exclamationmark.triangle"))
        }
        try? ctx.save()
        onLog("\(p.title): \(r.outcome)")
    }
}

/// An advisory lock on a file (flock). Released when the process exits, even after a crash.
final class RunnerLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire(at url: URL) -> RunnerLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
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

    /// One pass, only if the app is not holding the lock.
    @MainActor
    static func pass(_ runner: PublishRunner) async -> Bool {
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

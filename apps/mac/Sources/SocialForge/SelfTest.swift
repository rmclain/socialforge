import AppKit
import SwiftData
import SocialForgeKit

/// Self-test for agents: runs the app's real functions on a test store,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/SocialForge-self.store ~/Applications/SocialForge.app/Contents/MacOS/SocialForge --selftest
/// (tools/selftest.sh does this.) With APP_BACKEND_URL and APP_BACKEND_TOKEN set,
/// it also activates the run against that publishing service and syncs back.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            await run(model)
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func run(_ model: AppModel) async {
        let ctx = model.context

        // S-002 workspaces
        let before = model.workspaces.count
        let ws = model.createWorkspace(name: "  Self Test Co  ", colorHex: 0x2BC48A)
        check("New Workspace adds one and selects it", model.workspaces.count == before + 1 && model.workspaceID == ws.uuid)
        check("workspace names are trimmed", ws.name == "Self Test Co")

        // S-010 import a folder of 30 images and a CSV
        let src = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "sf-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        var csv = "filename,title,url\n"
        for i in 1...30 {
            let name = String(format: "product-%02d.jpg", i)
            SeedData.drawProduct(to: src.appending(path: name), hue: Double(i * 11), shape: i % 3)
            csv += "\(name),Product \(i),https://shop.example.com/p/\(i)\n"
        }
        try? FileManager.default.copyItem(at: src.appending(path: "product-01.jpg"), to: src.appending(path: "zz-copy-of-01.jpg"))
        try? csv.write(to: src.appending(path: "products.csv"), atomically: true, encoding: .utf8)
        let original = try? Data(contentsOf: src.appending(path: "product-05.jpg"))
        let assets = await model.importMedia([src]).sorted { $0.filename < $1.filename }
        check("imports 30 images and skips the duplicate", assets.count == 30, "got \(assets.count)")
        check("reports the duplicate", model.lastImportSummary?.contains("1 duplicates") == true, model.lastImportSummary ?? "")
        check("originals are unchanged", (try? Data(contentsOf: src.appending(path: "product-05.jpg"))) == original)
        check("CSV in the folder is loaded", model.bulk.table?.rows.count == 30)

        // S-011 variants
        let variants = await model.makeVariants(Array(assets.prefix(5)), preset: ExportPreset.builtIn[0])
        check("makes 5 Pinterest variants at 1000×1500", variants.count == 5 && variants.allSatisfy { $0.width == 1000 && $0.height == 1500 })

        // S-020 to S-023: match, target, schedule, validate
        let acct = SocialAccount(serverID: "acct_selftest", workspaceID: ws.uuid, platform: "pinterest", name: "Self Test", status: "connected")
        acct.scopes = ["boards:read", "pins:write"]
        ctx.insert(acct)
        let board = API.Board(id: "board_1", name: "Board", privacy: nil)
        let bulk = model.bulk
        bulk.assetIDs = assets.map(\.uuid)
        bulk.accountID = acct.serverID
        bulk.rule = ScheduleRule(timeZoneID: "America/New_York", start: LocalDay(Calendar.current.date(byAdding: .day, value: 2, to: .now)!, in: .current), times: [LocalTime(9)])
        bulk.rematch(assets: assets)
        check("all 30 images match a CSV row", bulk.report?.matched.count == 30, bulk.report?.summary ?? "no report")
        let posts = (try? bulk.createPosts(model: model, assets: assets, account: acct, board: board)) ?? []
        check("creates 30 posts, all Needs Review", posts.count == 30 && posts.allSatisfy { $0.status == .needsReview })
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        check("every post is at 9:00 New York time, one per day",
              posts.allSatisfy { ny.component(.hour, from: $0.scheduledAt) == 9 } && Set(posts.map { LocalDay($0.scheduledAt, in: ny.timeZone) }).count == 30)
        check("links come from the CSV", posts.first?.link == "https://shop.example.com/p/1")
        check("variant is attached to posts that have one", posts.prefix(5).allSatisfy { $0.variantID != nil })
        check("valid posts have no errors", posts.allSatisfy { !$0.hasErrors(model: model) },
              posts.first.map { $0.issues(model: model).map(\.message).joined(separator: "; ") } ?? "")
        posts[0].title = String(repeating: "x", count: 120)
        check("a 120-character title is an error", posts[0].hasErrors(model: model))
        posts[0].title = "Product 1"

        // Scenario E: missing permission blocks
        acct.scopes = ["boards:read"]
        check("an account without pins:write blocks posts", posts[1].hasErrors(model: model))
        acct.scopes = ["boards:read", "pins:write"]

        // Approval
        for p in posts where !p.hasErrors(model: model) { p.status = .approved }
        check("all 30 approved", posts.allSatisfy { $0.status == .approved })

        // Regenerate the schedule without recreating media
        bulk.rule.everyDays = 2
        try? bulk.reschedule(posts)
        let days = posts.map { LocalDay($0.scheduledAt, in: ny.timeZone) }.sorted()
        check("reschedule every 2 days keeps the posts", posts.count == 30 && days.count == 30 && days[1] != days[0])

        // S-040 studio export and brand templates
        let studio = model.studio
        model.ensureBuiltInTemplates()
        check("three editable brand templates exist", model.templates.count == 3)
        let kit = BrandKit(workspaceID: ws.uuid, name: "Self Test Brand")
        kit.colors = [0x111111, 0xEEEEEE, 0xFF0000]
        kit.headlineFont = "Helvetica"
        kit.bodyFont = "Helvetica"
        ctx.insert(kit)
        try? ctx.save()
        studio.open(StudioModel.productPin().withPhoto(assets[0].storedPath), designID: nil)
        let layerCount = studio.document?.layers.count ?? 0
        studio.addText(model: model)
        check("adding a layer can be undone", studio.canUndo)
        studio.undo()
        check("undo removes it", studio.document?.layers.count == layerCount)
        func headlineColor() -> UInt32? {
            guard let d = studio.rendered(brand: model.brandKit?.style), let l = d.layers.first(where: { $0.name == "Headline" }), case .text(let t) = l.content else { return nil }
            return t.color.hex
        }
        check("headline uses the brand's color 2", headlineColor() == 0xEEEEEE)
        kit.colors[1] = 0x00FF00
        check("changing the brand kit restyles the design", headlineColor() == 0x00FF00)
        studio.saveAsTemplate(model: model, name: "Self Test Template")
        check("Save as template adds a template", model.templates.count == 4 && studio.templateID != nil)
        if let t = model.templates.first(where: { $0.name == "Self Test Template" }) {
            studio.change { $0.name = "Self Test Template v2" }
            studio.save(model: model)
            check("saving a template updates it in place", model.templates.contains { $0.name == "Self Test Template v2" } && model.templates.count == 4)
            let before = (try? ctx.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0
            await studio.applyTemplate(t, to: Array(assets.prefix(3)), model: model)
            let after = (try? ctx.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0
            check("applying a template to 3 images makes 3 branded graphics", after == before + 3, studio.exportMessage ?? "")
        }
        studio.resize(to: CanvasPreset.all[1])
        check("smart resize switches to 1200 × 628 with text still live", studio.document?.width == 1200 && studio.document?.height == 628
              && studio.document?.layers.contains { if case .text = $0.content { true } else { false } } == true)
        let countBefore = (try? ctx.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0
        await studio.export(model: model)
        check("export adds a PNG to the library", ((try? ctx.fetchCount(FetchDescriptor<MediaAsset>())) ?? 0) == countBefore + 1, studio.exportMessage ?? "")

        // Analytics and command tools work on real data.
        let summary = Analytics.summarize(model.workspacePublications.map { PostRecord(platform: $0.platform, status: $0.statusRaw, scheduledAt: $0.scheduledAt) },
                                          from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(90 * 86_400))
        check("analytics counts the 30 approved posts", summary.scheduled == 30, "\(summary.scheduled)")
        check("assistant time parsing", ToolRunner.parseTime("9 AM") == LocalTime(9) && ToolRunner.parseTime("8:30pm") == LocalTime(20, 30))

        // On-Mac publishing (the default): the app publishes due posts itself.
        check("publishing defaults to this Mac", model.publishMode == .mac)
        guard let mock = model.addMockAccount() else { check("mock account added", false); return }
        check("mock account is labeled as mock", mock.isMock && mock.source == "mac" && mock.name.contains("Mock"))
        let mockFile = PublishRunner.mockFile(storage: model.storage)
        let pinsBefore = await MockPinterestTarget(file: mockFile).posts().count
        func duePosts(_ n: Int, from: Int) -> [Publication] {
            assets[from..<(from + n)].map { a in
                let p = Publication(workspaceID: ws.uuid, scheduledAt: .now.addingTimeInterval(2), timeZoneID: "America/New_York")
                p.assetID = a.uuid; p.accountID = mock.serverID; p.accountName = mock.name; p.boardID = "board_winter"; p.boardName = "Winter Home Edit"
                p.title = a.filename; p.link = "https://shop.example.com/\(a.filename)"; p.status = .approved
                ctx.insert(p)
                return p
            }
        }
        let local = duePosts(6, from: 10)
        try? ctx.save()
        let sent = await model.activate(local)
        check("activating on this Mac schedules 6 posts", sent.sent == 6 && local.allSatisfy { $0.status == .scheduled })
        try? await Task.sleep(for: .seconds(2.5))
        let firstPass = await model.runner.passNow()
        func fresh(_ ids: [UUID]) -> [Publication] {
            let c = ModelContext(model.container)
            return ((try? c.fetch(FetchDescriptor<Publication>())) ?? []).filter { ids.contains($0.uuid) }
        }
        let afterFirst = fresh(local.map(\.uuid))
        check("the app publishes all 6 due posts", firstPass == 6 && afterFirst.allSatisfy { $0.status == .published && $0.publishedURL != nil },
              afterFirst.map { "\($0.statusRaw) \($0.lastError ?? "")" }.joined(separator: ", "))
        let pins = { await MockPinterestTarget(file: mockFile).posts().count - pinsBefore }
        let c1 = await pins()
        check("each post was published exactly once", c1 == 6, "\(c1) pins")
        _ = await model.runner.passNow()
        check("a second pass publishes nothing again", await pins() == 6)
        let attempts = (try? ModelContext(model.container).fetch(FetchDescriptor<PublishAttempt>())) ?? []
        check("every attempt is recorded", attempts.filter { $0.outcome == "success" }.count == 6)

        // The launch agent: stands by while the app holds the lock, publishes once it is free.
        let agentPosts = duePosts(4, from: 20)
        try? ctx.save()
        _ = await model.activate(agentPosts)
        check("the app holds the publisher lock", model.runner.holdsLock)
        try? await Task.sleep(for: .seconds(2.5))
        let standby = runAgentOnce()
        check("the agent stands by while the app is open", standby.contains("standing by"), standby)
        check("nothing was published twice by the agent", await pins() == 6)
        model.runner.releaseLock()
        let ran = runAgentOnce()
        check("with the app's lock released, the agent publishes the 4 due posts", ran.contains("pass done, 4 due"), ran)
        let afterAgent = fresh(agentPosts.map(\.uuid))
        check("the agent's results are in the store", afterAgent.allSatisfy { $0.status == .published }, afterAgent.map(\.statusRaw).joined(separator: ","))
        let c2 = await pins()
        check("10 Pins in total, no duplicates", c2 == 10, "\(c2) pins")

        // Optional: the real publishing service.
        let env = ProcessInfo.processInfo.environment
        if let url = env["APP_BACKEND_URL"], !url.isEmpty {
            model.publishMode = .service
            model.backendURLString = url
            await model.checkBackend()
            check("publishing service is up", { if case .up = model.backendStatus { true } else { false } }(), "\(model.backendStatus)")
            await model.refreshAccounts()
            guard let mock = model.accounts.first(where: { $0.isMock }) else {
                check("service lists the mock Pinterest account", false)
                return
            }
            check("service lists the mock Pinterest account", true)
            let boards = model.boards[mock.serverID] ?? []
            check("boards load for the account", !boards.isEmpty)
            for p in posts { p.accountID = mock.serverID; p.accountName = mock.name; p.boardID = boards.first?.id ?? ""; p.boardName = boards.first?.name ?? "" }
            let r = await model.activate(posts)
            check("activation sends 30 posts", r.sent == 30 && r.failed.isEmpty, r.failed.joined(separator: "; "))
            check("posts are Scheduled with server ids", posts.allSatisfy { $0.status == .scheduled && $0.serverID != nil })
            let again = await model.activate(posts)
            check("activating again sends nothing twice", again.sent == 0)
            await model.sync()
            check("sync keeps 30 scheduled", posts.allSatisfy { $0.status == .scheduled })
        }
    }

    /// Runs this same binary as the launch agent for one pass, on the same test store.
    private static func runAgentOnce() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--publish-agent", "--once"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "could not start: \(error)" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}

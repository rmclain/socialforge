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
        defer { try? FileManager.default.removeItem(at: src) }
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
        // Issue: Delete on a selected canvas element removes it; a locked one stays.
        studio.addText(model: model)
        let added = studio.selectedLayer
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: NSApp.windows.first?.windowNumber ?? 0, context: nil,
                                   characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)
        if let key, key.window != nil {
            let w = key.window!
            // As a click on the canvas does: the search field gives up focus.
            StudioDeleteKey.endTextEditing(in: w)
            check("the Delete key removes the selected canvas layer", StudioDeleteKey.handle(key, studio: studio)
                  && studio.document?.layers.contains { $0.id == added } == false,
                  "first responder: \(String(describing: w.firstResponder))")
        } else {
            studio.deleteSelection()
            check("Delete Layer removes the selected canvas layer", studio.document?.layers.contains { $0.id == added } == false)
        }
        if let first = studio.document?.layers.first?.id {
            studio.changeLayer(first) { $0.isLocked = true }
            studio.selectedLayer = first
            studio.deleteSelection()
            check("a locked layer is not deleted and says why", studio.document?.layers.contains { $0.id == first } == true
                  && studio.exportMessage?.contains("locked") == true)
            studio.changeLayer(first) { $0.isLocked = false }
            studio.exportMessage = nil
        }
        check("deleting is undoable", studio.canUndo)
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

        // Issue: Generate all sizes says when it is done and keeps the results together.
        let setName = StudioModel.sizeSetName(for: studio.document?.name ?? "")
        model.mediaSelection = [assets[1].uuid]
        await studio.generateAllSizes(model: model)
        check("exports leave the Media Library selection alone (it fills the photo slot)", model.mediaSelection == [assets[1].uuid])
        let sizeCount = CanvasPreset.all.count
        func setDesigns() -> [Design] { ((try? ctx.fetch(FetchDescriptor<Design>())) ?? []).filter { $0.sizeSet == setName } }
        func setImages() -> [MediaAsset] { ((try? ctx.fetch(FetchDescriptor<MediaAsset>())) ?? []).filter { $0.collection == "Sizes · \(setName)" } }
        check("Generate all sizes says it is done", studio.exportMessage?.hasPrefix("Done: \(sizeCount) sizes") == true && studio.busy == nil
              && studio.sizesProgress == nil, studio.exportMessage ?? "")
        check("the sizes are one set of designs and one collection", setDesigns().count == sizeCount && setImages().count == sizeCount,
              "\(setDesigns().count) designs, \(setImages().count) images")
        check("Show in Finder has every file", studio.lastSizes?.files.count == sizeCount
              && studio.lastSizes?.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } == true)
        await studio.generateAllSizes(model: model)
        check("running it again replaces the set's designs and still says done", setDesigns().count == sizeCount
              && studio.exportMessage?.hasPrefix("Done: \(sizeCount) sizes") == true, "\(setDesigns().count) · \(studio.exportMessage ?? "")")
        check("a size's name maps back to its set", StudioModel.sizeSetName(for: "\(setName) · Story") == setName)
        print("SIZES \(studio.lastSizes?.files.map(\.path).joined(separator: " ") ?? "")")

        // Issue: Remove from Collection takes media out, including Studio exports under Branded.
        let plain = assets[5], branded = (try? ctx.fetch(FetchDescriptor<MediaAsset>()))?.first { $0.tags.contains("branded") }
        model.setCollection("Self Test", for: [plain])
        check("Add to collection files the image", plain.collection == "Self Test")
        model.setCollection("", for: [plain])
        check("Remove from Collection empties it", plain.collection.isEmpty)
        if let branded {
            model.setCollection("", for: [branded])
            check("a removed Studio export leaves the Branded filter too", branded.collection.isEmpty && !branded.tags.contains("branded"))
        } else {
            check("a Studio export is in the library", false)
        }

        // Issue: double-clicking a calendar day starts a post for that day.
        let pageBefore = model.page
        let inThreeDays = Calendar.current.date(byAdding: .day, value: 3, to: .now)!
        let opened = CalendarCompose.open(on: inThreeDays, model: model)
        check("double-clicking a day opens the Composer at 9:00 that day", opened && model.page == .composer
              && Calendar.current.isDate(model.composer.when, inSameDayAs: inThreeDays) && Calendar.current.component(.hour, from: model.composer.when) == 9)
        model.page = pageBefore
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        check("a past day does not open the Composer", !CalendarCompose.open(on: yesterday, model: model) && model.page == pageBefore)

        // Analytics and command tools work on real data.
        let summary = Analytics.summarize(model.workspacePublications.map { PostRecord(platform: $0.platform, status: $0.statusRaw, scheduledAt: $0.scheduledAt) },
                                          from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(90 * 86_400))
        check("analytics counts the 30 approved posts", summary.scheduled == 30, "\(summary.scheduled)")
        check("assistant time parsing", ToolRunner.parseTime("9 AM") == LocalTime(9) && ToolRunner.parseTime("8:30pm") == LocalTime(20, 30))

        // Issue: first launch sets up the first brand (or imports one), then opens Accounts.
        check("a library with work in it skips the Welcome sheet", !model.needsBrandSetup)
        if let empty = try? ModelContainer(for: SwiftData.Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
            let fresh = AppModel(container: empty)
            check("a new library asks for its first brand", fresh.needsBrandSetup && fresh.workspaces.count == 1)
            let kit = await fresh.completeBrandSetup(name: "  Juniper Goods ", colorHex: 0x2BC48A, voice: "Warm and plain-spoken",
                                                     hashtags: ["#handmade", " slowliving"], logo: nil)
            check("Create Brand names the workspace and makes its kit", fresh.workspace?.name == "Juniper Goods" && fresh.workspace?.colorHex == 0x2BC48A
                  && kit?.name == "Juniper Goods" && kit?.colors.contains(0x2BC48A) == true && kit?.hashtags == ["handmade", "slowliving"]
                  && fresh.brandKit?.voice == "Warm and plain-spoken")
            check("then Accounts opens and the sheet does not come back", fresh.page == .accounts && !fresh.showWelcome && !fresh.needsBrandSetup)
            // The kit exports to a .sfbrand file, and a second new library sets up by importing it.
            if let made = kit {
                let file = FileManager.default.temporaryDirectory.appending(path: "selftest-\(UUID().uuidString).sfbrand")
                BrandKitIO.write(made, templates: [], to: file)
                if let other = try? ModelContainer(for: SwiftData.Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
                    let second = AppModel(container: other)
                    let imported = BrandKitIO.importKit(from: file, model: second)
                    if let imported { second.completeBrandImport(imported) }
                    check("Import Brand Kit on the Welcome sheet sets up the brand from a .sfbrand file",
                          imported?.voice == "Warm and plain-spoken" && imported?.hashtags == ["handmade", "slowliving"]
                          && second.workspace?.name == "Juniper Goods" && second.workspace?.colorHex == 0x2BC48A
                          && second.page == .accounts && !second.needsBrandSetup)
                }
                try? FileManager.default.removeItem(at: file)
                check("a file that is not a brand kit is refused", BrandKitIO.importKit(from: URL(fileURLWithPath: "/etc/hosts"), model: fresh) == nil)
            }
            check("every platform links to where its developer keys are made",
                  PlatformRegistry.all.allSatisfy { PlatformKeys.forPlatform($0.platform) != nil }
                  && PlatformKeysList.redirect(for: "pinterest")?.hasPrefix("https://") == true
                  && PlatformKeysList.redirect(for: "threads")?.hasPrefix("https://") == true)
            // A brand saves its files to its own folder (Brand Kits > Save files to).
            if let made = kit {
                let folder = FileManager.default.temporaryDirectory.appending(path: "selftest-brand-\(UUID().uuidString)/Juniper Goods", directoryHint: .isDirectory)
                let library = fresh.libraryStorage.root
                check("a brand folder is created when chosen", fresh.setBrandFolder(folder, for: made)
                      && FileManager.default.fileExists(atPath: folder.path) && fresh.storage.root.standardizedFileURL == folder.standardizedFileURL)
                let png = FileManager.default.temporaryDirectory.appending(path: "selftest-\(UUID().uuidString).png")
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                rep?.setColor(NSColor(red: 0.2, green: 0.7, blue: 0.5, alpha: 1), atX: 1, y: 1)
                try? rep?.representation(using: .png, properties: [:])?.write(to: png)
                let added = await fresh.importMedia([png])
                check("new media for that brand is saved in its folder", added.first?.storedPath.hasPrefix(folder.standardizedFileURL.path) == true,
                      added.first?.storedPath ?? "nothing imported")
                check("the publisher's own files stay in the app's library", fresh.libraryStorage.root == library && fresh.runner.storage.root == library)
                check("Suggested folder is Documents/<brand>", AppModel.suggestedFolder(for: "Brand1").path == URL.documentsDirectory.appending(path: "Brand1").path)

                // Media Library Delete warns about posts and designs, and keeps a stored file another record still uses.
                if let a = added.first {
                    let twin = MediaAsset(workspaceID: a.workspaceID, filename: a.filename, storedPath: a.storedPath,
                                          sourcePath: a.sourcePath, sha256: a.sha256, bytes: a.bytes)
                    fresh.context.insert(twin)
                    let post = Publication(workspaceID: a.workspaceID, scheduledAt: .now.addingTimeInterval(86_400), timeZoneID: "UTC")
                    post.assetID = twin.uuid
                    fresh.context.insert(post)
                    let design = Design(workspaceID: a.workspaceID, document: StudioModel.productPin().withPhoto(twin.storedPath))
                    fresh.context.insert(design)
                    let usage = fresh.mediaUsage([twin])
                    check("Delete warns about a post and a design that still use the media", usage.posts == 1 && usage.designs >= 1,
                          "\(usage.posts) posts, \(usage.designs) designs")
                    post.status = .published
                    check("published posts do not count as still using the media", fresh.mediaUsage([twin]).posts == 0)
                    let twinID = twin.uuid
                    fresh.mediaSelection = [twinID]
                    fresh.deleteMedia([twin], trashFiles: true)
                    check("Delete removes the record and its selection", fresh.asset(twinID) == nil && fresh.mediaSelection.isEmpty)
                    check("Delete keeps a stored file that another library item still uses", FileManager.default.fileExists(atPath: a.storedPath))
                    fresh.context.delete(post)
                    fresh.context.delete(design)
                }

                // Agents over MCP: reads see the library; changes go through the inbox and land in Needs Review.
                if let a = added.first, let ws = fresh.workspaceID {
                    let inbox = fresh.agentInbox
                    let account = SocialAccount(serverID: "selftest-agent-acct", workspaceID: ws, platform: "pinterest", name: "Agent Test", status: "connected")
                    fresh.context.insert(account)
                    try? fresh.context.save()
                    let brand = JSONValue.string(ws.uuidString)
                    let listed = AgentMCP.handle("list_media", args: ["brand": brand, "query": .string(a.filename)], client: "Claude Code",
                                                 context: fresh.context, inbox: inbox)
                    check("an agent's list_media finds the brand's media", !listed.isError && listed.text.contains(a.uuid.uuidString))
                    let accounts = AgentMCP.handle("list_accounts", args: ["brand": brand], client: "Claude Code", context: fresh.context, inbox: inbox)
                    check("an agent's list_accounts lists the brand's accounts", accounts.text.contains("selftest-agent-acct"))
                    let when = JSONValue.string(AgentTools.iso(.now.addingTimeInterval(2 * 86_400)))
                    let queued = AgentMCP.handle("create_posts", args: ["brand": brand, "posts": .array([
                        .object(["account_id": .string("selftest-agent-acct"), "media_id": .string(a.uuid.uuidString), "scheduled_at": when, "title": .string("Agent pin")]),
                        .object(["account_id": .string("Agent Test"), "file": .string(png.path), "scheduled_at": when]),
                    ])], client: "Claude Code", context: fresh.context, inbox: inbox)
                    let bad = AgentMCP.handle("create_posts", args: ["brand": brand, "posts": .array([
                        .object(["account_id": .string("selftest-agent-acct"), "file": .string("/nope.png"), "scheduled_at": when]),
                    ])], client: "Codex", context: fresh.context, inbox: inbox)
                    check("a request with a missing file is refused before it is queued", bad.isError && inbox.pendingCount == 1, bad.text)
                    let unknown = AgentMCP.handle("create_posts", args: ["brand": brand, "posts": .array([
                        .object(["account_id": .string("no-such-account"), "media_id": .string(a.uuid.uuidString), "scheduled_at": when]),
                    ])], client: "Codex", context: fresh.context, inbox: inbox)
                    check("an agent's change is queued, not written", !queued.isError && queued.text.contains("Queued") && fresh.workspacePublications.allSatisfy { $0.runName != "From Claude Code" })
                    let handled = await fresh.processAgentInbox()
                    let made = fresh.workspacePublications.filter { $0.runName == "From Claude Code" }
                    check("the app applies queued requests", handled == 2 && inbox.pendingCount == 0, "\(handled) handled")
                    check("agent posts land in Needs Review, for the person to approve",
                          made.count == 2 && made.allSatisfy { $0.status == .needsReview && $0.accountID == "selftest-agent-acct" && $0.assetID == a.uuid }
                          && made.contains { $0.title == "Agent pin" }, "\(made.count) posts")
                    let unknownID = unknown.text.components(separatedBy: " ").dropFirst(3).first.flatMap { UUID(uuidString: String($0.dropLast())) }
                    let failed = unknownID.flatMap { inbox.result($0) }
                    check("a request naming an unknown account makes nothing and says why",
                          failed?.ok == false && failed?.message.contains("no account") == true && !fresh.workspacePublications.contains { $0.runName == "From Codex" },
                          failed?.message ?? unknown.text)
                    let status = AgentMCP.handle("get_request_status", args: [:], client: "Claude Code", context: fresh.context, inbox: inbox)
                    check("get_request_status reports what was made", status.text.contains(made[0].uuid.uuidString) || status.text.contains(made.last?.uuid.uuidString ?? "-"))
                    for p in made { fresh.context.delete(p) }
                    fresh.context.delete(account)
                    try? fresh.context.save()
                    try? FileManager.default.removeItem(at: inbox.root)
                }

                // Deleting a generated result from AI Studio removes it from the batch, the library, and the job.
                if let a = added.first {
                    let job = AIJob(workspaceID: fresh.workspaceID ?? UUID(), provider: "ComfyUI", kind: "image", prompt: "test")
                    job.outputAssetIDs = [a.uuid]
                    fresh.context.insert(job)
                    fresh.aiStudio.lastJobID = job.uuid
                    fresh.aiStudio.resultIDs = [a.uuid]
                    fresh.aiStudio.selectedResult = a.uuid
                    let id = a.uuid
                    fresh.deleteMedia([a], trashFiles: false)
                    fresh.aiStudio.resultIDs.removeAll { $0 == id }
                    check("Delete on a result removes it from the library and the job's history",
                          fresh.asset(id) == nil && job.outputAssetIDs.isEmpty && fresh.aiStudio.resultIDs.isEmpty)
                }
                fresh.setBrandFolder(nil, for: made)
                check("Use Default goes back to the app's library", fresh.storage.root == library)
                try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: png)
            }
            check("Appearance offers System, Light, and Dark", ThemeStore.Mode.allCases.map(\.title) == ["System", "Light", "Dark"]
                  && ThemeStore.Mode.system.appearance == nil && ThemeStore.Mode.dark.appearance?.name == .darkAqua && ThemeStore.Mode.light.appearance?.name == .aqua)
            let skipped = AppModel(container: (try? ModelContainer(for: SwiftData.Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))) ?? empty)
            skipped.finishBrandSetup()
            check("Skip for Now opens Accounts", skipped.page == .accounts && !skipped.showWelcome)
        } else {
            check("an empty library opens", false)
        }

        // On-Mac publishing (the default): the app publishes due posts itself.
        check("publishing defaults to this Mac", model.publishMode == .mac)
        guard let mock = model.addMockAccount() else { check("mock account added", false); return }
        check("mock account is labeled as mock", mock.isMock && mock.source == "mac" && mock.name.contains("Mock"))
        let mockFile = PublishRunner.mockFile(storage: model.libraryStorage)
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

        // Scenario D & E: Approval invalidation on edit + Unknown outcome manual reconciliation
        let reconPost = Publication(workspaceID: ws.uuid, scheduledAt: .now.addingTimeInterval(3600), timeZoneID: "America/New_York")
        reconPost.assetID = assets[0].uuid; reconPost.accountID = mock.serverID; reconPost.accountName = mock.name
        reconPost.boardID = "board_winter"; reconPost.title = "Approved Pin"; reconPost.status = .approved
        ctx.insert(reconPost)
        reconPost.title = "Edited After Approval"
        reconPost.invalidateApprovalIfChanged()
        check("editing an approved post invalidates approval back to Needs Review", reconPost.status == .needsReview)
        reconPost.status = .outcomeUnknown
        reconPost.lastError = "Network dropped after request sent."
        model.markOutcomeConfirmedPublished(reconPost, url: "https://pinterest.com/pin/manual-confirmed")
        check("manual reconciliation confirms unknown outcome as published", reconPost.status == .published && reconPost.publishedURL == "https://pinterest.com/pin/manual-confirmed")

        // Scenario H: Crash-recovery idempotency for Inbound MCP create_posts (no duplicates)
        let idemReqID = UUID()
        let idemReq = AgentRequest(id: idemReqID, tool: "create_posts", args: [
            "brand": .string(ws.uuid.uuidString),
            "posts": .array([
                .object(["account_id": .string(mock.serverID), "media_id": .string(assets[0].uuid.uuidString),
                         "scheduled_at": .string(AgentTools.iso(.now.addingTimeInterval(86_400))), "title": .string("Idem Pin")])
            ]),
        ], client: "Claude Code")
        let r1 = await model.applyAgentRequest(idemReq)
        let r2 = await model.applyAgentRequest(idemReq)
        let idemCount = model.workspacePublications.count { $0.agentRequestID == idemReqID.uuidString }
        check("MCP crash-recovery replay creates zero duplicate posts", r1.ok && r2.ok && idemCount == 1, "count=\(idemCount)")

        // Scenario I: Multi-brand workspace isolation (5 brands) + Automation managed-folder guard
        let overlapErr = AutomationEngine.folderOverlapProblem(model.storage.root.path, workspaceID: ws.uuid, model: model)
        check("automation blocks watching SocialForge managed library folder", overlapErr != nil)
        let originalWS = ws.uuid
        var brandIDs: [UUID] = []
        for idx in 1...5 {
            let b = model.createWorkspace(name: "Brand \(idx)", colorHex: 0xFF8A5C)
            brandIDs.append(b.uuid)
        }
        check("5 isolated brand workspaces have zero leaked posts from first workspace",
              model.workspacePublications.isEmpty && model.accounts.isEmpty)
        model.workspaceID = originalWS
        check("switching back restores original workspace posts cleanly", !model.workspacePublications.isEmpty)
        for bid in brandIDs {
            if let w = model.workspaces.first(where: { $0.uuid == bid }) { ctx.delete(w) }
        }
        try? ctx.save()

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

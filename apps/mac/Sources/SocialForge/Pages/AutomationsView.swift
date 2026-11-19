import SwiftData
import SwiftUI
import SocialForgeKit

/// Runs automations. Every run ends with posts in Needs Review: automations never publish.
@MainActor
enum AutomationEngine {
    struct Plan {
        var newFiles: [URL] = []
        var tagged: [MediaAsset] = []
        var log: [String] = []
    }

    static func plan(_ a: Automation, model: AppModel) -> Plan {
        var p = Plan()
        switch a.trigger {
        case "folder":
            guard !a.folderPath.isEmpty, FileManager.default.fileExists(atPath: a.folderPath) else {
                p.log.append("The watched folder is missing: \(a.folderPath.isEmpty ? "none chosen" : a.folderPath).")
                return p
            }
            let scan = MediaScanner.scan([URL(fileURLWithPath: a.folderPath)])
            let known = Set(((try? model.context.fetch(FetchDescriptor<MediaAsset>())) ?? []).map(\.sourcePath))
            p.newFiles = scan.files.map(\.url).filter { !known.contains($0.path) }
            p.log.append("Found \(p.newFiles.count) new image\(p.newFiles.count == 1 ? "" : "s") in \(URL(fileURLWithPath: a.folderPath).lastPathComponent).")
        case "tag":
            let all = (try? model.context.fetch(FetchDescriptor<MediaAsset>())) ?? []
            let used = Set(((try? model.context.fetch(FetchDescriptor<Publication>())) ?? []).compactMap(\.assetID))
            p.tagged = all.filter { $0.workspaceID == a.workspaceID && $0.tags.contains { $0.caseInsensitiveCompare(a.tag) == .orderedSame } && !used.contains($0.uuid) }
            p.log.append("Found \(p.tagged.count) image\(p.tagged.count == 1 ? "" : "s") tagged “\(a.tag)” without a post.")
        default:
            let sel = model.assets(model.mediaSelection)
            p.tagged = sel
            p.log.append("Using the \(sel.count) image\(sel.count == 1 ? "" : "s") selected in the Media Library.")
        }
        if !a.presetID.isEmpty, let preset = ExportPreset.builtIn.first(where: { $0.id == a.presetID }) { p.log.append("Would make \(preset.name) variants.") }
        if let t = a.templateID, let tpl = model.templates.first(where: { $0.uuid == t }) { p.log.append("Would apply the “\(tpl.name)” template.") }
        if a.generateCopy { p.log.append(model.textProvider == nil ? "AI copy skipped: no text provider set up." : "Would write titles and descriptions with \(model.textProviderID.displayName).") }
        let acct = model.accounts.first { $0.serverID == a.accountID }
        p.log.append(acct == nil ? "No account chosen: posts would be created without one and need fixing in review."
                                 : "Would queue one post every \(a.everyDays) day\(a.everyDays == 1 ? "" : "s") at \(LocalTime(a.postHour, a.postMinute).label) on \(a.boardName.isEmpty ? "no board" : a.boardName), after the existing queue, for your approval.")
        return p
    }

    static func run(_ a: Automation, model: AppModel, dryRun: Bool) async -> AutomationRun {
        let run = AutomationRun(automationID: a.uuid, dryRun: dryRun)
        model.context.insert(run)
        let plan = plan(a, model: model)
        run.log = plan.log
        defer {
            run.finishedAt = .now
            a.lastRunAt = .now
            try? model.context.save()
        }
        if dryRun { run.outcome = "dry run"; return run }
        var assets = plan.tagged
        if !plan.newFiles.isEmpty {
            let imported = await model.importMedia(plan.newFiles)
            assets += imported
            run.log.append("Imported \(imported.count).")
        }
        guard !assets.isEmpty else { run.outcome = "nothing to do"; return run }
        if let t = a.templateID, let tpl = model.templates.first(where: { $0.uuid == t }) {
            let before = Set(((try? model.context.fetch(FetchDescriptor<MediaAsset>())) ?? []).map(\.uuid))
            await model.studio.applyTemplate(tpl, to: assets, model: model)
            let after = ((try? model.context.fetch(FetchDescriptor<MediaAsset>())) ?? []).filter { !before.contains($0.uuid) }
            run.log.append("Applied “\(tpl.name)” to \(after.count) images.")
            if !after.isEmpty { assets = after }
        }
        if !a.presetID.isEmpty, let preset = ExportPreset.builtIn.first(where: { $0.id == a.presetID }) {
            let made = await model.makeVariants(assets, preset: preset)
            run.log.append("Made \(made.count) \(preset.name) variants.")
        }
        let bulk = BulkSession()
        bulk.runName = a.name
        bulk.presetID = a.presetID.isEmpty ? nil : a.presetID
        bulk.rule = ScheduleRule(timeZoneID: TimeZone.current.identifier, start: LocalDay(.now.addingTimeInterval(86_400), in: .current),
                                 times: [LocalTime(a.postHour, a.postMinute)], everyDays: max(1, a.everyDays))
        let acct = model.accounts.first { $0.serverID == a.accountID }
        let board = model.boards[a.accountID]?.first { $0.id == a.boardID } ?? (a.boardID.isEmpty ? nil : API.Board(id: a.boardID, name: a.boardName, privacy: nil))
        do {
            let made = try bulk.createPosts(model: model, assets: assets, account: acct, board: board)
            run.log.append("Created \(made.count) posts in Needs Review.")
            if a.generateCopy, let provider = model.textProvider {
                var n = 0
                for p in made {
                    let req = CopyRequest(platform: p.platform, productName: p.title, filename: model.asset(p.assetID)?.filename ?? "", link: p.link,
                                          existingTitle: p.title, existingDescription: p.desc, brand: model.brandKit?.voiceForAI)
                    if let (copy, usage) = try? await PostCopyGenerator.generate(req, provider: provider) {
                        p.title = copy.title; p.desc = copy.description; if p.altText.isEmpty { p.altText = copy.altText }
                        model.recordAI(kind: "text", prompt: "Automation copy for \(p.title)", usage: usage, ok: true)
                        n += 1
                    }
                }
                run.log.append("Wrote AI copy for \(n) of \(made.count).")
            }
            run.outcome = "done"
            model.log("Automation “\(a.name)” prepared \(made.count) posts for review", symbol: "bolt")
        } catch {
            run.outcome = "failed"
            run.log.append("Could not schedule: \(error)")
        }
        return run
    }

    /// Called every few minutes while the app is open.
    static func tick(model: AppModel) async {
        let all = ((try? model.context.fetch(FetchDescriptor<Automation>())) ?? []).filter(\.isEnabled)
        let cal = Calendar.current
        for a in all {
            switch a.trigger {
            case "folder":
                if !plan(a, model: model).newFiles.isEmpty { _ = await run(a, model: model, dryRun: false) }
            case "weekly":
                let now = Date.now
                let due = cal.component(.weekday, from: now) == a.weekday && cal.component(.hour, from: now) >= a.hour
                    && !(a.lastRunAt.map { cal.isDate($0, inSameDayAs: now) } ?? false)
                if due { _ = await run(a, model: model, dryRun: false) }
            default: break
            }
        }
    }
}

struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Automation.createdAt) private var all: [Automation]
    @Query(sort: \AutomationRun.startedAt, order: .reverse) private var runs: [AutomationRun]

    private var mine: [Automation] { all.filter { $0.workspaceID == model.workspaceID } }

    static let recipes: [(String, String, String)] = [
        ("Folder → Pinterest queue", "folder", "Import every new image from a folder, resize it for Pinterest, and queue one Pin a day for review."),
        ("Tagged images → daily Pins", "tag", "Take images with a tag and make a daily Pin from each, with its product link."),
        ("Branded graphics for selection", "manual", "Apply a brand template to the selected images and queue them for review."),
        ("Weekly drafts", "weekly", "Every week, turn the newest tagged images into drafts for review."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Automations").font(DS.display(30))
                        Text("A trigger, then steps. Every run ends with posts waiting for your approval; automations never publish on their own.")
                            .foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Menu {
                        ForEach(Self.recipes, id: \.0) { r in Button(r.0) { add(r) } }
                    } label: { Label("New Automation", systemImage: "plus").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.button).buttonStyle(PrimaryButtonStyle()).menuIndicator(.hidden).fixedSize()
                }
                if mine.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.lg)], spacing: Space.lg) {
                        ForEach(Self.recipes, id: \.0) { r in
                            VStack(alignment: .leading, spacing: Space.sm) {
                                Image(systemName: "bolt").foregroundStyle(DS.accent)
                                Text(r.0).font(DS.bodyMedium)
                                Text(r.2).font(DS.small).foregroundStyle(DS.text2)
                                Button("Use this") { add(r) }.buttonStyle(LinkButtonStyle())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                    }
                }
                ForEach(mine) { a in
                    HStack(alignment: .top, spacing: Space.lg) {
                        Image(systemName: a.trigger == "folder" ? "folder" : a.trigger == "tag" ? "tag" : a.trigger == "weekly" ? "calendar" : "hand.tap")
                            .foregroundStyle(DS.accent).frame(width: 36, height: 36).background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(a.name).font(DS.bodyMedium)
                            Text(AutomationEngine.plan(a, model: model).log.joined(separator: " ")).font(DS.small).foregroundStyle(DS.text2).lineLimit(3)
                            if let last = runs.first(where: { $0.automationID == a.uuid }) {
                                Text("Last run \(last.startedAt.formatted(.relative(presentation: .named))) · \(last.outcome)").font(DS.caption).foregroundStyle(DS.text3)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { a.isEnabled }, set: { a.isEnabled = $0; try? model.context.save() }))
                            .toggleStyle(SFToggleStyle()).labelsHidden().fixedSize()
                            .disabled(a.trigger == "manual")
                            .help(a.trigger == "manual" ? "Manual automations run when you press Run" : "Run automatically while SocialForge is open")
                    }
                    .card(padding: Space.lg, selected: model.automationSelection == a.uuid)
                    .onTapGesture { model.automationSelection = a.uuid }
                    .contextMenu { Button("Delete", role: .destructive) { model.context.delete(a); try? model.context.save() } }
                }
                if !runs.isEmpty {
                    Text("Activity").font(.system(size: 15, weight: .semibold))
                    ForEach(runs.filter { r in mine.contains { $0.uuid == r.automationID } }.prefix(10)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(mine.first { $0.uuid == r.automationID }?.name ?? "").font(DS.bodyMedium)
                                Text(r.dryRun ? "Dry run" : r.outcome.capitalized).font(DS.small).foregroundStyle(r.outcome == "failed" ? DS.red : DS.text2)
                                Spacer()
                                Text(r.startedAt.formatted(date: .abbreviated, time: .shortened)).font(DS.small).foregroundStyle(DS.text3)
                            }
                            ForEach(r.log, id: \.self) { Text("· " + $0).font(DS.small).foregroundStyle(DS.text2) }
                        }
                        .card(padding: Space.md)
                    }
                }
            }
            .padding(Space.xxl)
        }
    }

    private func add(_ r: (String, String, String)) {
        guard let ws = model.workspaceID else { return }
        let a = Automation(workspaceID: ws, name: r.0)
        a.trigger = r.1
        a.presetID = "pinterest-2x3"
        a.tag = r.1 == "tag" || r.1 == "weekly" ? "Holiday" : ""
        if let pin = model.accounts.first(where: { $0.platform == "pinterest" }) {
            a.accountID = pin.serverID
            if let b = model.boards[pin.serverID]?.first { a.boardID = b.id; a.boardName = b.name }
        }
        if r.1 == "manual" { a.templateID = model.templates.first?.uuid }
        model.context.insert(a)
        try? model.context.save()
        model.automationSelection = a.uuid
    }
}

struct AutomationInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var all: [Automation]

    var body: some View {
        if let a = all.first(where: { $0.uuid == model.automationSelection }) {
            AutomationEditor(automation: a)
        } else {
            VStack(spacing: 0) {
                PanelHeader(title: "Automation")
                Divider().overlay(DS.stroke)
                EmptyState(symbol: "bolt", title: "No automation selected", message: "Pick one to edit its trigger and steps, preview it, or run it.")
            }
        }
    }
}

struct AutomationEditor: View {
    @Bindable var automation: Automation
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var preview: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Automation") { Text(automation.isEnabled ? "On" : "Off") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("When")
                    TextField("Name", text: $automation.name).fieldStyle()
                    Picker("Trigger", selection: $automation.trigger) {
                        Text("New file in a folder").tag("folder")
                        Text("Images with a tag").tag("tag")
                        Text("Every week").tag("weekly")
                        Text("When I press Run").tag("manual")
                    }
                    .font(DS.body)
                    if automation.trigger == "folder" {
                        HStack {
                            Text(automation.folderPath.isEmpty ? "No folder" : URL(fileURLWithPath: automation.folderPath).lastPathComponent).font(DS.body).lineLimit(1)
                            Spacer()
                            Button("Choose…") {
                                let p = NSOpenPanel()
                                p.canChooseDirectories = true
                                p.canChooseFiles = false
                                if p.runModal() == .OK, let u = p.url { automation.folderPath = u.path }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Text("Checked every few minutes while SocialForge is open. Files are copied in; the folder is never changed.").font(DS.caption).foregroundStyle(DS.text3)
                    }
                    if automation.trigger == "tag" || automation.trigger == "weekly" {
                        TextField("Tag", text: $automation.tag).fieldStyle()
                    }
                    if automation.trigger == "weekly" {
                        Picker("Day", selection: $automation.weekday) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                        Stepper("At \(automation.hour):00", value: $automation.hour, in: 0...23)
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Then")
                    Picker("Resize", selection: $automation.presetID) {
                        Text("Keep original").tag("")
                        ForEach(ExportPreset.builtIn) { Text($0.name).tag($0.id) }
                    }
                    Picker("Brand template", selection: $automation.templateID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.templates) { Text($0.name).tag(UUID?.some($0.uuid)) }
                    }
                    Toggle("Write titles and descriptions with AI", isOn: $automation.generateCopy).toggleStyle(SFToggleStyle())
                    Picker("Account", selection: $automation.accountID) {
                        Text("None").tag("")
                        ForEach(model.accounts.filter { $0.platform == "pinterest" }) { Text($0.name).tag($0.serverID) }
                    }
                    Picker("Board", selection: Binding(get: { automation.boardID }, set: { id in
                        automation.boardID = id
                        automation.boardName = model.boards[automation.accountID]?.first { $0.id == id }?.name ?? ""
                    })) {
                        Text("None").tag("")
                        ForEach(model.boards[automation.accountID] ?? []) { Text($0.name).tag($0.id) }
                    }
                    Stepper("Every \(automation.everyDays) day\(automation.everyDays == 1 ? "" : "s")", value: $automation.everyDays, in: 1...30)
                    Stepper("At \(LocalTime(automation.postHour, automation.postMinute).label)", value: $automation.postHour, in: 0...23)
                    Label("Posts wait in Needs Review. You approve before anything publishes.", systemImage: "person.badge.shield.checkmark")
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                .font(DS.body)
                if !preview.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        SectionLabel("Dry run")
                        ForEach(preview, id: \.self) { Text("· " + $0).font(DS.small).foregroundStyle(DS.textBody) }
                    }
                    .card(padding: Space.md)
                }
            }
            Divider().overlay(DS.stroke)
            HStack(spacing: Space.sm) {
                Button("Dry run") { preview = AutomationEngine.plan(automation, model: model).log }.buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Button(running ? "Running…" : "Run now") {
                    running = true
                    Task {
                        let r = await AutomationEngine.run(automation, model: model, dryRun: false)
                        preview = r.log
                        running = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(running)
            }
            .padding(Space.xl)
        }
        .onChange(of: automation.uuid) { preview = [] }
        .onDisappear { try? model.context.save() }
    }
}

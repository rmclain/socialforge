import SwiftData
import SwiftUI
import SocialForgeKit

/// "Schedule these 20 Pins over the next month": AI turns the request into a
/// typed plan of SocialForge tools. Nothing runs until you press Run, and
/// approving or publishing needs its own tick.
struct CommandPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var plan: CommandPlan?
    @State private var planning = false
    @State private var running = false
    @State private var allowApproval = false
    @State private var results: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(DS.accent)
                Text("Ask SocialForge").font(DS.display(24))
                Spacer()
                Text(model.textProvider == nil ? "No text provider" : model.textProviderID.displayName).font(DS.small).foregroundStyle(DS.text2)
            }
            TextField("Schedule these 20 Pins over the next month at 9 AM", text: $request, axis: .vertical)
                .lineLimit(2...4).fieldStyle().onSubmit { Task { await makePlan() } }
            Text("Context: \(model.mediaSelection.count) selected images, \(model.workspacePublications.filter { $0.status == .needsReview }.count) posts in review, \(model.accounts.count) accounts.")
                .font(DS.small).foregroundStyle(DS.text2)
            if model.textProvider == nil {
                Label("Add a text provider in Settings > AI Providers to plan with AI.", systemImage: "exclamationmark.triangle").font(DS.small).foregroundStyle(DS.amber)
            }
            if let error { Text(error).font(DS.small).foregroundStyle(DS.red) }
            if let plan {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Plan · \(plan.actions.count) step\(plan.actions.count == 1 ? "" : "s")")
                    ForEach(Array(plan.actions.enumerated()), id: \.element.id) { i, a in
                        HStack(alignment: .top, spacing: Space.md) {
                            Text("\(i + 1)").font(DS.bodyMedium).foregroundStyle(DS.text3).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.summary).font(DS.body)
                                Text(a.tool + (a.args.isEmpty ? "" : " · " + a.args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
                                    .font(DS.mono).foregroundStyle(DS.text3).lineLimit(2)
                            }
                            Spacer()
                            if a.requiresApproval { Text("Needs approval").font(DS.caption).foregroundStyle(DS.amber) }
                        }
                    }
                    ForEach(plan.missing, id: \.self) { Label("Missing: \($0)", systemImage: "questionmark.circle").font(DS.small).foregroundStyle(DS.amber) }
                    ForEach(plan.rejected, id: \.self) { Label("Not allowed, skipped: \($0)", systemImage: "hand.raised").font(DS.small).foregroundStyle(DS.red) }
                    if plan.actions.contains(where: \.requiresApproval) {
                        Toggle("I approve the steps marked “Needs approval”", isOn: $allowApproval).toggleStyle(SFToggleStyle()).font(DS.body)
                    }
                }
                .card()
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Results")
                    ForEach(results, id: \.self) { Text("· " + $0).font(DS.small).foregroundStyle(DS.textBody) }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                if plan == nil || plan?.actions.isEmpty == true {
                    Button(planning ? "Planning…" : "Plan") { Task { await makePlan() } }.buttonStyle(PrimaryButtonStyle())
                        .disabled(request.isEmpty || planning || model.textProvider == nil).keyboardShortcut(.defaultAction)
                } else {
                    Button("Re-plan") { plan = nil; results = []; allowApproval = false }.buttonStyle(SecondaryButtonStyle())
                    Button(running ? "Running…" : "Run") { Task { await execute() } }.buttonStyle(PrimaryButtonStyle())
                        .disabled(running).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 600)
        .background(DS.panel)
        .onAppear { request = model.aiStudio.pendingCommand; model.aiStudio.pendingCommand = "" }
    }

    private func makePlan() async {
        guard let provider = model.textProvider, !request.isEmpty else { return }
        planning = true
        error = nil
        allowApproval = false
        defer { planning = false }
        let context: [String: String] = [
            "selected_images": "\(model.mediaSelection.count)",
            "posts_in_review": "\(model.workspacePublications.filter { $0.status == .needsReview }.count)",
            "accounts": model.accounts.map { "\($0.name) (\($0.platform))" }.joined(separator: "; "),
            "boards": model.accounts.flatMap { model.boards[$0.serverID] ?? [] }.map(\.name).joined(separator: "; "),
            "templates": model.templates.map(\.name).joined(separator: "; "),
            "presets": ExportPreset.builtIn.map(\.id).joined(separator: ", "),
            "today": Date.now.formatted(date: .complete, time: .omitted),
        ]
        let (system, user) = CommandPlanner.prompt(request: request, context: context)
        do {
            let r = try await provider.complete(system: system, user: user, maxTokens: 1200)
            plan = try CommandPlanner.parse(r.text)
            model.recordAI(kind: "plan", prompt: request, usage: r.usage, ok: true)
        } catch {
            self.error = error.localizedDescription
            model.recordAI(kind: "plan", prompt: request, usage: nil, ok: false, detail: error.localizedDescription)
        }
    }

    /// Runs each allowed step with the same functions the buttons use.
    private func execute() async {
        guard let plan else { return }
        running = true
        defer { running = false }
        results = []
        var planScopeIDs: Set<UUID> = []
        for a in plan.actions {
            if a.requiresApproval && !allowApproval { results.append("Skipped “\(a.summary)”: not approved."); continue }
            results.append(await ToolRunner.run(a, model: model, scopePostIDs: &planScopeIDs))
        }
    }
}

/// The only things the assistant can do. Each maps to an existing app function.
@MainActor
enum ToolRunner {
    static func run(_ a: PlannedAction, model: AppModel, scopePostIDs: inout Set<UUID>) async -> String {
        let args = a.args
        let mine: [MediaAsset] = {
            guard let wsID = model.workspaceID else { return [] }
            return (try? model.context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.workspaceID == wsID }))) ?? []
        }()
        switch a.tool {
        case "list_media":
            return "The library has \(mine.count) items; \(model.mediaSelection.count) selected."
        case "select_media":
            let q = (args["tag"] ?? args["query"] ?? "").lowercased()
            let hits = mine.filter { q.isEmpty || $0.tags.contains { $0.lowercased() == q } || $0.filename.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.collection.lowercased().contains(q) }
            model.mediaSelection = Set(hits.map(\.uuid))
            return "Selected \(hits.count) images."
        case "transform_media":
            let key = (args["preset"] ?? "").lowercased()
            guard let preset = ExportPreset.builtIn.first(where: { $0.id == key || $0.name.lowercased().contains(key) || (key.contains("pin") && $0.id == "pinterest-2x3") }) else {
                return "Unknown preset “\(key)”."
            }
            let made = await model.makeVariants(model.assets(model.mediaSelection), preset: preset)
            return "Made \(made.count) \(preset.name) variants."
        case "apply_template":
            let name = (args["template"] ?? "").lowercased()
            guard let t = model.templates.first(where: { $0.name.lowercased().contains(name) }) ?? (name.isEmpty ? model.templates.first : nil) else {
                return "No template named “\(name)”."
            }
            await model.studio.applyTemplate(t, to: model.assets(model.mediaSelection), model: model)
            return "Applied “\(t.name)”."
        case "create_posts", "schedule_posts":
            // Prevent duplicate post creation if a plan contains both create_posts and schedule_posts.
            if a.tool == "schedule_posts", !scopePostIDs.isEmpty {
                let bulk = model.bulk
                if let start = args["start"].flatMap({ ISO8601.parse($0 + "T12:00:00Z") ?? ISO8601.parse($0) }) { bulk.rule.start = LocalDay(start, in: .current) }
                if let t = args["time"], let time = parseTime(t) { bulk.rule.times = [time] }
                if let e = args["every_days"].flatMap(Int.init) { bulk.rule.everyDays = max(1, e); bulk.rule.everyHours = nil }
                if args["skip_weekends"] == "true" { bulk.skipWeekends = true }
                let created = model.workspacePublications.filter { scopePostIDs.contains($0.uuid) }.sorted { $0.scheduledAt < $1.scheduledAt }
                let slots = (try? ScheduleBuilder.slots(bulk.rule, count: created.count)) ?? []
                for (p, s) in zip(created, slots) {
                    p.scheduledAt = s.instant
                    p.timeZoneID = bulk.rule.timeZoneID
                    p.updatedAt = .now
                }
                try? model.context.save()
                return "Updated schedule for \(created.count) newly created posts."
            }
            let bulk = model.bulk
            let acct = model.accounts.first { a in args["account"].map { a.name.lowercased().contains($0.lowercased()) || a.platform.lowercased() == $0.lowercased() } ?? true }
            let board = acct.flatMap { a in model.boards[a.serverID]?.first { b in args["board"].map { b.name.lowercased().contains($0.lowercased()) } ?? true } }
            if let start = args["start"].flatMap({ ISO8601.parse($0 + "T12:00:00Z") ?? ISO8601.parse($0) }) { bulk.rule.start = LocalDay(start, in: .current) }
            if let t = args["time"], let time = parseTime(t) { bulk.rule.times = [time] }
            if let e = args["every_days"].flatMap(Int.init) { bulk.rule.everyDays = max(1, e); bulk.rule.everyHours = nil }
            if args["skip_weekends"] == "true" { bulk.skipWeekends = true }
            let assets = mine.filter { model.mediaSelection.contains($0.uuid) }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            guard !assets.isEmpty else { return "No images selected to make posts from." }
            bulk.assetIDs = assets.map(\.uuid)
            bulk.rematch(assets: assets)
            do {
                let made = try bulk.createPosts(model: model, assets: assets, account: acct, board: board)
                scopePostIDs.formUnion(made.map(\.uuid))
                bulk.assetIDs = []
                return "Created \(made.count) posts in Needs Review, starting \(bulk.rule.start.formatted) at \(bulk.rule.times.map(\.label).joined(separator: ", "))."
            } catch {
                return "Could not schedule: \(error)"
            }
        case "generate_copy":
            guard let provider = model.textProvider else { return "No text provider." }
            let posts = model.workspacePublications.filter {
                $0.status == .needsReview && (scopePostIDs.isEmpty || scopePostIDs.contains($0.uuid))
            }
            var n = 0
            for p in posts {
                let req = CopyRequest(platform: p.platform, productName: p.title, filename: model.asset(p.assetID)?.filename ?? "", link: p.link,
                                      existingTitle: p.title, existingDescription: p.desc, brand: model.brandKit?.voiceForAI)
                if let (copy, usage) = try? await PostCopyGenerator.generate(req, provider: provider) {
                    p.title = copy.title; p.desc = copy.description
                    model.recordAI(kind: "text", prompt: "Assistant copy", usage: usage, ok: true)
                    n += 1
                }
            }
            try? model.context.save()
            return "Wrote copy for \(n) posts in review."
        case "validate_posts":
            let posts = model.workspacePublications.filter {
                $0.status.isLocal && (scopePostIDs.isEmpty || scopePostIDs.contains($0.uuid))
            }
            let bad = posts.filter { $0.hasErrors(model: model) }
            return "\(posts.count - bad.count) of \(posts.count) posts are ready; \(bad.count) have problems."
        case "approve_posts":
            let ok = model.workspacePublications.filter {
                $0.status == .needsReview && (scopePostIDs.isEmpty || scopePostIDs.contains($0.uuid)) && !$0.hasErrors(model: model)
            }
            for p in ok {
                p.status = .approved
            }
            try? model.context.save()
            return "Approved \(ok.count) posts without problems."
        case "publish_approved_posts":
            let ok = model.workspacePublications.filter {
                $0.status == .approved && (scopePostIDs.isEmpty || scopePostIDs.contains($0.uuid))
            }
            let r = await model.activate(ok)
            return "Scheduled \(r.sent) approved posts." + (r.failed.isEmpty ? "" : " Problems: " + r.failed.joined(separator: "; "))
        default:
            return "Skipped unknown step “\(a.tool)”."
        }
    }

    static func parseTime(_ s: String) -> LocalTime? {
        let lower = s.lowercased().replacingOccurrences(of: " ", with: "")
        let pm = lower.hasSuffix("pm"), am = lower.hasSuffix("am")
        let digits = lower.replacingOccurrences(of: "am", with: "").replacingOccurrences(of: "pm", with: "")
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard var h = parts.first, (0...23).contains(h) else { return nil }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        return LocalTime(h, parts.count > 1 ? parts[1] : 0)
    }
}

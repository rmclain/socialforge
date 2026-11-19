import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

/// AI Studio state: the prompt, options, the running batch, and results.
@Observable
final class AIStudioModel {
    var prompt = "Warm minimal product backdrop, linen tablecloth on oak, soft window light from the left, winter morning, negative space in the top third for a headline."
    var aspect = "2:3"
    var batch = 4
    var seed = Int.random(in: 1...99_999)
    var useBrandStyle = true
    var checkpoints: [String] = []
    var checkpoint: String?
    var workflowID: UUID?
    var running: Task<Void, Never>?
    var progress: (done: Int, total: Int, step: Int, steps: Int)?
    var resultIDs: [UUID] = []
    var selectedResult: UUID?
    var lastError: String?
    var lastJobID: UUID?
    /// Set by Creative Studio: offer "Use in Studio" prominently.
    var sendToStudio = false
    var referenceAssetID: UUID?
    /// The command panel's starting text (from the automation bar).
    var pendingCommand = ""
    var verified: [AIProviderID: String] = [:]

    static let aspects: [(String, Int, Int)] = [("2:3", 832, 1248), ("1:1", 1024, 1024), ("4:5", 896, 1120), ("16:9", 1344, 768), ("9:16", 768, 1344)]

    var size: (Int, Int) {
        let a = Self.aspects.first { $0.0 == aspect } ?? Self.aspects[0]
        return (a.1, a.2)
    }

    @MainActor
    func generate(model: AppModel) {
        guard running == nil, let ws = model.workspaceID else { return }
        var finalPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if useBrandStyle, let style = model.brandKit?.imageStyle, !style.isEmpty { finalPrompt += ". Style: \(style)" }
        // Typography is a design operation: the model only makes the background.
        finalPrompt += ". No text, no letters, no logos, no watermark."
        let provider = model.imageProviderID
        let job = AIJob(workspaceID: ws, provider: provider == .comfyui ? "ComfyUI" : provider.displayName, kind: "image", prompt: prompt)
        job.seed = seed
        model.context.insert(job)
        try? model.context.save()
        lastJobID = job.uuid
        lastError = nil
        resultIDs = []
        let count = batch, (w, h) = size, baseSeed = seed
        progress = (0, count, 0, 0)
        running = Task { @MainActor in
            defer { running = nil; progress = nil; seed = Int.random(in: 1...99_999) }
            do {
                var datas: [Data] = []
                if provider == .comfyui {
                    guard let client = model.comfyClient else { throw AIError.notConfigured("Set the ComfyUI address in Settings > ComfyUI.") }
                    let workflow = try comfyWorkflow(model: model)
                    for i in 0..<count {
                        try Task.checkCancellation()
                        let graph = workflow.applying(prompt: finalPrompt, negative: "text, letters, words, watermark, logo, blurry", seed: baseSeed + i,
                                                      width: w, height: h, batch: 1, checkpoint: checkpoint)
                        let clientID = UUID().uuidString
                        let watcher = Task { @MainActor in
                            for await p in client.progress(clientID: clientID) {
                                progress = (i, count, p.value, p.max)
                                job.progress = (Double(i) + Double(p.value) / Double(max(1, p.max))) / Double(count)
                            }
                        }
                        let images = try await client.run(graph: graph, clientID: clientID)
                        watcher.cancel()
                        datas += images
                        try await importImages(images, model: model, job: job, seed: baseSeed + i)
                        progress = (i + 1, count, 0, 0)
                    }
                } else {
                    guard let config = model.aiConfigs[provider], let p = makeImageProvider(config, apiKey: model.aiKey(provider)) else {
                        throw AIError.notConfigured("\(provider.displayName) cannot make images with the current settings.")
                    }
                    let (images, usage) = try await p.generate(prompt: finalPrompt, width: w, height: h, count: count)
                    job.inputTokens = usage.inputTokens ?? 0
                    job.outputTokens = usage.outputTokens ?? 0
                    datas = images
                    try await importImages(images, model: model, job: job, seed: baseSeed)
                }
                job.status = "done"
                job.detail = "\(datas.count) image\(datas.count == 1 ? "" : "s")"
                model.log("AI made \(datas.count) backgrounds with \(job.provider)", symbol: "sparkles")
            } catch is CancellationError {
                job.status = "canceled"
            } catch {
                job.status = "failed"
                job.detail = error.localizedDescription
                lastError = error.localizedDescription
            }
            job.finishedAt = .now
            try? model.context.save()
        }
    }

    @MainActor
    func cancel() { running?.cancel() }

    @MainActor
    private func importImages(_ images: [Data], model: AppModel, job: AIJob, seed: Int) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sf-ai-\(job.uuid.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, d) in images.enumerated() {
            let u = dir.appending(path: "ai-\(seed)-\(i).png")
            try d.write(to: u)
            urls.append(u)
        }
        let added = await model.importMedia(urls)
        for a in added {
            a.collection = "AI backgrounds"
            a.tags = ["ai", job.provider.lowercased()]
            a.notes = "\(job.provider) · seed \(seed) · \(job.prompt)"
        }
        job.outputAssetIDs += added.map(\.uuid)
        resultIDs += added.map(\.uuid)
        try? model.context.save()
    }

    @MainActor
    func comfyWorkflow(model: AppModel) throws -> ComfyWorkflow {
        if let id = workflowID, let rec = (try? model.context.fetch(FetchDescriptor<ComfyWorkflowRecord>(predicate: #Predicate { $0.uuid == id })))?.first {
            let wf = try ComfyWorkflow.parse(name: rec.name, json: rec.json)
            if !wf.unmappedRequired.isEmpty { throw AIError.badResponse("“\(rec.name)” has no prompt input SocialForge can fill.") }
            return wf
        }
        guard let ckpt = checkpoint ?? checkpoints.first else {
            throw AIError.notConfigured("ComfyUI reported no checkpoints. Add a model to ComfyUI, or import your own workflow.")
        }
        return ComfyWorkflow.textToImage(checkpoint: ckpt)
    }

    @MainActor
    func loadCheckpoints(model: AppModel) async {
        guard let client = model.comfyClient else { return }
        if let list = try? await client.checkpoints() {
            checkpoints = list
            if checkpoint == nil { checkpoint = list.first }
        }
    }
}

extension AppModel {
    /// Keeps a record of every AI request: provider, tokens, and outcome. Never stores keys or full responses.
    func recordAI(kind: String, prompt: String, usage: AIUsage?, ok: Bool, detail: String = "") {
        guard let workspaceID else { return }
        let j = AIJob(workspaceID: workspaceID, provider: textProviderID.displayName, kind: kind, prompt: String(prompt.prefix(200)))
        j.status = ok ? "done" : "failed"
        j.detail = detail
        j.inputTokens = usage?.inputTokens ?? 0
        j.outputTokens = usage?.outputTokens ?? 0
        j.finishedAt = .now
        context.insert(j)
        try? context.save()
    }
}

// MARK: - Page

struct AIStudioView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \AIJob.createdAt, order: .reverse) private var allJobs: [AIJob]
    @Query(sort: \ComfyWorkflowRecord.createdAt) private var workflows: [ComfyWorkflowRecord]

    private var ai: AIStudioModel { model.aiStudio }

    var body: some View {
        @Bindable var ai = model.aiStudio
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("Describe the background. Leave room for your headline; text is added later as real type.", text: $ai.prompt, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 16)).lineLimit(2...5)
                    FlowLayout(spacing: Space.sm) {
                        chipMenu("Provider", model.imageProviderID == .comfyui ? "ComfyUI · \(model.comfyIsLocal ? "Local" : "Remote")" : model.imageProviderID.displayName) {
                            ForEach(AIProviderID.allCases.filter(\.supportsImage), id: \.self) { p in Button(p.displayName) { model.imageProviderID = p } }
                        }
                        if model.imageProviderID == .comfyui {
                            chipMenu("Workflow", workflows.first { $0.uuid == ai.workflowID }?.name ?? "Text to image") {
                                Button("Text to image (built in)") { ai.workflowID = nil }
                                ForEach(workflows) { w in Button(w.name) { ai.workflowID = w.uuid } }
                                Divider()
                                Button("Import Workflow (API format)…") { ComfyWorkflowIO.importWorkflow(model: model) }
                            }
                            if ai.workflowID == nil {
                                chipMenu("Model", ai.checkpoint ?? (ai.checkpoints.isEmpty ? "—" : ai.checkpoints[0])) {
                                    ForEach(ai.checkpoints, id: \.self) { c in Button(c) { ai.checkpoint = c } }
                                    Button("Reload from ComfyUI") { Task { await ai.loadCheckpoints(model: model) } }
                                }
                            }
                        }
                        chipMenu("Aspect", ai.aspect.replacingOccurrences(of: ":", with: " : ")) {
                            ForEach(AIStudioModel.aspects, id: \.0) { a in Button("\(a.0) · \(a.1) × \(a.2)") { ai.aspect = a.0 } }
                        }
                        chipMenu("Batch", "\(ai.batch)") { ForEach([1, 2, 4, 8], id: \.self) { n in Button("\(n)") { ai.batch = n } } }
                        if let kit = model.brandKit {
                            Button { ai.useBrandStyle.toggle() } label: { chipLabel("Style", ai.useBrandStyle ? kit.name : "None") }.buttonStyle(.plain)
                                .help(kit.imageStyle.isEmpty ? "Add a preferred image style to the brand kit" : "Adds: \(kit.imageStyle)")
                        }
                    }
                    HStack(spacing: Space.sm) {
                        Spacer()
                        if ai.running != nil {
                            Button("Stop") { ai.cancel() }.buttonStyle(SecondaryButtonStyle())
                        }
                        Button { ai.generate(model: model) } label: { Label("Generate", systemImage: "sparkles") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(ai.running != nil || ai.prompt.isEmpty || !model.isConfigured(model.imageProviderID))
                            .keyboardShortcut(.return, modifiers: .command)
                            .help(model.isConfigured(model.imageProviderID) ? "Generate backgrounds (Command-Return)" : "Set up \(model.imageProviderID.displayName) first")
                    }
                    if !model.isConfigured(model.imageProviderID) {
                        Label(model.imageProviderID == .comfyui ? "ComfyUI is not reachable at \(model.comfyURLString). Start it, or change the address in Settings > ComfyUI."
                              : "Add an API key for \(model.imageProviderID.displayName) in Settings > AI Providers.", systemImage: "exclamationmark.triangle")
                            .font(DS.small).foregroundStyle(DS.amber)
                    }
                    if let e = ai.lastError { Text(e).font(DS.small).foregroundStyle(DS.red) }
                }
                .card(padding: Space.xl)

                results

                history
            }
            .padding(Space.xxl)
        }
        .task {
            if model.comfyState == .unknown { await model.checkComfy() }
            if model.comfyState.isConnected && ai.checkpoints.isEmpty { await ai.loadCheckpoints(model: model) }
        }
    }

    @ViewBuilder
    private var results: some View {
        let job = allJobs.first { $0.uuid == ai.lastJobID }
        let ids = ai.resultIDs.isEmpty ? (job?.outputAssetIDs ?? []) : ai.resultIDs
        let assets = model.assets(ids).sorted { a, b in (ids.firstIndex(of: a.uuid) ?? 0) < (ids.firstIndex(of: b.uuid) ?? 0) }
        if ai.running != nil || !assets.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Text("Batch").font(.system(size: 15, weight: .semibold))
                    if let p = ai.progress {
                        Text("\(job?.provider ?? "") · \(p.done) of \(p.total) complete").foregroundStyle(DS.text2)
                    } else {
                        Text("\(job?.provider ?? "") · \(assets.count) image\(assets.count == 1 ? "" : "s")").foregroundStyle(DS.text2)
                    }
                    Spacer()
                    if let sel = ai.selectedResult, let a = model.asset(sel) {
                        Button("Use in Creative Studio") {
                            if model.studio.document != nil, ai.sendToStudio {
                                model.studio.change { $0 = $0.hasPhotoSlot ? $0.withPhoto(a.storedPath) : $0 }
                            } else {
                                model.studio.openNew(model: model, photoPath: a.storedPath)
                            }
                            ai.sendToStudio = false
                            model.page = .studio
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.lg), count: 4), spacing: Space.lg) {
                    ForEach(assets) { a in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Thumbnail(path: a.storedPath, maxPixel: 600)
                                .aspectRatio(CGFloat(a.width) / CGFloat(max(1, a.height)), contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(ai.selectedResult == a.uuid ? DS.accentFill : .clear, lineWidth: 2))
                                .onTapGesture { ai.selectedResult = a.uuid }
                            Text(a.notes.components(separatedBy: " · ").dropFirst().first ?? "").font(DS.mono).foregroundStyle(DS.text3)
                        }
                    }
                    if let p = ai.progress {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Spacer()
                            Text(p.steps > 0 ? "Sampling · step \(p.step) / \(p.steps)" : "Waiting for the server…").font(DS.small).foregroundStyle(DS.textBody)
                            ThinProgress(segments: [(p.steps > 0 ? Double(p.step) / Double(p.steps) : 0.05, DS.accentFill)])
                        }
                        .padding(Space.md)
                        .aspectRatio(CGFloat(ai.size.0) / CGFloat(ai.size.1), contentMode: .fit)
                        .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
                    }
                }
            }
        }
    }

    private var history: some View {
        let jobs = allJobs.filter { $0.workspaceID == model.workspaceID }.prefix(12)
        return VStack(alignment: .leading, spacing: Space.md) {
            Text("History").font(.system(size: 15, weight: .semibold))
            if jobs.isEmpty { Text("Generated backgrounds and AI copy show up here, with token counts.").foregroundStyle(DS.text2) }
            ForEach(Array(jobs)) { j in
                HStack(spacing: Space.md) {
                    Image(systemName: j.kind == "image" ? "photo" : j.kind == "plan" ? "list.bullet.rectangle" : "text.alignleft").foregroundStyle(DS.text2).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(j.prompt).font(DS.body).lineLimit(1)
                        Text([j.provider, j.createdAt.formatted(.relative(presentation: .named)), j.inputTokens + j.outputTokens > 0 ? "\(j.inputTokens) in / \(j.outputTokens) out tokens" : "", j.detail]
                            .filter { !$0.isEmpty }.joined(separator: " · ")).font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
                    }
                    Spacer()
                    StatusDot(text: j.status.capitalized, color: j.status == "done" ? DS.green : j.status == "failed" ? DS.red : DS.text2)
                    if j.kind == "image", !j.outputAssetIDs.isEmpty {
                        Button("Show") { ai.lastJobID = j.uuid; ai.resultIDs = j.outputAssetIDs }.buttonStyle(LinkButtonStyle())
                    }
                }
                Divider().overlay(DS.stroke)
            }
        }
    }

    private func chipMenu<C: View>(_ key: String, _ value: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: { chipLabel(key, value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func chipLabel(_ key: String, _ value: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(key).foregroundStyle(DS.text2)
            Text(value).foregroundStyle(DS.text)
        }
        .font(DS.body)
        .padding(.horizontal, Space.md).frame(height: 32)
        .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(DS.stroke))
    }
}

enum ComfyWorkflowIO {
    @MainActor
    static func importWorkflow(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a workflow saved from ComfyUI with “Save (API Format)”."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            let wf = try ComfyWorkflow.parse(name: url.deletingPathExtension().lastPathComponent, json: data)
            if !wf.unmappedRequired.isEmpty {
                model.lastError = "SocialForge could not find a prompt text input in “\(wf.name)”. It needs a CLIPTextEncode (or similar) connected to the sampler."
                return
            }
            let rec = ComfyWorkflowRecord(name: wf.name, json: data)
            model.context.insert(rec)
            try? model.context.save()
            model.aiStudio.workflowID = rec.uuid
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

// MARK: - Providers inspector

struct AIProvidersInspector: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ComfyWorkflowRecord.createdAt) private var workflows: [ComfyWorkflowRecord]

    var body: some View {
        let configured = AIProviderID.allCases.filter { model.isConfigured($0) }.count
        VStack(spacing: 0) {
            PanelHeader(title: "AI Providers") { Text("\(configured) configured") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                comfyCard
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Cloud and local providers").padding(.bottom, Space.sm)
                    ForEach(AIProviderID.allCases.filter { $0 != .comfyui }, id: \.self) { p in
                        ProviderRow(id: p)
                        Divider().overlay(DS.stroke)
                    }
                    Button("Manage keys in Settings") { model.settingsTab = .ai; model.page = .settings }.buttonStyle(LinkButtonStyle()).padding(.top, Space.sm)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Routing")
                    HStack {
                        Text("Text").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                        Picker("", selection: Binding(get: { model.textProviderID }, set: { model.textProviderID = $0 })) {
                            ForEach(AIProviderID.allCases.filter(\.supportsText), id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden()
                    }
                    HStack {
                        Text("Images").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                        Picker("", selection: Binding(get: { model.imageProviderID }, set: { model.imageProviderID = $0 })) {
                            ForEach(AIProviderID.allCases.filter(\.supportsImage), id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden()
                    }
                    Text("Backgrounds are made by the image provider; headlines, prices, and logos are always real text and layers in Creative Studio. Images leave this Mac only when you generate with a cloud provider; copy requests send titles, filenames, and links, never images.")
                        .font(DS.small).foregroundStyle(DS.text2)
                        .padding(Space.md).background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                }
            }
        }
    }

    private var comfyCard: some View {
        let ai = model.aiStudio
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: "cpu").foregroundStyle(DS.green).frame(width: 36, height: 36).background(DS.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ComfyUI · \(model.comfyIsLocal ? "Local" : "Remote")").font(DS.bodyMedium)
                    Text(model.comfyURLString).font(DS.mono).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                StatusDot(text: model.comfyState.isConnected ? "Connected" : model.comfyState == .checking ? "Checking" : "Offline", color: model.comfyState.color)
            }
            VStack(spacing: 0) {
                KeyValueRow("Device", model.comfyState.isConnected ? model.comfyState.detail.components(separatedBy: " · ").last ?? "" : "—")
                KeyValueRow("Workflow", workflows.first { $0.uuid == ai.workflowID }?.name ?? "Text to image (built in)")
                KeyValueRow("Models", ai.checkpoints.isEmpty ? "—" : "\(ai.checkpoints.count) checkpoints")
                KeyValueRow("Queue", ai.progress.map { "\($0.done) of \($0.total) running" } ?? "Idle")
            }
            HStack {
                Button("Test") { Task { await model.checkComfy(); await ai.loadCheckpoints(model: model) } }.buttonStyle(SecondaryButtonStyle())
                Button("Import Workflow…") { ComfyWorkflowIO.importWorkflow(model: model) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Space.lg)
        .background(model.comfyState.isConnected ? DS.green.opacity(0.06) : DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(model.comfyState.isConnected ? DS.green.opacity(0.35) : DS.stroke))
    }
}

struct ProviderRow: View {
    let id: AIProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        let configured = model.isConfigured(id)
        let verified = model.aiStudio.verified[id]
        HStack(spacing: Space.md) {
            InitialBadge(text: initials, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.displayName).font(DS.bodyMedium)
                Text(model.aiConfigs[id].map { [$0.textModel, $0.imageModel].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "").font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer()
            if let verified {
                StatusDot(text: verified, color: verified == "Verified" ? DS.green : DS.red)
            } else {
                StatusDot(text: configured ? (id.needsKey ? "Key saved" : "Ready") : "Not set up", color: configured ? DS.amber : DS.text3)
            }
        }
        .padding(.vertical, Space.sm)
        .help(configured ? "Saved, not yet verified with a request. Use Test in Settings." : "Add a key in Settings > AI Providers.")
    }

    private var initials: String {
        switch id {
        case .openai: "OA"
        case .anthropic: "A"
        case .gemini: "G"
        case .openaiCompatible: "L"
        case .comfyui: "C"
        }
    }
}

// MARK: - Generate step in Bulk Publisher

struct GenerateSection: View {
    let publications: [Publication]
    @Environment(AppModel.self) private var model
    @State private var onlyEmpty = true
    @State private var running = false
    @State private var done = 0
    @State private var error: String?

    var body: some View {
        let targets = publications.filter { $0.status.isLocal }
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Generate", trailing: AnyView(Image(systemName: "sparkles").foregroundStyle(DS.accent)))
            if model.textProvider == nil {
                Text("Titles and descriptions come from the CSV or filename. Add a text provider in Settings > AI Providers to write them with AI.")
                    .font(DS.small).foregroundStyle(DS.text2)
                Button("Set Up AI") { model.settingsTab = .ai; model.page = .settings }.buttonStyle(SecondaryButtonStyle())
            } else {
                Toggle("Only fill empty or filename titles", isOn: $onlyEmpty).toggleStyle(SFToggleStyle()).font(DS.body)
                Button(running ? "Writing \(done) of \(targets.count)…" : "Write titles and descriptions for \(targets.count) posts") { Task { await run(targets) } }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(running || targets.isEmpty)
                Text("Uses \(model.textProviderID.displayName) with your brand voice. Sends titles, filenames, and links; never images. You review everything before it publishes.")
                    .font(DS.caption).foregroundStyle(DS.text3)
                if let error { Text(error).font(DS.small).foregroundStyle(DS.red) }
            }
        }
    }

    private func run(_ targets: [Publication]) async {
        guard let provider = model.textProvider else { return }
        running = true
        done = 0
        error = nil
        defer { running = false }
        for p in targets {
            let asset = model.asset(p.assetID)
            let fromFilename = asset.map { BulkSession.titleFromFilename($0.filename) == p.title } ?? false
            if onlyEmpty && !(p.title.isEmpty || fromFilename || p.desc.isEmpty) { done += 1; continue }
            let req = CopyRequest(platform: p.platform, productName: p.title, filename: asset?.filename ?? "", link: p.link,
                                  existingTitle: p.title, existingDescription: p.desc, extra: [:], brand: model.brandKit?.voiceForAI)
            do {
                let (copy, usage) = try await PostCopyGenerator.generate(req, provider: provider)
                if !onlyEmpty || p.title.isEmpty || fromFilename { p.title = copy.title }
                if !onlyEmpty || p.desc.isEmpty {
                    p.desc = copy.description + (copy.hashtags.isEmpty ? "" : "\n\n" + copy.hashtags.prefix(5).map { "#" + $0 }.joined(separator: " "))
                }
                if p.altText.isEmpty { p.altText = copy.altText }
                p.updatedAt = .now
                model.recordAI(kind: "text", prompt: "Copy for \(p.title)", usage: usage, ok: true)
            } catch {
                self.error = error.localizedDescription
                model.recordAI(kind: "text", prompt: "Copy for \(p.title)", usage: nil, ok: false, detail: error.localizedDescription)
                break
            }
            done += 1
        }
        try? model.context.save()
    }
}

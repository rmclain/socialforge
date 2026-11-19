import SwiftUI
import SocialForgeKit

/// The Settings window (Command-Comma): one tab per topic. The sidebar's Settings page shows the same panes.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                ScrollView { SettingsPane(tab: tab).padding(Space.xl) }
                    .frame(width: 600, height: 560)
                    .background(DS.panel)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            switch tab {
            case .general: GeneralSettings()
            case .publishing: PublishingSettings()
            case .ai: AISettings()
            case .comfy: ComfyUISettings()
            case .appearance: AppearanceSettingsPane()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// Settings as a sidebar page.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                PillPicker(options: SettingsTab.allCases, selection: $model.settingsTab) { $0.title }
                SettingsPane(tab: model.settingsTab)
            }
            .padding(Space.xxl)
        }
    }
}

struct SettingsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Status")
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("This Mac").padding(.bottom, Space.xs)
                    KeyValueRow("Publishing", model.publishMode == .mac ? "This Mac" : "Service")
                    KeyValueRow("Background", model.helperService.status == .enabled ? "On" : "Off")
                    KeyValueRow("ComfyUI", model.comfyState.isConnected ? "Connected" : model.comfyState.detail)
                    KeyValueRow("Text AI", model.isConfigured(model.textProviderID) ? model.textProviderID.displayName : "Not set up")
                    KeyValueRow("Image AI", model.isConfigured(model.imageProviderID) ? model.imageProviderID.displayName : "Not set up")
                    KeyValueRow("Library", "\(model.workspaceAssetCount) items")
                }
                Text("Keys and tokens are stored in your login Keychain. Nothing in Settings is sent anywhere until you use it.").font(DS.small).foregroundStyle(DS.text2)
            }
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, publishing, ai, comfy, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .publishing: "Publishing"
        case .ai: "AI Providers"
        case .comfy: "ComfyUI"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .publishing: "paperplane"
        case .ai: "sparkles"
        case .comfy: "cpu"
        case .appearance: "paintpalette"
        }
    }
}

/// A titled settings group in the design's card style.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: Space.md) { content }.frame(maxWidth: .infinity, alignment: .leading).card()
            if let footer { Text(footer).font(DS.small).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Workspace") {
            if let w = model.workspace {
                @Bindable var w = w
                TextField("Name", text: $w.name).fieldStyle()
                TextField("Content guidelines: tone, words to avoid, claims you never make", text: $w.voice, axis: .vertical).lineLimit(2...5).fieldStyle()
            }
            Button("New Workspace…") { model.showNewWorkspace = true }.buttonStyle(SecondaryButtonStyle())
        }
        UpdateSettingsView()
        SettingsGroup(title: "Library", footer: "Imported files are copied here, one folder per content hash. Your originals are never changed.") {
            Text(model.storage.root.path).font(DS.mono).foregroundStyle(DS.text2).textSelection(.enabled).lineLimit(2)
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: model.storage.root, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([model.storage.root])
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

struct PublishingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @AppStorage("pinterest.apiBase") private var apiBase = "https://api.pinterest.com"

    var body: some View {
        @Bindable var model = model
        let _ = model.modeRevision
        SettingsGroup(title: "Publishing", footer: model.publishMode == .mac
                      ? "This Mac publishes approved posts at their times. Nothing posts while the Mac is asleep or off; posts that came due go out when it wakes, marked late in Activity."
                      : "The optional service in services/api keeps tokens and the queue on an always-on host, so posts go out while the Mac sleeps.") {
            PillPicker(options: PublishMode.allCases, selection: Binding(get: { model.publishMode }, set: { model.publishMode = $0 })) { $0.title }
            if model.publishMode == .mac {
                Toggle("Publish while SocialForge is closed", isOn: Binding(
                    get: { model.helperService.status == .enabled || model.helperService.status == .requiresApproval },
                    set: { model.setHelper(enabled: $0) }))
                    .toggleStyle(SFToggleStyle()).font(DS.body)
                Text(model.helperStatusText).font(DS.small).foregroundStyle(DS.text2)
            }
        }
        if model.publishMode == .mac {
            SettingsGroup(title: "Your Pinterest app", footer: "Create an app at developers.pinterest.com and add http://127.0.0.1:8085/pinterest/callback as a redirect URI. The ID, secret, and tokens stay in your Keychain. Live publishing is built but not yet verified against Pinterest.") {
                TextField("App ID", text: $clientID).fieldStyle().onSubmit { Keychain.write("pinterest.clientID", clientID) }
                SecureField("App secret", text: $clientSecret).fieldStyle().onSubmit { Keychain.write("pinterest.clientSecret", clientSecret) }
                PillPicker(options: ["https://api.pinterest.com", "https://api-sandbox.pinterest.com"], selection: $apiBase) { $0.contains("sandbox") ? "Sandbox (Trial access)" : "Production" }
                HStack {
                    Button("Save to Keychain") {
                        Keychain.write("pinterest.clientID", clientID)
                        Keychain.write("pinterest.clientSecret", clientSecret)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Connect Pinterest") {
                        Keychain.write("pinterest.clientID", clientID)
                        Keychain.write("pinterest.clientSecret", clientSecret)
                        Task { await model.connectPinterestOnMac() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)
                }
            }
            .onAppear {
                clientID = Keychain.read("pinterest.clientID") ?? ""
                clientSecret = Keychain.read("pinterest.clientSecret") ?? ""
            }
        } else {
            SettingsGroup(title: "Publishing service", footer: "Run it with `npm run dev:local` in services/api (plain Node and PostgreSQL). The token is stored in your Keychain.") {
                TextField("http://127.0.0.1:8787", text: $model.backendURLString).fieldStyle().onSubmit { Task { await model.checkBackend() } }
                SecureField("Access token", text: $token).fieldStyle().onSubmit { model.token = token }
                HStack {
                    Button("Check") {
                        model.token = token
                        Task {
                            await model.checkBackend()
                            if case .up = model.backendStatus { await model.refreshAccounts() }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    switch model.backendStatus {
                    case .unknown: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .up(let v): StatusDot(text: "Up · version \(v)", color: DS.green)
                    case .down(let why): StatusDot(text: why, color: DS.red)
                    }
                }
            }
        }
    }
}

struct AISettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Routing", footer: "Choose a default provider per task. Headlines, prices, and logos are never rendered by an image model; they stay real text in Creative Studio.") {
            Picker("Text (titles, captions, plans)", selection: Binding(get: { model.textProviderID }, set: { model.textProviderID = $0 })) {
                ForEach(AIProviderID.allCases.filter(\.supportsText), id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Images (backgrounds)", selection: Binding(get: { model.imageProviderID }, set: { model.imageProviderID = $0 })) {
                ForEach(AIProviderID.allCases.filter(\.supportsImage), id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .font(DS.body)
        ForEach(AIProviderID.allCases.filter { $0 != .comfyui }, id: \.self) { id in ProviderSettings(id: id) }
        Text("Keys stay in your Keychain and go only to the provider you chose. Requests send product titles, filenames, links, and your brand voice; images are sent only when you generate with a cloud image provider. Costs are billed by each provider; SocialForge shows token counts, not prices.")
            .font(DS.small).foregroundStyle(DS.text2)
    }
}

struct ProviderSettings: View {
    let id: AIProviderID
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var testing = false

    var body: some View {
        let config = Binding(get: { model.aiConfigs[id] ?? .defaults(for: id) }, set: { model.aiConfigs[id] = $0 })
        SettingsGroup(title: id.displayName) {
            HStack {
                if id.needsKey {
                    SecureField(model.isConfigured(id) ? "Key saved · paste to replace" : "API key", text: $key).fieldStyle()
                        .onSubmit { save() }
                    Button("Save") { save() }.buttonStyle(SecondaryButtonStyle()).disabled(key.isEmpty)
                    if model.isConfigured(id) { Button("Remove") { model.setAIKey(id, ""); model.aiStudio.verified[id] = nil }.buttonStyle(.plain).foregroundStyle(DS.text2) }
                } else {
                    Text("No key needed (a server on your network).").font(DS.body).foregroundStyle(DS.text2)
                }
            }
            HStack {
                Text("Base URL").font(DS.small).foregroundStyle(DS.text2).frame(width: 80, alignment: .leading)
                TextField("", text: config.baseURL).fieldStyle()
            }
            HStack {
                Text("Text model").font(DS.small).foregroundStyle(DS.text2).frame(width: 80, alignment: .leading)
                TextField("", text: config.textModel).fieldStyle()
            }
            if id.supportsImage {
                HStack {
                    Text("Image model").font(DS.small).foregroundStyle(DS.text2).frame(width: 80, alignment: .leading)
                    TextField("", text: config.imageModel).fieldStyle()
                }
            }
            HStack {
                Button(testing ? "Testing…" : "Test") { Task { await test() } }.buttonStyle(SecondaryButtonStyle())
                    .disabled(testing || !model.isConfigured(id))
                if let v = model.aiStudio.verified[id] { StatusDot(text: v, color: v == "Verified" ? DS.green : DS.red) }
                Spacer()
                Button("Reset to defaults") { model.aiConfigs[id] = .defaults(for: id) }.buttonStyle(.plain).foregroundStyle(DS.text2).font(DS.small)
            }
        }
    }

    private func save() {
        model.setAIKey(id, key)
        key = ""
        model.aiStudio.verified[id] = nil
    }

    /// One tiny request to prove the key and model work.
    private func test() async {
        guard let config = model.aiConfigs[id], let p = makeTextProvider(config, apiKey: model.aiKey(id)) else { return }
        testing = true
        defer { testing = false }
        do {
            let r = try await p.complete(system: "Reply with the single word OK.", user: "Say OK.", maxTokens: 8)
            model.aiStudio.verified[id] = r.text.isEmpty ? "Empty answer" : "Verified"
            model.recordAI(kind: "text", prompt: "Connection test (\(id.displayName))", usage: r.usage, ok: true)
        } catch {
            model.aiStudio.verified[id] = error.localizedDescription
        }
    }
}

struct ComfyUISettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("comfy.url") private var url = "http://127.0.0.1:8188"
    @State private var token = ""

    var body: some View {
        SettingsGroup(title: "ComfyUI", footer: "Uses ComfyUI's HTTP and WebSocket API: /system_stats, /object_info, /prompt, /history, /view, /interrupt. Remote servers must use HTTPS; add a token if your server or proxy requires one. Import your own workflows (Save → API Format) in AI Studio.") {
            HStack {
                TextField("http://127.0.0.1:8188", text: $url).fieldStyle().onSubmit { Task { await model.checkComfy() } }
                Button("Test Connection") {
                    Task {
                        await model.checkComfy()
                        await model.aiStudio.loadCheckpoints(model: model)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if let u = URL(string: url), let problem = ComfyUIClient.transportProblem(u) { Text(problem).font(DS.small).foregroundStyle(DS.red) }
            SecureField(Keychain.read("comfy.token")?.isEmpty == false ? "Token saved · paste to replace" : "Optional bearer token", text: $token).fieldStyle()
                .onSubmit { Keychain.write("comfy.token", token); token = "" }
            HStack {
                StatusDot(text: model.comfyState.isConnected ? "Connected · \(model.comfyState.detail)" : model.comfyState.detail, color: model.comfyState.color)
                Spacer()
                if !model.aiStudio.checkpoints.isEmpty { Text("\(model.aiStudio.checkpoints.count) checkpoints").font(DS.small).foregroundStyle(DS.text2) }
            }
        }
    }
}

struct AppearanceSettingsPane: View {
    var body: some View {
        SettingsGroup(title: "Appearance", footer: "SocialForge follows your Mac's light or dark mode. The accent is SocialForge's ember orange from the design.") {
            AppearanceSettings()
        }
    }
}

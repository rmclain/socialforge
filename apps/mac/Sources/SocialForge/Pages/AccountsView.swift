import AppKit
import SwiftData
import SwiftUI
import SocialForgeKit

/// Unified Connections hub: Social Accounts, AI Providers, Media Storage,
/// Automation & Agents, and Publishing Infrastructure, with guided connection
/// wizards and sanitized diagnostics.
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SocialAccount.name) private var allAccounts: [SocialAccount]
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @State private var category: ConnectionCategory = .social
    @State private var refreshing = false
    @State private var wizardPlatform: String?
    @State private var diagnosticReport: ConnectionDiagnosticReport?

    private var accounts: [SocialAccount] { allAccounts.filter { $0.workspaceID == model.workspaceID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                PillPicker(options: ConnectionCategory.allCases, selection: $category) { $0.title }
                switch category {
                case .social:
                    socialSection
                case .aiProvider:
                    aiProvidersSection
                case .mediaStorage:
                    mediaStorageSection
                case .automationAndAgents:
                    agentsSection
                case .publishingInfra:
                    publishingInfraSection
                }
            }
            .padding(Space.xxl)
        }
        .task {
            if !model.oauthRelayURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.oauthRelayCapabilities == nil {
                await model.checkOAuthRelay()
            }
        }
        .sheet(item: Binding(
            get: { wizardPlatform.map(WizardTarget.init(platform:)) },
            set: { wizardPlatform = $0?.platform }
        )) { target in
            ConnectionWizardSheet(platform: target.platform)
        }
        .sheet(item: Binding(
            get: { diagnosticReport.map(DiagnosticBox.init(report:)) },
            set: { diagnosticReport = $0?.report }
        )) { box in
            ConnectionDiagnosticsSheet(report: box.report)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Connections").font(DS.display(30))
                Text("Manage social accounts, AI providers, media storage, MCP agents, and publishing infrastructure from one place. Secrets stay in your macOS Keychain.")
                    .foregroundStyle(DS.text2)
            }
            Spacer()
            Button(refreshing ? "Refreshing…" : "Verify All") {
                refreshing = true
                Task {
                    await model.refreshAccounts()
                    await model.checkComfy()
                    if !model.oauthRelayURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await model.checkOAuthRelay()
                    }
                    if model.publishMode == .service { await model.checkBackend() }
                    refreshing = false
                }
            }
            .buttonStyle(SecondaryButtonStyle()).disabled(refreshing)
            Menu {
                ForEach(PlatformRegistry.all.sorted { PlatformsSettingsGroup.order($0) < PlatformsSettingsGroup.order($1) }) { spec in
                    Button("Connect \(spec.name)…") { wizardPlatform = spec.platform }
                }
                Divider()
                Button("Mock Pinterest (testing only)") { model.addMockAccount() }
            } label: { Label("Connect Account", systemImage: "plus").font(.system(size: 13, weight: .semibold)) }
            .menuStyle(.button).buttonStyle(PrimaryButtonStyle()).menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder
    private var socialSection: some View {
        if accounts.isEmpty {
            EmptyState(symbol: "person.2", title: "No social accounts connected",
                       message: "Launch a guided connection wizard for Pinterest, Facebook Pages, Instagram, Threads, LinkedIn, X, TikTok, or YouTube — or add Mock Pinterest to try every workflow without API keys.") {
                Button("Connect Pinterest…") { wizardPlatform = "pinterest" }.buttonStyle(PrimaryButtonStyle())
                Button("Add Mock Pinterest") { model.addMockAccount() }.buttonStyle(SecondaryButtonStyle())
            }
            .frame(height: 260)
        } else {
            ForEach(accounts) { a in
                AccountCard(
                    account: a,
                    queued: allPubs.filter { $0.workspaceID == model.workspaceID && $0.accountID == a.serverID && ($0.status == .approved || $0.status.isQueuedForPublish) }.count,
                    onOpenWizard: { wizardPlatform = a.platform },
                    onShowDiagnostics: { report in diagnosticReport = report }
                )
            }
        }
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Platform setup & wizards").font(.system(size: 15, weight: .semibold))
                Spacer()
                if case .ready(let count) = model.oauthRelayStatus, count > 0 {
                    StatusDot(text: "One-Click Relay active · \(count) platform\(count == 1 ? "" : "s")", color: DS.green)
                } else {
                    Button("Configure One-Click Relay…") { category = .publishingInfra }.buttonStyle(LinkButtonStyle())
                }
            }
            Text("Connect in one click via a hosted stateless OAuth Relay (Vercel), or bring your own developer app credentials in the macOS Keychain.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
        }
        PlatformKeysList(onConnect: { wizardPlatform = $0 })
        Text("Platform capability matrix").font(.system(size: 15, weight: .semibold))
        CapabilityMatrix()
    }

    @ViewBuilder
    private var aiProvidersSection: some View {
        SettingsGroup(title: "AI Services", footer: "Local providers (Ollama, LM Studio, ComfyUI) keep prompts and media on your network. Cloud API keys are stored in your Keychain.") {
            ForEach(Array(AIProviderID.allCases.enumerated()), id: \.element) { idx, id in
                if idx > 0 { Divider().overlay(DS.stroke) }
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id.displayName).font(DS.bodyMedium)
                        Text(id == .comfyui ? model.comfyURLString : (model.aiConfigs[id]?.baseURL ?? ""))
                            .font(DS.mono).foregroundStyle(DS.text2).lineLimit(1)
                    }
                    Spacer()
                    let statusText: String = {
                        if id == .comfyui { return model.comfyState.isConnected ? "Connected" : model.comfyState.detail }
                        if let v = model.aiStudio.verified[id] { return v }
                        return model.isConfigured(id) ? "Configured · not tested" : "Not configured"
                    }()
                    let statusColor: Color = {
                        if id == .comfyui { return model.comfyState.color }
                        if let v = model.aiStudio.verified[id] { return v == "Verified" ? DS.green : DS.red }
                        return model.isConfigured(id) ? DS.amber : DS.text3
                    }()
                    StatusDot(text: statusText, color: statusColor)
                    Button("Configure") {
                        model.settingsTab = id == .comfyui ? .comfy : .ai
                        model.page = .settings
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var mediaStorageSection: some View {
        MetaPublishingSettings()
    }

    @ViewBuilder
    private var agentsSection: some View {
        AgentSettings()
        OutboundMCPSettingsView()
    }

    @ViewBuilder
    private var publishingInfraSection: some View {
        PublishingSettings()
    }
}

private struct WizardTarget: Identifiable {
    let platform: String
    var id: String { platform }
}

private struct DiagnosticBox: Identifiable {
    let id = UUID()
    let report: ConnectionDiagnosticReport
}

struct AccountCard: View {
    let account: SocialAccount
    let queued: Int
    var onOpenWizard: () -> Void = {}
    var onShowDiagnostics: (ConnectionDiagnosticReport) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var testing = false

    var body: some View {
        let status = account.connectionStatus
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                PlatformBadge(platform: account.platform, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.sm) {
                        Text(account.name).font(.system(size: 15, weight: .semibold))
                        if account.isMock {
                            Text("Mock provider · testing only").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.amber)
                                .padding(.horizontal, Space.sm).padding(.vertical, 2).background(DS.amber.opacity(0.15), in: Capsule())
                        } else if !account.authMode.isEmpty {
                            Text(account.authMode.replacingOccurrences(of: "_", with: " ")).font(DS.caption).foregroundStyle(DS.text2)
                                .padding(.horizontal, Space.sm).padding(.vertical, 2).background(DS.fillStrong, in: Capsule())
                        }
                    }
                    Text([account.handle, PlatformRegistry.spec(account.platform)?.name ?? account.platform, "\(queued) queued"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer()
                StatusDot(text: status.label, color: status.color)
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    Task {
                        let report = await model.testAccountConnection(account)
                        testing = false
                        onShowDiagnostics(report)
                    }
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(testing)
                if status.needsAttention && !account.isMock {
                    Button("Reconnect") {
                        Task {
                            if account.source == "mac" {
                                await model.connectPlatformOnMac(account.platform, authMode: account.authMode)
                            } else {
                                await model.connect(platform: account.platform)
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Menu {
                    Button("Connection Wizard & Credentials…") { onOpenWizard() }
                    if account.source == "mac" && model.workspaces.count > 1 {
                        Menu("Also Associate with Workspace") {
                            ForEach(model.workspaces.filter { $0.uuid != account.workspaceID }) { ws in
                                Button(ws.name) { _ = model.shareAccount(account, intoWorkspace: ws.uuid) }
                            }
                        }
                    }
                    if let keys = PlatformKeys.forPlatform(account.platform), !account.isMock {
                        Link("Open Developer Console", destination: keys.portal)
                    }
                    Divider()
                    Button("Disconnect from This Workspace", role: .destructive) {
                        model.disconnectAccount(account)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize().help("Account Actions")
            }
            if let err = account.lastError, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.small).foregroundStyle(DS.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: 0) {
                    KeyValueRow(key: "Permissions") { Text(account.scopes.isEmpty ? "None" : account.scopes.joined(separator: ", ")).font(DS.mono) }
                    KeyValueRow("Credential", account.isMock ? "Not needed (mock)" : account.tokenExpiresAt.map { "Expires \($0.formatted(.relative(presentation: .named)))" } ?? "No expiry reported")
                    KeyValueRow("Last verified", account.lastVerifiedAt?.formatted(.dateTime.month().day().hour().minute()) ?? "Never tested")
                    KeyValueRow("Last publish", account.lastPublishedAt?.formatted(.dateTime.month().day().hour().minute()) ?? "Never")
                    KeyValueRow("Destinations", (model.boards[account.serverID] ?? []).map(\.name).joined(separator: ", ").nonEmpty ?? "Not loaded")
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Capabilities")
                    ForEach(account.capabilities, id: \.contentType.id) { c in
                        Label {
                            Text(c.contentType.name + (c.allowed ? "" : " — " + (c.reason ?? ""))).font(DS.body)
                        } icon: {
                            Image(systemName: c.allowed ? "checkmark.circle.fill" : "lock.fill").foregroundStyle(c.allowed ? DS.green : DS.amber)
                        }
                    }
                    if let spec = PlatformRegistry.spec(account.platform), !spec.liveVerified, !account.isMock {
                        Label("Implemented & unit tested · not yet live verified.", systemImage: "info.circle").font(DS.small).foregroundStyle(DS.amber)
                    }
                }
                .frame(width: 320, alignment: .leading)
            }
        }
        .card(padding: Space.xl)
    }
}

/// Guided step-by-step wizard for connecting any of the 8 social platforms.
struct ConnectionWizardSheet: View {
    let platform: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var hasSavedSecret = false
    @State private var pastedCallback = ""
    @State private var authVariant = "default"
    @State private var connectionMethod = "byok"
    @State private var statusMessage: String?
    @State private var busy = false
    @AppStorage("pinterest.apiBase") private var pinterestBase = "https://api.pinterest.com"
    @AppStorage(MetaSettings.pinterestRedirectKey) private var pinterestRedirect = MetaSettings.defaultHTTPSRedirect

    private var spec: PlatformSpec? { PlatformRegistry.spec(platform) }
    private var keys: PlatformKeys? { PlatformKeys.forPlatform(platform) }
    private var relayAvailable: Bool { model.relaySupports(platform: platform, authVariant: authVariant) }

    private var idKeychainItem: String {
        switch platform {
        case "pinterest": "pinterest.clientID"
        case "facebook": MetaSettings.appIDItem
        case "instagram": authVariant == "instagram_login" ? MetaSettings.instagramIDItem : MetaSettings.appIDItem
        case "threads": MetaSettings.threadsIDItem
        case "linkedin": "linkedin.clientID"
        case "x": "x.clientID"
        case "tiktok": "tiktok.clientKey"
        case "youtube": "youtube.clientID"
        default: "\(platform).clientID"
        }
    }

    private var secretKeychainItem: String {
        switch platform {
        case "pinterest": "pinterest.clientSecret"
        case "facebook": MetaSettings.secretItem
        case "instagram": authVariant == "instagram_login" ? MetaSettings.instagramSecretItem : MetaSettings.secretItem
        case "threads": MetaSettings.threadsSecretItem
        case "linkedin": "linkedin.clientSecret"
        case "x": "x.clientSecret"
        case "tiktok": "tiktok.clientSecret"
        case "youtube": "youtube.clientSecret"
        default: "\(platform).clientSecret"
        }
    }

    private var redirectURI: String {
        switch platform {
        case "pinterest": pinterestRedirect.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? MetaSettings.defaultHTTPSRedirect
        case "facebook": MetaSettings.redirect
        case "instagram": authVariant == "instagram_login" ? MetaSettings.instagramRedirect : MetaSettings.redirect
        case "threads": MetaSettings.threadsRedirect
        default: "http://127.0.0.1:\(OAuthLoopback.port)/\(platform)/callback"
        }
    }

    private var secretOptional: Bool { platform == "x" || platform == "youtube" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                PlatformBadge(platform: platform, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(spec?.name ?? platform.capitalized)").font(DS.display(26))
                    Text("Bring-your-own-credentials OAuth setup · keys stay in your Keychain").font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Divider().overlay(DS.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let spec {
                        Text(PlatformStatus.summary(spec)).font(DS.body).foregroundStyle(DS.textBody)
                    }
                    if relayAvailable {
                        PillPicker(options: ["relay", "byok"], selection: $connectionMethod) {
                            $0 == "relay" ? "One-Click Sign In (Relay)" : "My Own Developer App (BYOK)"
                        }
                    }

                    if connectionMethod == "relay" && relayAvailable {
                        VStack(alignment: .leading, spacing: Space.md) {
                            SectionLabel("One-Click Sign In via Stateless OAuth Relay")
                            Text("No developer app required. Your browser opens \(spec?.name ?? platform.capitalized), asks you to approve access, and bounces directly back into SocialForge. Your tokens are saved only in your local macOS Keychain — the relay stores nothing.")
                                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                            if platform == "pinterest" {
                                PillPicker(options: ["https://api.pinterest.com", "https://api-sandbox.pinterest.com"], selection: $pinterestBase) {
                                    $0.contains("sandbox") ? "Sandbox (Trial)" : "Production (Standard)"
                                }
                            } else if platform == "instagram" {
                                PillPicker(options: ["facebook_login", "instagram_login"], selection: $authVariant) {
                                    $0 == "instagram_login" ? "Direct Instagram Login" : "Facebook Login (Linked Page)"
                                }
                            } else if platform == "linkedin" {
                                PillPicker(options: ["default", "organization"], selection: $authVariant) {
                                    $0 == "organization" ? "Personal + Company Pages" : "Personal Profile Only"
                                }
                            }
                            Button(busy ? "Opening browser…" : "Continue with \(spec?.name ?? platform.capitalized)") {
                                busy = true
                                statusMessage = nil
                                Task {
                                    await model.connectViaRelay(platform, authMode: authVariant)
                                    busy = false
                                    if let err = model.lastError { statusMessage = err }
                                    else if let msg = model.metaMessage { statusMessage = msg }
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(busy)
                        }
                        .card()
                    } else {
                    if let keys {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            SectionLabel("1. Developer Console Prerequisites")
                            Text(keys.steps).font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Space.md) {
                                Link(destination: keys.portal) { Label("Open Developer Console", systemImage: "arrow.up.right.square") }
                                    .buttonStyle(SecondaryButtonStyle())
                                Link("Official API Guide", destination: keys.guide).buttonStyle(LinkButtonStyle())
                            }
                        }
                        .card()
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("2. Register Redirect URI")
                        if platform == "pinterest" {
                            HStack(spacing: Space.sm) {
                                TextField(MetaSettings.defaultHTTPSRedirect, text: $pinterestRedirect).fieldStyle().font(DS.mono)
                                Button("Copy URI") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(redirectURI, forType: .string)
                                    statusMessage = "Copied redirect URI to clipboard."
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                            Text("Pinterest requires an HTTPS redirect URI. After approving in your browser, click Open SocialForge or Copy address on the callback page.")
                                .font(DS.small).foregroundStyle(DS.text2)
                        } else {
                            HStack {
                                Text(redirectURI).font(DS.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Copy URI") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(redirectURI, forType: .string)
                                    statusMessage = "Copied redirect URI to clipboard."
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                    .card()

                    VStack(alignment: .leading, spacing: Space.md) {
                        SectionLabel("3. Credentials & Authorization Mode")
                        if platform == "pinterest" {
                            PillPicker(options: ["https://api.pinterest.com", "https://api-sandbox.pinterest.com"], selection: $pinterestBase) {
                                $0.contains("sandbox") ? "Sandbox (Trial)" : "Production (Standard)"
                            }
                        } else if platform == "instagram" {
                            PillPicker(options: ["facebook_login", "instagram_login"], selection: $authVariant) {
                                $0 == "instagram_login" ? "Direct Instagram Login" : "Facebook Login (Linked Page)"
                            }
                        } else if platform == "linkedin" {
                            PillPicker(options: ["default", "organization"], selection: $authVariant) {
                                $0 == "organization" ? "Personal + Company Pages" : "Personal Profile Only"
                            }
                        }
                        TextField(keys?.keys.first ?? "Client ID", text: $clientID).fieldStyle()
                        SecureField(hasSavedSecret ? "Secret saved in Keychain · paste to replace" : (keys?.keys.dropFirst().first ?? "Client Secret"), text: $clientSecret).fieldStyle()
                        HStack {
                            Button("Save Credentials") { saveCredentials() }.buttonStyle(SecondaryButtonStyle())
                            Button(busy ? "Connecting…" : "Authorize in Browser") {
                                saveCredentials()
                                authorize()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(busy || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!secretOptional && clientSecret.isEmpty && !hasSavedSecret))
                        }
                    }
                    .card()
                    }

                    if let pending = model.pendingOAuth {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            SectionLabel("4. Complete Manual Callback (\(pending.serviceName))")
                            Text("Paste the complete URL from your browser address bar (including code and state).").font(DS.small).foregroundStyle(DS.text2)
                            TextField("https://…/?code=…&state=…", text: $pastedCallback).fieldStyle().font(DS.mono)
                            HStack {
                                Button("Verify & Connect") {
                                    let url = pastedCallback
                                    pastedCallback = ""
                                    busy = true
                                    Task {
                                        await model.finishMeta(pasted: url)
                                        statusMessage = model.metaMessage
                                        busy = false
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(pastedCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Cancel Session") { model.pendingOAuth = nil }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        .card()
                    }

                    if let msg = statusMessage ?? model.metaMessage {
                        Text(msg).font(DS.small).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 620, height: 640)
        .background(DS.panel)
        .noInitialFocus()
        .onAppear {
            loadCredentials()
            connectionMethod = relayAvailable ? "relay" : "byok"
        }
        .onChange(of: authVariant) { _, _ in
            loadCredentials()
            if !relayAvailable && connectionMethod == "relay" { connectionMethod = "byok" }
        }
    }

    private func loadCredentials() {
        clientID = Keychain.read(idKeychainItem) ?? ""
        hasSavedSecret = Keychain.read(secretKeychainItem)?.isEmpty == false
        clientSecret = ""
    }

    private func saveCredentials() {
        let cleanID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSec = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanID.isEmpty { Keychain.write(idKeychainItem, cleanID) }
        if !cleanSec.isEmpty { Keychain.write(secretKeychainItem, cleanSec); clientSecret = "" }
        hasSavedSecret = Keychain.read(secretKeychainItem)?.isEmpty == false
        model.modeRevision += 1
        statusMessage = "Credentials saved to macOS Keychain."
    }

    private func authorize() {
        busy = true
        statusMessage = nil
        Task {
            await model.connectPlatformOnMac(platform, authMode: authVariant)
            busy = false
            if let err = model.lastError {
                statusMessage = err
            } else if model.pendingOAuth == nil {
                statusMessage = model.metaMessage ?? "Connection updated."
            }
        }
    }
}

/// Sanitized connection diagnostics with one-click Copy Diagnostics (never includes secrets).
struct ConnectionDiagnosticsSheet: View {
    let report: ConnectionDiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Diagnostics").font(DS.display(24))
                    Text("\(report.providerName) · \(report.accountIdentity)").font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer()
                StatusDot(text: report.status.label, color: report.status.color)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionLabel("Plain-Language Summary")
                Text(report.plainLanguageSummary).font(DS.body).fixedSize(horizontal: false, vertical: true)
                SectionLabel("Recommended Action").padding(.top, Space.xs)
                Text(report.recommendedAction).font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            .card()
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionLabel("Sanitized Technical Details")
                ForEach(report.technicalDetails.keys.sorted(), id: \.self) { k in
                    KeyValueRow(key: k) { Text(report.technicalDetails[k] ?? "").font(DS.mono) }
                }
            }
            .card()
            HStack {
                Button(copied ? "Copied Sanitized Report" : "Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.copyableText(), forType: .string)
                    copied = true
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("Secrets, tokens, codes, and signed URLs are automatically redacted.").font(DS.caption).foregroundStyle(DS.text3)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 580)
        .background(DS.panel)
        .noInitialFocus()
    }
}

/// Where each platform's developer keys come from, with the redirect URI SocialForge expects.
struct PlatformKeysList: View {
    @Environment(AppModel.self) private var model
    var onConnect: ((String) -> Void)?

    /// The redirect URI to register on the developer site.
    static func redirect(for platform: String) -> String? {
        switch platform {
        case "pinterest": MetaSettings.pinterestRedirect
        case "facebook", "instagram": MetaSettings.redirect
        case "threads": MetaSettings.threadsRedirect
        case "linkedin": "http://127.0.0.1:\(OAuthLoopback.port)/linkedin/callback"
        case "x": "http://127.0.0.1:\(OAuthLoopback.port)/x/callback"
        case "tiktok": "http://127.0.0.1:\(OAuthLoopback.port)/tiktok/callback"
        case "youtube": "http://127.0.0.1:\(OAuthLoopback.port)/youtube/callback"
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PlatformKeys.all.enumerated()), id: \.element.id) { i, keys in
                if i > 0 { Divider().overlay(DS.stroke) }
                row(keys)
            }
        }
        .card(padding: Space.xl)
    }

    private func row(_ keys: PlatformKeys) -> some View {
        let name = PlatformRegistry.spec(keys.platform)?.name ?? keys.platform
        return HStack(alignment: .top, spacing: Space.md) {
            PlatformBadge(platform: keys.platform, size: 28)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(name).font(DS.bodyMedium)
                    StatusDot(text: "Adapter built · unverified live", color: DS.amber)
                }
                Text(keys.steps).font(DS.body).foregroundStyle(DS.textBody).fixedSize(horizontal: false, vertical: true)
                Text("Credentials: " + keys.keys.joined(separator: ", ")).font(DS.small).foregroundStyle(DS.text2)
                if let redirect = Self.redirect(for: keys.platform) {
                    HStack(spacing: Space.sm) {
                        Text("Redirect URI").font(DS.small).foregroundStyle(DS.text2)
                        Text(redirect).font(DS.mono).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(redirect, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(IconButtonStyle()).help("Copy the redirect URI")
                    }
                }
            }
            Spacer(minLength: Space.md)
            VStack(alignment: .trailing, spacing: Space.sm) {
                if model.relaySupports(platform: keys.platform) {
                    Button("One-Click Connect") {
                        Task { await model.connectViaRelay(keys.platform) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("BYOK Wizard…") { onConnect?(keys.platform) }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Setup Wizard…") { onConnect?(keys.platform) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                HStack(spacing: Space.md) {
                    Link("Console", destination: keys.portal).buttonStyle(LinkButtonStyle())
                    Link("Guide", destination: keys.guide).buttonStyle(LinkButtonStyle())
                }
            }
            .fixedSize()
        }
        .padding(.vertical, Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) developer keys")
    }
}

/// What each platform supports in this version, from spec/platforms.
struct CapabilityMatrix: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.md) {
            GridRow {
                ForEach(["Platform", "Status", "Content", "Image", "Video", "Text limits"], id: \.self) { Text($0.uppercased()).font(DS.sectionLabel).tracking(0.6).foregroundStyle(DS.text3) }
            }
            Divider().overlay(DS.stroke).gridCellUnsizedAxes(.horizontal)
            ForEach(PlatformRegistry.all.sorted { PlatformsSettingsGroup.order($0) < PlatformsSettingsGroup.order($1) }) { s in
                GridRow {
                    HStack { PlatformBadge(platform: s.platform, size: 18); Text(s.name).font(DS.bodyMedium) }
                    StatusDot(text: s.isAvailable ? (s.liveVerified ? "Live, verified" : "Built · unverified live") : PlatformsSettingsGroup.badge(s),
                              color: s.isAvailable ? (s.liveVerified ? DS.green : DS.amber) : DS.text3)
                    Text(s.contentTypes.map(\.name).joined(separator: ", ")).font(DS.body)
                    Text(s.image.map { "\($0.recommended.aspect) · \($0.recommended.width)×\($0.recommended.height) · ≤\($0.maxBytes / 1_048_576) MB" } ?? "—").font(DS.body)
                    Text(s.video.map { "\($0.recommended.aspect) · \($0.recommended.width)×\($0.recommended.height)" + ($0.maxSeconds.map { " · ≤" + PostValidator.duration($0) } ?? "") } ?? "—").font(DS.body)
                    Text(s.text.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.max)" }.joined(separator: ", ")).font(DS.small).foregroundStyle(DS.text2)
                }
            }
        }
        .card(padding: Space.xl)
    }
}

struct AccountsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Connections") { Text(model.publishMode == .mac ? "This Mac" : "Service") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Connected Accounts")
                    ForEach(model.accounts) { AccountRow(account: $0) }
                    if model.accounts.isEmpty { Text("None yet").font(DS.body).foregroundStyle(DS.text2) }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Publishing Infrastructure")
                    Text(model.helperStatusText).font(DS.body).foregroundStyle(DS.textBody)
                    KeyValueRow("Media Storage", PublicMediaSettings.config() != nil ? "Configured" : "Not set up")
                    KeyValueRow("ComfyUI", model.comfyState.detail)
                }
                if model.publishMode == .service {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("Remote Service")
                        KeyValueRow("Last sync", model.lastSync?.formatted(.relative(presentation: .named)) ?? "Never")
                        if let caps = model.backendCapabilities {
                            KeyValueRow("Supported", caps.platforms.joined(separator: ", "))
                        }
                        Button("Sync Now") { Task { await model.sync() } }.buttonStyle(SecondaryButtonStyle(fullWidth: true)).disabled(model.client == nil)
                    }
                }
            }
        }
    }
}

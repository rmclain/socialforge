import SwiftData
import SwiftUI
import SocialForgeKit

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SocialAccount.name) private var allAccounts: [SocialAccount]
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @State private var refreshing = false

    private var accounts: [SocialAccount] { allAccounts.filter { $0.workspaceID == model.workspaceID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Accounts").font(DS.display(30))
                        Text("Connected through each platform's official sign-in. Tokens stay in your Keychain; options an account cannot use stay off.")
                            .foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button("Refresh") {
                        refreshing = true
                        Task { await model.refreshAccounts(); refreshing = false }
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(refreshing)
                    Menu {
                        ForEach(PlatformRegistry.all) { spec in
                            // The optional service connects Pinterest only; Meta platforms post from this Mac.
                            let macOnly = spec.platform != "pinterest" && model.publishMode == .service
                            Button(spec.name + (!spec.isAvailable ? " (not built yet)" : macOnly ? " (This Mac publishing only)" : "")) {
                                Task {
                                    switch (model.publishMode, spec.platform) {
                                    case (.service, _): await model.connect(platform: spec.platform)
                                    case (.mac, "facebook"), (.mac, "instagram"): await model.connectMeta(.facebook)
                                    case (.mac, "threads"): await model.connectMeta(.threads)
                                    default: await model.connectPinterestOnMac()
                                    }
                                }
                            }
                            .disabled(!spec.isAvailable || macOnly)
                        }
                        Divider()
                        Button("Mock Pinterest (testing only)") { model.addMockAccount() }
                    } label: { Label("Connect Account", systemImage: "plus").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.button).buttonStyle(PrimaryButtonStyle()).menuIndicator(.hidden).fixedSize()
                }
                if accounts.isEmpty {
                    EmptyState(symbol: "person.2", title: "No accounts yet",
                               message: "Connect Pinterest, Facebook, Instagram, or Threads with your own developer apps (IDs and secrets in Settings > Publishing), or add the mock account to try the whole flow without credentials.") {
                        Button("Add Mock Account") { model.addMockAccount() }.buttonStyle(SecondaryButtonStyle())
                        Button("Publishing Settings") { model.settingsTab = .publishing; model.page = .settings }.buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(height: 300)
                }
                ForEach(accounts) { a in AccountCard(account: a, queued: allPubs.filter { $0.accountID == a.serverID && [.approved, .scheduled].contains($0.status) }.count) }
                Text("Platform capabilities").font(.system(size: 15, weight: .semibold))
                CapabilityMatrix()
            }
            .padding(Space.xxl)
        }
    }
}

struct AccountCard: View {
    let account: SocialAccount
    let queued: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                PlatformBadge(platform: account.platform, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.sm) {
                        Text(account.name).font(.system(size: 15, weight: .semibold))
                        if account.isMock {
                            Text("Mock provider · testing only").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.amber)
                                .padding(.horizontal, Space.sm).padding(.vertical, 2).background(DS.amber.opacity(0.15), in: Capsule())
                        }
                    }
                    Text([account.handle, PlatformRegistry.spec(account.platform)?.name ?? account.platform, "\(queued) queued"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer()
                StatusDot(text: account.status == "connected" ? "Connected" : account.status.capitalized, color: account.status == "connected" ? DS.green : DS.amber)
                if account.status != "connected" && !account.isMock {
                    Button("Reconnect") {
                        Task { if account.source == "mac" { await model.connectPinterestOnMac() } else { await model.connect(platform: account.platform) } }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Menu {
                    Button("Disconnect and Forget Tokens", role: .destructive) {
                        Keychain.write(account.tokenKey, "")
                        Keychain.write(account.tokenKey + ".refresh", "")
                        model.context.delete(account)
                        try? model.context.save()
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize().help("More")
            }
            HStack(alignment: .top, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: 0) {
                    KeyValueRow(key: "Permissions") { Text(account.scopes.isEmpty ? "None" : account.scopes.joined(separator: ", ")).font(DS.mono) }
                    KeyValueRow("Token", account.isMock ? "Not needed (mock)" : account.tokenExpiresAt.map { "Expires \($0.formatted(.relative(presentation: .named)))" } ?? "No expiry reported")
                    KeyValueRow("Last publish", account.lastPublishedAt?.formatted(.dateTime.month().day().hour().minute()) ?? "Never")
                    KeyValueRow("Boards", (model.boards[account.serverID] ?? []).map(\.name).joined(separator: ", ").nonEmpty ?? "Not loaded")
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Can publish")
                    ForEach(account.capabilities, id: \.contentType.id) { c in
                        Label {
                            Text(c.contentType.name + (c.allowed ? "" : " — " + (c.reason ?? ""))).font(DS.body)
                        } icon: {
                            Image(systemName: c.allowed ? "checkmark.circle.fill" : "lock.fill").foregroundStyle(c.allowed ? DS.green : DS.amber)
                        }
                    }
                    if let spec = PlatformRegistry.spec(account.platform), !spec.liveVerified, !account.isMock {
                        Label("Live API not yet verified for \(spec.name).", systemImage: "exclamationmark.triangle").font(DS.small).foregroundStyle(DS.amber)
                    }
                }
                .frame(width: 320, alignment: .leading)
            }
        }
        .card(padding: Space.xl)
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
                    StatusDot(text: s.isAvailable ? (s.liveVerified ? "Live, verified" : "Built · live API unverified") : PlatformsSettingsGroup.badge(s),
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
            PanelHeader(title: "Publishing") { Text(model.publishMode == .mac ? "This Mac" : "Service") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Accounts")
                    ForEach(model.accounts) { AccountRow(account: $0) }
                    if model.accounts.isEmpty { Text("None yet").font(DS.body).foregroundStyle(DS.text2) }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Where posts publish from")
                    Text(model.helperStatusText).font(DS.body).foregroundStyle(DS.textBody)
                    Button("Publishing Settings") { model.settingsTab = .publishing; model.page = .settings }.buttonStyle(LinkButtonStyle())
                }
                if model.publishMode == .service {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("Sync")
                        KeyValueRow("Last sync", model.lastSync?.formatted(.relative(presentation: .named)) ?? "Never")
                        Button("Sync Now") { Task { await model.sync() } }.buttonStyle(SecondaryButtonStyle(fullWidth: true)).disabled(model.client == nil)
                    }
                }
            }
        }
    }
}

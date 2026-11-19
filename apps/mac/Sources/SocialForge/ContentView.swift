import SwiftData
import SwiftUI
import SocialForgeKit

/// The window: sidebar · page (top bar + workspace) · inspector, as in the design.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if model.showSidebar {
                Sidebar()
                    .frame(width: DS.sidebarWidth)
                    .transition(.move(edge: .leading))
                Divider().overlay(DS.stroke)
            }
            VStack(spacing: 0) {
                TopBar()
                Divider().overlay(DS.stroke)
                PageView(page: model.page)
                    .id(model.workspaceID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DS.main)
            if model.showInspector {
                Divider().overlay(DS.stroke)
                InspectorView(page: model.page)
                    .id(model.workspaceID)
                    .frame(width: DS.inspectorWidth)
                    .background(DS.panel)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(DS.window)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(DS.text)
        .tint(DS.accent)
        .animation(.snappy(duration: 0.2), value: model.showInspector)
        .animation(.snappy(duration: 0.2), value: model.showSidebar)
        .sheet(isPresented: $model.showNewWorkspace) { NewWorkspaceSheet() }
        .sheet(isPresented: $model.showCommandPanel) { CommandPanel() }
        .sheet(isPresented: Binding(get: { AppUpdater.shared.showSheet }, set: { AppUpdater.shared.showSheet = $0 })) {
            if let r = AppUpdater.shared.available { UpdateSheet(release: r) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            SeedData.insertIfRequested(into: model)
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
            guard !Store.isOverridden else { return }
            model.runner.startInApp()
            AppUpdater.shared.checkIfDue()
            Task { @MainActor in
                // Folder and weekly automations, while the app is open.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await AutomationEngine.tick(model: model)
                }
            }
            await model.refreshLocalAccounts()
            await model.checkComfy()
            guard model.publishMode == .service else { return }
            await model.checkBackend()
            if case .up = model.backendStatus {
                await model.refreshAccounts()
                await model.sync()
            }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var showResults = false
    @State private var showNotifications = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Space.md) {
            if !model.showSidebar {
                // Room for the window buttons when the sidebar is hidden.
                Color.clear.frame(width: 64)
                Button("Show Sidebar", systemImage: "sidebar.left") { model.showSidebar = true }
                    .labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.page.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                Text(model.pageSubtitle).font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.text3)
                TextField("Search posts, media", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { showResults = !model.searchText.isEmpty }
                    .onChange(of: model.searchText) { showResults = !model.searchText.isEmpty }
                Text("⌘K").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text3)
                    .padding(.horizontal, Space.xs).padding(.vertical, 2)
                    .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, Space.md)
            .frame(width: 280, height: 32)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(DS.stroke))
            .popover(isPresented: $showResults, arrowEdge: .bottom) { SearchResults(query: model.searchText) { showResults = false } }
            Button("Notifications", systemImage: model.notificationCount > 0 ? "bell.badge" : "bell") { showNotifications.toggle() }
                .labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
                .help("Approvals and failures")
                .popover(isPresented: $showNotifications, arrowEdge: .bottom) { NotificationsPopover() }
            Menu {
                Button("Post in Composer", systemImage: "square.and.pencil") { model.page = .composer; model.composer.startNew(model: model) }
                Button("Bulk Run", systemImage: "square.stack.3d.up") { model.page = .bulk }
                Button("Design", systemImage: "paintbrush.pointed") { model.page = .studio; model.studio.openNew(model: model) }
                Button("Import Media…", systemImage: "square.and.arrow.down") { ImportPanel.run(model: model) }
            } label: {
                Label("New Post", systemImage: "plus").font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(PrimaryButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
                .labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
                .help("Show or hide the inspector (Option-Command-I)")
        }
        .padding(.horizontal, Space.xl)
        .frame(height: DS.topBarHeight)
        .background(DS.main)
        .background {
            // ⌘K focuses search from anywhere.
            Button("") { searchFocused = true }.keyboardShortcut("k").opacity(0).accessibilityHidden(true)
        }
    }
}

struct SearchResults: View {
    let query: String
    let done: () -> Void
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var pubs: [Publication]
    @Query(sort: \MediaAsset.filename) private var assets: [MediaAsset]

    var body: some View {
        let q = query.lowercased()
        let posts = pubs.filter { $0.workspaceID == model.workspaceID && ($0.title.lowercased().contains(q) || $0.link.lowercased().contains(q)) }.prefix(6)
        let media = assets.filter { $0.workspaceID == model.workspaceID && ($0.filename.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }) }.prefix(6)
        VStack(alignment: .leading, spacing: Space.sm) {
            if posts.isEmpty && media.isEmpty {
                Text("Nothing matches “\(query)”.").foregroundStyle(DS.text2).padding(Space.md)
            }
            if !posts.isEmpty {
                SectionLabel("Posts")
                ForEach(posts) { p in
                    Button {
                        model.page = .calendar
                        model.publicationSelection = [p.id]
                        done()
                    } label: { PublicationRow(pub: p) }.buttonStyle(.plain)
                }
            }
            if !media.isEmpty {
                SectionLabel("Media")
                ForEach(media) { a in
                    Button {
                        model.page = .media
                        model.mediaSelection = [a.uuid]
                        done()
                    } label: {
                        HStack {
                            Thumbnail(path: a.storedPath, maxPixel: 96).frame(width: 28, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(a.filename).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Space.md)
        .frame(width: 360)
    }
}

struct NotificationsPopover: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var pubs: [Publication]

    var body: some View {
        let mine = pubs.filter { $0.workspaceID == model.workspaceID }
        let failed = mine.filter { $0.status == .failed }
        let review = mine.filter { $0.status == .needsReview }
        VStack(alignment: .leading, spacing: Space.md) {
            if failed.isEmpty && review.isEmpty {
                Text("You're all caught up.").foregroundStyle(DS.text2)
            }
            if !failed.isEmpty {
                SectionLabel("Failed")
                ForEach(failed.prefix(5)) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(DS.bodyMedium)
                        Text(p.lastError ?? "").font(DS.small).foregroundStyle(DS.red).lineLimit(2)
                    }
                }
            }
            if !review.isEmpty {
                SectionLabel("Awaiting approval")
                Text("\(review.count) posts need your review.").font(DS.body)
                Button("Review in Bulk Publisher") { model.page = .bulk }.buttonStyle(LinkButtonStyle())
            }
        }
        .padding(Space.lg)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var pubs: [Publication]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button("Hide Sidebar", systemImage: "sidebar.left") { model.showSidebar = false }
                    .labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
                    .help("Hide the sidebar (Control-Command-S)")
            }
            .frame(height: DS.topBarHeight)
            .padding(.horizontal, Space.md)
            WorkspaceSwitcher().padding(.horizontal, Space.md)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AppPage.Section.allCases, id: \.self) { section in
                        if !section.rawValue.isEmpty {
                            Text(section.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.text3)
                                .padding(.horizontal, Space.md).padding(.top, Space.lg).padding(.bottom, Space.xs)
                        }
                        ForEach(AppPage.allCases.filter { $0.section == section }) { page in
                            SidebarItem(page: page, badge: badge(page))
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.md)
            }
            Spacer(minLength: 0)
            Divider().overlay(DS.stroke)
            VStack(spacing: Space.sm) {
                UpdateBanner()
                ComfyStatusRow()
                PublishingStatusRow()
                UserRow()
            }
            .padding(Space.md)
        }
        .background {
            ZStack {
                DS.sidebar
                // The design's warm glow in the top left.
                RadialGradient(colors: [Color(hex: 0xFF6E3C).opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
    }

    private func badge(_ page: AppPage) -> Int {
        guard page == .home || page == .bulk else { return 0 }
        let ws = model.workspaceID
        return pubs.filter { $0.workspaceID == ws && $0.status == .needsReview }.count
    }
}

struct SidebarItem: View {
    let page: AppPage
    let badge: Int
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let selected = model.page == page
        Button { model.page = page } label: {
            HStack(spacing: Space.md) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? DS.accent : DS.text2)
                    .frame(width: 20)
                Text(page.title).font(.system(size: 13.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DS.text : DS.textBody)
                Spacer()
                if badge > 0 { Text("\(badge)").font(DS.small).foregroundStyle(DS.text2).monospacedDigit() }
            }
            .padding(.horizontal, Space.md)
            .frame(height: 32)
            .background(selected ? DS.fillSelected : (hover ? DS.fill : .clear), in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceSwitcher: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Workspace.createdAt) private var workspaces: [Workspace]

    var body: some View {
        Menu {
            ForEach(workspaces) { w in
                Button {
                    model.workspaceID = w.uuid
                } label: {
                    if w.uuid == model.workspaceID { Label(w.name, systemImage: "checkmark") } else { Text(w.name) }
                }
            }
            Divider()
            Button("New Workspace…") { model.showNewWorkspace = true }
        } label: {
            HStack(spacing: Space.sm) {
                WorkspaceBadge(name: model.workspace?.name ?? "?", colorHex: model.workspace?.colorHex ?? 0xFF8A5C, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.workspace?.name ?? "No workspace").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                    Text("Brand workspace").font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(DS.text2)
            }
            .padding(Space.sm)
            .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch workspace")
        .accessibilityLabel("Workspace: \(model.workspace?.name ?? "none")")
    }
}

struct WorkspaceBadge: View {
    let name: String
    let colorHex: Int
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: UInt32(colorHex)).opacity(0.9), Color(hex: UInt32(colorHex)).opacity(0.55)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text(name.first.map { String($0).uppercased() } ?? "?").font(DS.display(size * 0.62)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

struct ComfyStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.settingsTab = .comfy; model.page = .settings } label: {
            HStack(spacing: Space.sm) {
                Circle().fill(model.comfyState.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("ComfyUI · \(model.comfyIsLocal ? "Local" : "Remote")").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text)
                    Text(model.comfyState.detail).font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.sm)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("ComfyUI connection (Settings)")
    }
}

struct PublishingStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.modeRevision
        let on = model.publishMode == .mac ? model.helperService.status == .enabled : { if case .up = model.backendStatus { true } else { false } }()
        Button { model.settingsTab = .publishing; model.page = .settings } label: {
            HStack(spacing: Space.sm) {
                Circle().fill(on ? DS.green : DS.text3).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.publishMode == .mac ? "Publishing · This Mac" : "Publishing · Service").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text)
                    Text(model.publishMode == .mac ? (on ? "Also while the app is closed" : "While SocialForge is open") : (on ? "Service up" : "Service not reachable"))
                        .font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.sm)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct UserRow: View {
    var body: some View {
        let name = Store.isOverridden ? "Maya Kessler" : NSFullUserName()
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        HStack(spacing: Space.sm) {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xD8B08C), Color(hex: 0x8A5A3C)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 28, height: 28)
                .overlay(Text(initials.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            Text(name).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
            Spacer()
            Text("Owner").font(DS.small).foregroundStyle(DS.text2)
        }
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
    }
}

struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = 0xFF8A5C
    static let colors = [0xFF8A5C, 0xE84A93, 0x7B5CFF, 0x0A84FF, 0x2BC48A, 0xF5B800, 0x7C7C84]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("New Workspace").font(DS.display(26))
            Text("A workspace is a company, brand, or client. Its media, posts, kits, and accounts stay separate.").font(DS.body).foregroundStyle(DS.text2)
            TextField("Company, brand, or client", text: $name).fieldStyle().onSubmit(create)
            HStack(spacing: Space.sm) {
                ForEach(Self.colors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Color(hex: UInt32(c))).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.white, lineWidth: color == c ? 2 : 0))
                    }
                    .buttonStyle(.plain).accessibilityLabel(String(format: "Color %06X", c))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create", action: create).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xxl)
        .frame(width: 440)
        .background(DS.panel)
        .noInitialFocus()
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createWorkspace(name: name, colorHex: color)
        dismiss()
    }
}

/// The center workspace for each sidebar page.
struct PageView: View {
    let page: AppPage

    var body: some View {
        switch page {
        case .home: HomeView()
        case .calendar: CalendarView()
        case .composer: ComposerView()
        case .media: MediaLibraryView()
        case .studio: StudioView()
        case .ai: AIStudioView()
        case .bulk: BulkView()
        case .automations: AutomationsView()
        case .campaigns: CampaignsView()
        case .analytics: AnalyticsView()
        case .accounts: AccountsView()
        case .brandKits: BrandKitsView()
        case .settings: SettingsPage()
        }
    }
}

/// The right-hand inspector for each page.
struct InspectorView: View {
    let page: AppPage

    var body: some View {
        switch page {
        case .home: HomeInspector()
        case .accounts: AccountsInspector()
        case .calendar: PublicationInspector()
        case .composer: ComposerInspector()
        case .media: MediaInspector()
        case .studio: StudioInspector()
        case .ai: AIProvidersInspector()
        case .bulk: BulkInspector()
        case .brandKits: BrandKitInspector()
        case .analytics: AnalyticsInspector()
        case .campaigns: CampaignInspector()
        case .automations: AutomationInspector()
        case .settings: SettingsInspector()
        }
    }
}

/// A small colored platform glyph, like the design's badges.
struct PlatformBadge: View {
    let platform: String
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color(hex: Self.color(platform)))
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(["x", "tiktok", "threads"].contains(platform) ? 0.28 : 0)))
            .overlay(Text(Self.glyph(platform)).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.white))
            .accessibilityLabel(PlatformRegistry.spec(platform)?.name ?? platform)
    }

    static func color(_ p: String) -> UInt32 {
        switch p {
        case "pinterest": 0xE60023
        case "facebook": 0x0866FF
        case "linkedin": 0x0A66C2
        case "x": 0x000000
        case "tiktok": 0x111111
        case "instagram": 0xD62976
        case "youtube": 0xFF0033
        case "threads": 0x101010
        default: 0x7C7C84
        }
    }

    static func glyph(_ p: String) -> String {
        switch p {
        case "pinterest": "P"
        case "facebook": "f"
        case "linkedin": "in"
        case "x": "𝕏"
        case "tiktok": "♪"
        case "instagram": "IG"
        case "youtube": "▶"
        case "threads": "@"
        default: "?"
        }
    }
}

struct StatusChip: View {
    let status: PublicationStatus

    var body: some View { StatusDot(text: status.title, color: status.color) }
}

extension PublicationStatus {
    var color: Color {
        switch self {
        case .published: DS.green
        case .failed: DS.red
        case .needsReview: DS.amber
        case .approved: DS.green
        case .scheduled, .preparing, .publishing: DS.accent
        case .draft, .paused, .canceled: DS.text2
        }
    }
}

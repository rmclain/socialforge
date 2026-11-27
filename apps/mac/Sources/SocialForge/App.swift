import AppKit
import SwiftData
import SwiftUI
import SocialForgeKit

// SocialForge
//   SocialForge                      the app
//   APP_STORE=<file> SocialForge     use another database (tests, experiments)
//   APP_SNAPSHOT=<dir> SocialForge   save a PNG of every sidebar page and Settings tab in light and dark mode, then quit
//   APP_SEED=1 SocialForge           fill an empty /tmp store with sample data (tools/snap.sh)
//   SocialForge --selftest           run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> SocialForge      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 SocialForge           draw the 8 pt grid and the layout probes over the window
//   SocialForge --publish-agent [--once]   the background publisher (launch agent), no window
//   SocialForge --mcp                the MCP server for Claude, Codex, and other agents (stdio), no window

@main
enum Entry {
    static func main() {
        if PublishAgent.requested { PublishAgent.run() }
        if AgentMCP.requested { AgentMCP.run() }
        SocialForgeApp.main()
    }
}

struct SocialForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(container: Store.makeContainer())

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        Window("SocialForge", id: "main") {
            ContentView()
                .environment(model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 1180, minHeight: 720)
                .onOpenURL { url in
                    Task { await model.handleIncomingOAuthURL(url) }
                }
        }
        .modelContainer(model.container)
        .defaultSize(width: 1480, height: 940)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .modelContainer(model.container)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await AppUpdater.shared.check(userInitiated: true) } }
                .disabled(!AppUpdater.shared.isEnabled)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Post in Composer") {
                model.page = .composer
                model.composer.startNew(model: model)
            }
            .keyboardShortcut("n")
            Button("New Design") {
                model.page = .studio
                model.studio.openNew(model: model)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("New Bulk Run") { model.page = .bulk }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("New Workspace…") { model.showNewWorkspace = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Import Media…") { model.page = .media; ImportPanel.run(model: model) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Save Sample CSV…") { SampleCSVPanel.run() }
            Divider()
            Button("Import Brand Kit…") {
                if let kit = BrandKitIO.importKit(model: model) {
                    if model.showWelcome { model.completeBrandImport(kit) } else { model.page = .brandKits }
                }
            }
            Button("Export Brand Kit…") {
                if let k = model.brandKit {
                    let templates = (try? model.context.fetch(FetchDescriptor<CreativeTemplate>()))?.filter { $0.workspaceID == k.workspaceID } ?? []
                    BrandKitIO.export(k, templates: templates)
                }
            }
            .disabled(model.brandKit == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if model.page == .studio && model.studio.canUndo {
                    model.studio.undo()
                } else {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if model.page == .studio && model.studio.canRedo {
                    model.studio.redo()
                } else {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            // The plain Delete key works too while the Studio is open (StudioDeleteKey).
            if model.page == .ai {
                Button("Delete Result") {
                    if let id = model.aiStudio.selectedResult, let a = model.asset(id) { model.aiStudio.deleteResult(a, model: model) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.aiStudio.selectedResult == nil)
            } else if model.page == .media {
                Button("Delete…") { model.mediaPendingDelete = Array(model.mediaSelection) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.mediaSelection.isEmpty)
            } else {
                Button("Delete Layer") { model.studio.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.page != .studio || !model.studio.canDeleteSelection)
            }
        }
        CommandMenu("Go") {
            ForEach(Array(AppPage.allCases.enumerated()), id: \.element) { i, page in
                if i < 9 {
                    Button(page.title) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                } else {
                    Button(page.title) { model.page = page }
                }
            }
        }
        CommandMenu("Publishing") {
            Button("Sync with Publishing Service") { Task { await model.sync(); await model.refreshAccounts() } }
                .keyboardShortcut("r")
            Button("Check Publishing Service") { Task { await model.checkBackend() } }
            Button("Connections") { model.page = .accounts }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Picker("Appearance", selection: Binding(get: { ThemeStore.shared.mode }, set: { ThemeStore.shared.mode = $0 })) {
                ForEach(ThemeStore.Mode.allCases) { Text($0.title).tag($0) }
            }
        }
        CommandMenu("Assistant") {
            Button("Ask SocialForge…") { model.showCommandPanel = true }
                .keyboardShortcut("j")
            Button("Connect Claude or Codex…") { model.settingsTab = .agents; model.page = .settings }
                .keyboardShortcut("j", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        ThemeStore.shared.applyMode()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where the data lives: ~/Library/Application Support/SocialForge/SocialForge.store
enum Store {
    /// Non-nil when the store could not open cleanly and was backed up before recovery.
    @MainActor static var recoveryNotice: String?

    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    nonisolated static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "SocialForge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appending(path: "SocialForge.store")
    }

    /// Where agents' requests wait for the app (`SocialForge --mcp`): next to the store.
    static var inboxURL: URL {
        if isOverridden { return url.deletingLastPathComponent().appending(path: url.lastPathComponent + "-inbox", directoryHint: .isDirectory) }
        return url.deletingLastPathComponent().appending(path: "Agent Inbox", directoryHint: .isDirectory)
    }

    /// Creates a backup copy of the SQLite store + WAL/SHM files without deleting user data.
    static func backupStore(at storeURL: URL, label: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }
        let stamp = ISO8601.format(.now).replacingOccurrences(of: ":", with: "-")
        let backupDir = storeURL.deletingLastPathComponent().appending(path: "Backups/\(label)-\(stamp)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: storeURL.path + suffix)
                if fm.fileExists(atPath: src.path) {
                    let dst = backupDir.appending(path: src.lastPathComponent)
                    try fm.copyItem(at: src, to: dst)
                }
            }
            return backupDir
        } catch {
            return nil
        }
    }

    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = SwiftData.Schema(AppSchema.models)
        let config = ModelConfiguration(url: url)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Preserve the original store in Backups/ rather than deleting user data.
            let backup = backupStore(at: url, label: "migration-recovery")
            let msg = "SocialForge could not open the existing database at \(url.path) (\(error.localizedDescription)). "
                + (backup.map { "A full backup was saved to \($0.path). " } ?? "")
                + "A safe temporary in-memory library was opened so your files on disk remain untouched."
            recoveryNotice = msg
            fputs("SocialForge store error: \(msg)\n", stderr)
            if let fallback = try? ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
                return fallback
            }
            fatalError(msg)
        }
    }
}

/// File > Import Media: folders, images, and a CSV in one panel.
enum ImportPanel {
    @MainActor
    static func run(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MediaFormats.images + MediaFormats.videos + MediaFormats.audio + [.commaSeparatedText, .folder]
        panel.message = "Choose images, videos, music, folders, or a CSV. Files are copied into SocialForge; the originals are not changed."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { _ = await model.importMedia(urls) }
    }
}

/// File > Save Sample CSV: the reference layout for a folder of images with links.
enum SampleCSVPanel {
    @MainActor
    static func run() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SampleCSV.filename
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "One row per image: filename matches the image's file name, url is where its post links. Title, description, and alt text are optional."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SampleCSV.text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

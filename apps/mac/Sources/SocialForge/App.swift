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

@main
enum Entry {
    static func main() {
        if PublishAgent.requested { PublishAgent.run() }
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
            Button("New Workspace…") { model.showNewWorkspace = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Import Media…") { model.page = .media; ImportPanel.run(model: model) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("New Bulk Run") { model.page = .bulk }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("New Design") {
                model.page = .studio
                model.studio.openNew(model: model)
            }
            Button("New Post in Composer") {
                model.page = .composer
                model.composer.startNew(model: model)
            }
            .keyboardShortcut("n")
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.studio.undo() }
                .keyboardShortcut("z")
                .disabled(model.page != .studio || !model.studio.canUndo)
            Button("Redo") { model.studio.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.page != .studio || !model.studio.canRedo)
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
        }
        CommandGroup(after: .sidebar) {
            Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") { model.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Assistant") {
            Button("Ask SocialForge…") { model.showCommandPanel = true }
                .keyboardShortcut("j")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Where the data lives: ~/Library/Application Support/SocialForge/SocialForge.store
enum Store {
    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let dir = URL.applicationSupportDirectory.appending(path: "SocialForge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "SocialForge.store")
    }

    static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: SwiftData.Schema(AppSchema.models), configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Could not open the database at \(url.path): \(error)")
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
        panel.allowedContentTypes = MediaFormats.images + MediaFormats.videos + [.commaSeparatedText, .folder]
        panel.message = "Choose images, folders, or a CSV. Files are copied into SocialForge; the originals are not changed."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { _ = await model.importMedia(urls) }
    }
}

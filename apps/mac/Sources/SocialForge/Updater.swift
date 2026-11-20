import AppKit
import SwiftUI
import SocialForgeKit

// Updates from GitHub releases, the same way ForgeDeck updates: a daily check of
// releases/latest, an Update button and a sheet that asks first, then download
// from GitHub only, verify the signature and team, swap the app (old one to the
// Trash), and relaunch. Data and Keychain items are not touched.

enum UpdateSettings {
    static let autoKey = "updates.auto"
    static let lastCheckKey = "updates.lastCheck"

    /// owner/name from Info.plist (SFUpdateRepository). Empty in a build without an update source.
    static var repository: String { Bundle.main.object(forInfoDictionaryKey: "SFUpdateRepository") as? String ?? "" }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var isAutomatic: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var lastCheck: Date? { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }

    static var version: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty || build == "__BUILD__" ? currentVersion : "\(currentVersion) (\(build))"
    }
}

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    var available: AppRelease?
    var showSheet = false
    var busy = false
    var progress: String?
    var message: String?

    /// Off in tests, snapshots, the background agent, and builds run outside an .app.
    var isEnabled: Bool {
        !Store.isOverridden && !PublishAgent.requested && !SelfTest.requested
            && Bundle.main.bundleURL.pathExtension == "app" && UpdateChecker.isValidRepository(UpdateSettings.repository)
    }

    /// At most once a day, quietly.
    func checkIfDue() {
        guard isEnabled, UpdateSettings.isAutomatic else { return }
        guard Date.now.timeIntervalSince(UpdateSettings.lastCheck ?? .distantPast) > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard isEnabled, !busy else {
            if userInitiated && !isEnabled { message = "Updates are off in development and test builds." }
            return
        }
        busy = true
        defer { busy = false }
        let result = await UpdateChecker(repository: UpdateSettings.repository).check(currentVersion: UpdateSettings.currentVersion)
        UserDefaults.standard.set(Date.now, forKey: UpdateSettings.lastCheckKey)
        switch result {
        case .available(let release):
            available = release
            if userInitiated { showSheet = true }
        case .upToDate(let latest):
            available = nil
            if userInitiated { message = "SocialForge \(UpdateSettings.currentVersion) is the newest version (latest release \(latest))." }
        case .noDownload(let why), .failed(let why):
            if userInitiated { message = why }
        }
    }

    /// Downloads, checks the signature, swaps the app in place (the old one goes to the Trash), and relaunches.
    func install(_ release: AppRelease) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let installer = UpdateInstaller()
        let work = URL.cachesDirectory.appending(path: "SocialForge/Update")
        let current = Bundle.main.bundleURL
        do {
            progress = "Downloading \(release.version)…"
            let zip = try await installer.download(release, into: work)
            progress = "Checking the signature…"
            let app = try await installer.unpack(zip, into: work)
            try await installer.verify(app, sameTeamAs: current)
            progress = "Installing…"
            var trashed: NSURL?
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
            do {
                try FileManager.default.moveItem(at: app, to: current)
            } catch {
                // Put the old app back so there is always one in place.
                if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
                throw error
            }
            try? FileManager.default.removeItem(at: work)
            progress = "Relaunching…"
            relaunch(current)
        } catch {
            progress = nil
            try? FileManager.default.removeItem(at: work)
            message = error.localizedDescription
        }
    }

    /// Quits, and opens the new copy once this one has exited.
    ///
    /// The sheet closes first: an open sheet refuses terminate. A small shell
    /// process waits for this process to end and then opens the app, so the new
    /// copy never starts while this one still runs. If something else refuses
    /// the quit, the waiter keeps waiting and the update opens when the person quits.
    private func relaunch(_ app: URL) {
        showSheet = false
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        let (tool, arguments) = UpdateInstaller.relaunchCommand(waitingFor: ProcessInfo.processInfo.processIdentifier, then: app)
        let waiter = Process()
        waiter.executableURL = URL(filePath: tool)
        waiter.arguments = arguments
        do {
            try waiter.run()
        } catch {
            progress = nil
            message = "SocialForge is updated. Quit and open it again to use the new version."
            return
        }
        // Let the sheet finish closing before asking to quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
            // Still here: the quit was refused. The new version opens when SocialForge quits.
            self.progress = nil
            self.message = "Quit SocialForge to finish updating. The new version opens as soon as it closes."
        }
    }
}

/// What is new, and the button that installs it.
struct UpdateSheet: View {
    let release: AppRelease
    @Environment(\.dismiss) private var dismiss
    private var updater: AppUpdater { AppUpdater.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 28)).foregroundStyle(DS.accent)
                Text("SocialForge \(release.version) is available").font(DS.display(26))
            }
            Text("You have \(UpdateSettings.currentVersion). The update is checked against this copy's signature before it replaces it, and the old app goes to the Trash. Your library, posts, settings, and Keychain items are not touched.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(release.notes.isEmpty ? "No release notes." : release.notes)
                    .font(DS.body).foregroundStyle(DS.textBody).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(Space.md)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            if let m = updater.message { Text(m).font(DS.small).foregroundStyle(DS.red) }
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(release.pageURL) }.buttonStyle(LinkButtonStyle())
                Spacer()
                Button("Later") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(updater.progress ?? "Install and Relaunch") { Task { await updater.install(release) } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(updater.busy)
            }
        }
        .padding(Space.xxl)
        .frame(width: 560)
        .background(DS.panel)
    }
}

/// The sidebar's Update button, shown when a newer release is out.
struct UpdateBanner: View {
    private var updater: AppUpdater { AppUpdater.shared }

    var body: some View {
        if let r = updater.available {
            Button { updater.showSheet = true } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(DS.onAccent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Update").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.onAccent)
                        Text("SocialForge \(r.version) is ready").font(DS.caption).foregroundStyle(DS.onAccent.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.sm)
                .background(DS.accentFill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See what is new and install it")
        }
    }
}

/// Settings › General: version, automatic checks, and Check Now.
struct UpdateSettingsView: View {
    @State private var automatic = UpdateSettings.isAutomatic
    private var updater: AppUpdater { AppUpdater.shared }

    var body: some View {
        SettingsGroup(title: "Updates", footer: updater.isEnabled
                      ? "Updates come from SocialForge's GitHub releases (\(UpdateSettings.repository)). Each one must carry the same Developer ID team signature as this copy before it installs."
                      : "Updates are off in development and test builds.") {
            KeyValueRow("Version", UpdateSettings.version)
            Toggle("Check for updates automatically", isOn: $automatic)
                .toggleStyle(SFToggleStyle()).font(DS.body)
                .onChange(of: automatic) { UpdateSettings.isAutomatic = automatic }
            HStack {
                Button(updater.busy ? "Checking…" : "Check Now") { Task { await updater.check(userInitiated: true) } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(updater.busy || !updater.isEnabled)
                if let last = UpdateSettings.lastCheck {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(DS.small).foregroundStyle(DS.text2)
                }
            }
            if let m = updater.message { Text(m).font(DS.small).foregroundStyle(DS.text2) }
        }
    }
}

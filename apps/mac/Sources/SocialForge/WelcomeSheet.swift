import AppKit
import SwiftUI
import SocialForgeKit

/// First launch: set up the first brand (or import one), then go to Accounts.
///
/// Shown once, for a new library only (`AppModel.needsBrandSetup`). Everything here
/// can be changed later in Brand Kits, and exported there as a .sfbrand file;
/// Skip for Now opens Accounts with the default workspace.
struct WelcomeSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var color = NewWorkspaceSheet.colors[0]
    @State private var voice = ""
    @State private var hashtags = ""
    @State private var logo: URL?
    /// nil: the app's library in Application Support.
    @State private var folder: URL?
    @State private var addMockAccount = false
    @State private var working = false

    private var folderLabel: String {
        guard let folder else { return "SocialForge's library (Application Support)" }
        return folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Welcome to SocialForge").font(DS.display(30))
                Text("Start with your brand. Templates, AI copy, and backgrounds follow it. Next you connect your accounts.")
                    .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            field("Brand name") {
                TextField("Company, brand, or client", text: $name).fieldStyle().onSubmit(create)
            }
            field("Accent color") {
                HStack(spacing: Space.sm) {
                    ForEach(NewWorkspaceSheet.colors, id: \.self) { c in
                        Button { color = c } label: {
                            Circle().fill(Color(hex: UInt32(c))).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(DS.text, lineWidth: color == c ? 2 : 0))
                        }
                        .buttonStyle(.plain).accessibilityLabel(String(format: "Color %06X", c))
                    }
                }
            }
            field("Logo (optional)") {
                HStack(spacing: Space.md) {
                    Group {
                        if let logo { Thumbnail(path: logo.path, maxPixel: 160, contentMode: .fit) }
                        else { Image(systemName: "seal").foregroundStyle(DS.text3) }
                    }
                    .frame(width: 48, height: 48)
                    .background(DS.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(logo == nil ? "Choose Logo…" : "Replace Logo…") { chooseLogo() }.buttonStyle(SecondaryButtonStyle())
                    if logo != nil { Button("Remove") { logo = nil }.buttonStyle(.plain).foregroundStyle(DS.text2) }
                }
            }
            field("Save files to") {
                HStack(spacing: Space.sm) {
                    Image(systemName: "folder").foregroundStyle(DS.text3)
                    Text(folderLabel).font(DS.body).foregroundStyle(DS.textBody).lineLimit(1).truncationMode(.middle)
                        .help(folder?.path ?? "Application Support/SocialForge/Library")
                    Spacer(minLength: Space.sm)
                    if folder == nil, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Documents/\(name.trimmingCharacters(in: .whitespaces))") { folder = AppModel.suggestedFolder(for: name) }
                            .buttonStyle(SecondaryButtonStyle()).lineLimit(1)
                            .help("Save this brand's files in a folder named after it in Documents")
                    }
                    Button("Choose…", action: chooseFolder).buttonStyle(SecondaryButtonStyle())
                    if folder != nil {
                        Button("Use Default") { folder = nil }.buttonStyle(.plain).foregroundStyle(DS.text2)
                    }
                }
            }
            field("Voice (optional)") {
                TextField("Voice", text: $voice, prompt: Text("Calm, tactile, never salesy"), axis: .vertical)
                    .lineLimit(2...3).fieldStyle()
            }
            field("Hashtags (optional)") {
                TextField("Hashtags", text: $hashtags, prompt: Text("handmade, slowliving, ceramics")).fieldStyle()
            }
            Toggle("Add a local mock account so I can test scheduling right away (nothing posts externally)", isOn: $addMockAccount)
                .toggleStyle(SFToggleStyle()).font(DS.body)
            HStack(spacing: Space.sm) {
                Image(systemName: "square.and.arrow.down").foregroundStyle(DS.text3)
                Text("Already have a brand kit? Import a .sfbrand file. You can export yours any time from Brand Kits.")
                    .font(DS.small).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Import Brand Kit…", action: importKit)
                    .buttonStyle(SecondaryButtonStyle()).disabled(working)
                Spacer()
                Button("Skip for Now") { model.finishBrandSetup() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(working ? "Setting Up…" : "Create Brand", action: create)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Space.xxl)
        .frame(width: 520)
        .background(DS.panel)
        .noInitialFocus()
        .interactiveDismissDisabled()
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(DS.small).foregroundStyle(DS.text2)
            content()
        }
    }

    private func create() {
        guard canCreate else { return }
        working = true
        let tags = hashtags.split(separator: ",").map(String.init)
        Task {
            await model.completeBrandSetup(name: name, colorHex: color, voice: voice, hashtags: tags, logo: logo, folder: folder)
            if addMockAccount { model.addMockAccount() }
            working = false
        }
    }

    private func importKit() {
        guard let kit = BrandKitIO.importKit(model: model) else { return }
        model.completeBrandImport(kit)
    }

    /// Starts in Documents, proposing a folder named after the brand.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where this brand's imports, exports, and AI generations are saved."
        panel.directoryURL = URL.documentsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Choose your logo. It is copied into SocialForge; a PNG with transparency works best."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        logo = url
    }
}

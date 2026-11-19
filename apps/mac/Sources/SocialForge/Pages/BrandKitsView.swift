import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

struct BrandKitsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \BrandKit.name) private var allKits: [BrandKit]
    @Query(sort: \CreativeTemplate.createdAt) private var allTemplates: [CreativeTemplate]

    private var kits: [BrandKit] { allKits.filter { $0.workspaceID == model.workspaceID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Brand kits").font(DS.display(30))
                        Text("Colors, fonts, logo, and voice. Templates and AI copy follow the kit, so changing it restyles everything at once.")
                            .foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button("Import…") { BrandKitIO.importKit(model: model) }.buttonStyle(SecondaryButtonStyle())
                    Button("New Brand Kit", action: add).buttonStyle(PrimaryButtonStyle())
                }
                if kits.isEmpty {
                    EmptyState(symbol: "swatchpalette", title: "No brand kit yet", message: "Add your colors, fonts, logo, and voice. Creative Studio templates use them automatically.") {
                        Button("New Brand Kit", action: add).buttonStyle(PrimaryButtonStyle())
                    }
                    .frame(height: 320)
                }
                ForEach(kits) { k in
                    KitCard(kit: k, selected: model.brandKitSelection == k.uuid)
                        .onTapGesture { model.brandKitSelection = k.uuid }
                        .contextMenu {
                            Button("Export…") { BrandKitIO.export(k, templates: allTemplates.filter { $0.workspaceID == k.workspaceID }) }
                            Button("Delete", role: .destructive) { model.context.delete(k); try? model.context.save() }
                        }
                }
                if !kits.isEmpty {
                    Text("Templates").font(.system(size: 15, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.lg)], spacing: Space.lg) {
                        ForEach(allTemplates.filter { $0.workspaceID == model.workspaceID }) { t in TemplateTile(template: t, large: true) }
                    }
                }
            }
            .padding(Space.xxl)
        }
        .onAppear { if model.brandKitSelection == nil { model.brandKitSelection = kits.first?.uuid }; model.ensureBuiltInTemplates() }
    }

    private func add() {
        guard let ws = model.workspaceID else { return }
        let k = BrandKit(workspaceID: ws, name: model.workspace?.name ?? "Brand")
        k.colors = [0x2A211C, 0xF4EFE8, model.workspace?.colorHex ?? 0xFF8A5C, 0x7A5C48, 0xC9B8A6]
        k.headlineFont = FontRegistry.hasInstrumentSerif ? "Instrument Serif" : "Baskerville"
        model.context.insert(k)
        try? model.context.save()
        model.brandKitSelection = k.uuid
    }
}

struct KitCard: View {
    let kit: BrandKit
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    if !kit.logoPath.isEmpty {
                        Thumbnail(path: kit.logoPath, maxPixel: 160, contentMode: .fit).frame(width: 56, height: 56)
                            .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        WorkspaceBadge(name: kit.name, colorHex: kit.colors.dropFirst(2).first ?? 0xFF8A5C, size: 56)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kit.name).font(.custom(kit.headlineFont, size: 28))
                        Text("\(kit.headlineFont) · \(kit.bodyFont) · \(kit.colors.count) colors").font(DS.small).foregroundStyle(DS.text2)
                    }
                }
                HStack(spacing: 0) { ForEach(kit.colors, id: \.self) { Rectangle().fill(Color(hex: UInt32($0))) } }
                    .frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if !kit.voice.isEmpty { Text("Voice: \(kit.voice)").font(DS.body).foregroundStyle(DS.textBody) }
                if !kit.ctas.isEmpty || !kit.hashtags.isEmpty {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(kit.ctas, id: \.self) { Chip(text: $0) }
                        ForEach(kit.hashtags, id: \.self) { Chip(text: "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
                    }
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Headline").font(DS.caption).foregroundStyle(DS.text3)
                Text("Slow mornings").font(.custom(kit.headlineFont, size: 34)).foregroundStyle(DS.text)
                Text("Body").font(DS.caption).foregroundStyle(DS.text3).padding(.top, Space.sm)
                Text("Hand-thrown stoneware, made in small batches.").font(.custom(kit.bodyFont, size: 14)).foregroundStyle(DS.textBody)
            }
            .frame(width: 280, alignment: .leading)
        }
        .card(padding: Space.xl, selected: selected)
    }
}

struct BrandKitInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var allKits: [BrandKit]

    var body: some View {
        if let kit = allKits.first(where: { $0.uuid == model.brandKitSelection }) {
            KitEditor(kit: kit)
        } else {
            VStack(spacing: 0) {
                PanelHeader(title: "Brand kit")
                Divider().overlay(DS.stroke)
                EmptyState(symbol: "swatchpalette", title: "No kit selected", message: "Pick a brand kit to edit it.")
            }
        }
    }
}

struct KitEditor: View {
    @Bindable var kit: BrandKit
    @Environment(AppModel.self) private var model
    @State private var ctaText = ""
    @State private var tagText = ""
    private static let fonts = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Brand kit") { Text(kit.name) }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Identity")
                    TextField("Name", text: $kit.name).fieldStyle()
                    HStack(spacing: Space.md) {
                        Group {
                            if kit.logoPath.isEmpty { Image(systemName: "seal").foregroundStyle(DS.text3) }
                            else { Thumbnail(path: kit.logoPath, maxPixel: 160, contentMode: .fit) }
                        }
                        .frame(width: 56, height: 56).background(DS.fill, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Button(kit.logoPath.isEmpty ? "Add Logo…" : "Replace Logo…") { chooseLogo() }.buttonStyle(SecondaryButtonStyle())
                            if !kit.logoPath.isEmpty { Button("Remove") { kit.logoPath = "" }.buttonStyle(.plain).foregroundStyle(DS.text2).font(DS.small) }
                        }
                    }
                    Text("A PNG with transparency works best. Templates place it in their logo slot.").font(DS.caption).foregroundStyle(DS.text3)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Colors")
                    Text("Color 1 is ink (text), 2 is paper, 3 is the accent. Templates refer to them by number.").font(DS.caption).foregroundStyle(DS.text3)
                    ForEach(kit.colors.indices, id: \.self) { i in
                        HStack {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: UInt32(kit.colors[i])) },
                                set: { c in
                                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
                                    kit.colors[i] = Int(ns.redComponent * 255) << 16 | Int(ns.greenComponent * 255) << 8 | Int(ns.blueComponent * 255)
                                    model.aiRevision += 1
                                }))
                            .labelsHidden()
                            Text("Brand \(i + 1) · \(i == 0 ? "ink" : i == 1 ? "paper" : i == 2 ? "accent" : "extra")").font(DS.body)
                            Spacer()
                            Text(String(format: "#%06X", kit.colors[i])).font(DS.mono).foregroundStyle(DS.text2)
                        }
                    }
                    HStack {
                        Button("Add Color") { kit.colors.append(0x888888) }.buttonStyle(SecondaryButtonStyle())
                        Button("Remove Last") { _ = kit.colors.popLast() }.buttonStyle(SecondaryButtonStyle()).disabled(kit.colors.count <= 3)
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Type")
                    fontPicker("Headline", $kit.headlineFont)
                    fontPicker("Body", $kit.bodyFont)
                    if !FontCheck.isInstalled(kit.headlineFont) || !FontCheck.isInstalled(kit.bodyFont) {
                        Text("A font in this kit is not installed on this Mac. Exports that use it are blocked rather than silently changed.")
                            .font(DS.small).foregroundStyle(DS.red)
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Voice and guidance")
                    TextField("Voice", text: $kit.voice, prompt: Text("Calm, tactile, never salesy"), axis: .vertical).lineLimit(2...4).fieldStyle()
                    TextField("Audience", text: $kit.audience, axis: .vertical).lineLimit(1...3).fieldStyle()
                    TextField("Never say", text: $kit.avoid, prompt: Text("Exclamation marks, “best ever”, health claims"), axis: .vertical).lineLimit(1...3).fieldStyle()
                    TextField("Preferred image style", text: $kit.imageStyle, prompt: Text("Warm natural light, linen, oak, negative space"), axis: .vertical).lineLimit(1...3).fieldStyle()
                    TextField("Calls to action (comma separated)", text: $ctaText).fieldStyle().onSubmit { kit.ctas = split(ctaText) }
                    TextField("Approved hashtags (comma separated)", text: $tagText).fieldStyle().onSubmit { kit.hashtags = split(tagText) }
                    Text("AI copy and backgrounds use the voice, audience, things to avoid, image style, CTAs, and hashtags.").font(DS.caption).foregroundStyle(DS.text3)
                }
            }
        }
        .onAppear { ctaText = kit.ctas.joined(separator: ", "); tagText = kit.hashtags.joined(separator: ", ") }
        .onDisappear { kit.ctas = split(ctaText); kit.hashtags = split(tagText); try? model.context.save() }
    }

    private func fontPicker(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).font(DS.body).foregroundStyle(DS.text2).frame(width: 72, alignment: .leading)
            Picker("", selection: binding) {
                if !Self.fonts.contains(binding.wrappedValue) { Text("\(binding.wrappedValue) (not installed)").tag(binding.wrappedValue) }
                ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Choose your logo. It is copied into SocialForge."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let a = await model.importMedia([url]).first {
                a.collection = "Brand"
                kit.logoPath = a.storedPath
            } else if let existing = (try? model.context.fetch(FetchDescriptor<MediaAsset>()))?.first(where: { $0.sourcePath == url.path }) {
                kit.logoPath = existing.storedPath
            }
            try? model.context.save()
        }
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Brand kits as portable JSON (.sfbrand): kit fields plus its templates. Logos are embedded as PNG data.
enum BrandKitIO {
    struct Bundle: Codable {
        var name: String
        var colors: [Int]
        var headlineFont: String
        var bodyFont: String
        var voice: String
        var audience: String
        var avoid: String
        var imageStyle: String
        var ctas: [String]
        var hashtags: [String]
        var logoPNG: Data?
        var templates: [Data]
    }

    @MainActor
    static func export(_ k: BrandKit, templates: [CreativeTemplate]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = k.name + ".sfbrand"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let logo = k.logoPath.isEmpty ? nil : try? Data(contentsOf: URL(fileURLWithPath: k.logoPath))
        let b = Bundle(name: k.name, colors: k.colors, headlineFont: k.headlineFont, bodyFont: k.bodyFont, voice: k.voice, audience: k.audience,
                       avoid: k.avoid, imageStyle: k.imageStyle, ctas: k.ctas, hashtags: k.hashtags, logoPNG: logo, templates: templates.map(\.json))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(b).write(to: url)
    }

    @MainActor
    static func importKit(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let b = try? JSONDecoder().decode(Bundle.self, from: data), let ws = model.workspaceID else {
            model.lastError = "That file is not a SocialForge brand kit."
            return
        }
        let k = BrandKit(workspaceID: ws, name: b.name)
        k.colors = b.colors; k.headlineFont = b.headlineFont; k.bodyFont = b.bodyFont; k.voice = b.voice; k.audience = b.audience
        k.avoid = b.avoid; k.imageStyle = b.imageStyle; k.ctas = b.ctas; k.hashtags = b.hashtags
        model.context.insert(k)
        for t in b.templates { if let doc = try? CreativeDocument.from(json: t) { model.context.insert(CreativeTemplate(workspaceID: ws, document: doc, category: StudioModel.category(for: doc))) } }
        try? model.context.save()
        model.brandKitSelection = k.uuid
        if let png = b.logoPNG {
            let tmp = FileManager.default.temporaryDirectory.appending(path: "\(b.name)-logo.png")
            try? png.write(to: tmp)
            Task { if let a = await model.importMedia([tmp]).first { k.logoPath = a.storedPath; try? model.context.save() } }
        }
    }
}

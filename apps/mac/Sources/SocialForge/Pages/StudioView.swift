import AppKit
import SwiftData
import SwiftUI
import SocialForgeKit

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: NSImage?
    @State private var dragStart: [UUID: CGPoint] = [:]
    @State private var showSaveTemplate = false
    @State private var templateName = ""

    private var studio: StudioModel { model.studio }

    var body: some View {
        Group {
            if let doc = studio.document {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        canvasArea(doc)
                        SmartResizeStrip()
                    }
                    LayersPanel().padding(Space.lg)
                }
                .task(id: studio.revision &+ model.aiRevision &+ (model.brandKit?.colors.hashValue ?? 0)) { await render() }
            } else {
                StudioGallery()
            }
        }
        .onAppear { model.ensureBuiltInTemplates() }
        .alert("Save as brand template", isPresented: $showSaveTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save") { studio.saveAsTemplate(model: model, name: templateName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text, colors, fonts, and the logo stay tied to the brand kit; the photo becomes a slot you fill per image.")
        }
    }

    private func canvasArea(_ doc: CreativeDocument) -> some View {
        VStack(spacing: Space.md) {
            ToolBar(saveAsTemplate: { templateName = doc.name; showSaveTemplate = true })
            HStack {
                Text("\(StudioModel.category(for: doc)) · \(doc.width) × \(doc.height)").font(DS.small).foregroundStyle(DS.text2)
                if studio.templateID != nil {
                    Text("Brand template").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.accent)
                        .padding(.horizontal, Space.sm).padding(.vertical, 2).background(DS.accentSoft, in: Capsule())
                }
                Spacer()
            }
            .frame(width: Double(doc.width) * studio.zoom)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(DS.fillStrong)
                    }
                    ForEach(doc.layers.filter { !$0.isHidden }) { layer in
                        hitArea(layer)
                    }
                    if let sel = studio.selected, !sel.isHidden { selection(sel) }
                }
                .frame(width: Double(doc.width) * studio.zoom, height: Double(doc.height) * studio.zoom)
                .clipped()
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(Space.section)
                .frame(maxWidth: .infinity)
            }
            if let msg = studio.exportMessage ?? studio.busy {
                HStack {
                    if studio.busy != nil { ProgressView().controlSize(.small) }
                    Text(msg).font(DS.small).foregroundStyle(DS.textBody)
                    Spacer()
                    if studio.busy == nil { Button("Dismiss") { studio.exportMessage = nil }.buttonStyle(.plain).foregroundStyle(DS.text2) }
                }
                .card(padding: Space.md)
                .padding(.horizontal, Space.xxl)
            }
        }
        .padding(.top, Space.lg)
        // Leave room for the floating Layers panel on the left.
        .padding(.leading, 236)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The design's dotted canvas.
            Canvas { ctx, size in
                let step: CGFloat = 20
                for x in stride(from: 0, to: size.width, by: step) {
                    for y in stride(from: 0, to: size.height, by: step) {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(DS.text3.opacity(0.25)))  // grid: ok canvas pixels or computed position
                    }
                }
            }
            .background(DS.canvas)
        }
    }

    /// Click to select; drag to move (one undo step per drag, groups move together).
    private func hitArea(_ layer: CreativeLayer) -> some View {
        let z = studio.zoom
        return Rectangle().fill(.clear).contentShape(Rectangle())
            .frame(width: layer.width * z, height: layer.height * z)
            .offset(x: layer.x * z, y: layer.y * z)  // grid: ok canvas coordinates
            .onTapGesture { studio.selectedLayer = layer.id }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    guard !layer.isLocked else { return }
                    studio.selectedLayer = layer.id
                    let prev = dragStart[layer.id] ?? .zero
                    let now = CGPoint(x: g.translation.width / z, y: g.translation.height / z)
                    if dragStart[layer.id] == nil, let d = studio.document { model.studio.beginDrag(d) }
                    studio.moveLayer(layer.id, dx: now.x - prev.x, dy: now.y - prev.y, recordUndo: false)
                    dragStart[layer.id] = now
                }
                .onEnded { _ in
                    dragStart[layer.id] = nil
                    studio.endDrag()
                })
    }

    private func selection(_ layer: CreativeLayer) -> some View {
        let z = studio.zoom
        let isText = { if case .text = layer.content { true } else { false } }()
        return ZStack(alignment: .topLeading) {
            Rectangle().strokeBorder(DS.accentFill, style: StrokeStyle(lineWidth: 2, dash: layer.isLocked ? [4, 3] : []))
                .frame(width: layer.width * z, height: layer.height * z)
            ForEach(0..<4, id: \.self) { i in
                Rectangle().fill(.white).frame(width: 8, height: 8).overlay(Rectangle().strokeBorder(DS.accentFill, lineWidth: 2))
                    .offset(x: (i % 2 == 0 ? 0 : layer.width * z) - 4, y: (i < 2 ? 0 : layer.height * z) - 4)  // grid: ok handle positions
            }
            if isText {
                Text("Text · editable").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(DS.accentFill, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .offset(x: layer.width * z + 12, y: 0)  // grid: ok tag beside the layer
            }
        }
        .offset(x: layer.x * z, y: layer.y * z)  // grid: ok canvas coordinates
        .allowsHitTesting(false)
    }

    private func render() async {
        guard let doc = studio.rendered(brand: model.brandKit?.style) else { return }
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            try? CreativeRenderer.render(doc, scale: 0.6, allowFallbackFonts: true)
        }.value
        if let img { preview = NSImage(cgImage: img, size: NSSize(width: doc.width, height: doc.height)) }
    }
}

extension StudioModel {
    /// A drag edits without undo steps, then records one step for the whole drag.
    func beginDrag(_ before: CreativeDocument) { dragOrigin = before }
    func endDrag() {
        guard let origin = dragOrigin, let now = document, origin != now else { dragOrigin = nil; return }
        document = origin
        change { $0 = now }
        dragOrigin = nil
    }
}

/// The design's floating tool bar: select, text, shape, image, AI, resize, zoom.
struct ToolBar: View {
    @Environment(AppModel.self) private var model
    let saveAsTemplate: () -> Void

    var body: some View {
        let studio = model.studio
        HStack(spacing: Space.md) {
            HStack(spacing: 2) {
                tool(.select, "cursorarrow", "Select and move (V)") {}
                tool(.text, "textformat", "Add a text layer (T)") { studio.addText(model: model) }
                tool(.shape, "square", "Add a shape (R)") { studio.addShape() }
                Menu {
                    Button("Image from Library Selection") {
                        if let a = model.assets(model.mediaSelection).first { studio.addImage(path: a.storedPath) }
                    }
                    .disabled(model.mediaSelection.isEmpty)
                    Button("Image from File…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = MediaFormats.images
                        if p.runModal() == .OK, let u = p.url {
                            Task { if let a = await model.importMedia([u]).first { studio.addImage(path: a.storedPath) } }
                        }
                    }
                    Button("Photo Slot (filled per image)") { studio.addImage(path: "", role: "photo") }
                    Button("Brand Logo") { studio.addLogo(model: model) }
                } label: { Image(systemName: "photo") }
                .menuStyle(.button).buttonStyle(IconButtonStyle(selected: studio.tool == .image)).menuIndicator(.hidden).fixedSize()
                .help("Add an image, a photo slot, or the logo")
                tool(.ai, "wand.and.stars", "Generate an AI background in AI Studio") {
                    model.aiStudio.sendToStudio = true
                    model.page = .ai
                }
                Menu {
                    ForEach(CanvasPreset.all) { p in Button("\(p.name) · \(p.width) × \(p.height)") { studio.resize(to: p) } }
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .menuStyle(.button).buttonStyle(IconButtonStyle(selected: studio.tool == .resize)).menuIndicator(.hidden).fixedSize()
                .help("Resize the canvas for another platform (text stays live)")
                Divider().frame(height: 20).padding(.horizontal, Space.xs)
                Menu {
                    ForEach([0.25, 0.36, 0.5, 0.75, 1.0], id: \.self) { z in Button("\(Int(z * 100))%") { model.studio.zoom = z } }
                } label: { Text("\(Int(studio.zoom * 100))%").font(DS.small).monospacedDigit().foregroundStyle(DS.text2) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().padding(.horizontal, Space.sm)
            }
            .padding(Space.xs)
            .background(DS.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.stroke))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            HStack(spacing: Space.xs) {
                Button("Undo", systemImage: "arrow.uturn.backward") { studio.undo() }.labelStyle(.iconOnly).buttonStyle(IconButtonStyle()).disabled(!studio.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { studio.redo() }.labelStyle(.iconOnly).buttonStyle(IconButtonStyle()).disabled(!studio.canRedo)
                Menu("Save") {
                    Button(studio.templateID != nil ? "Save Template" : "Save Design") { studio.save(model: model) }
                    Button("Save as Brand Template…", action: saveAsTemplate)
                    Divider()
                    Button("Close") { studio.document = nil }
                }
                .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
                .background { Button("") { studio.save(model: model) }.keyboardShortcut("s").opacity(0) }
                Button("Export") { Task { _ = await studio.export(model: model) } }.buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut("e")
                    .help("Render with real fonts and add the PNG to the Media Library")
            }
        }
    }

    private func tool(_ t: StudioModel.Tool, _ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button { model.studio.tool = t; action() } label: { Image(systemName: symbol) }
            .buttonStyle(IconButtonStyle(selected: model.studio.tool == t))
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The design's floating Layers panel.
struct LayersPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let studio = model.studio
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Layers").font(DS.bodyMedium).foregroundStyle(DS.text2)
                Spacer()
                Menu {
                    Button("Text") { studio.addText(model: model) }
                    Button("Shape") { studio.addShape() }
                    Button("Photo Slot") { studio.addImage(path: "", role: "photo") }
                    Button("Brand Logo") { studio.addLogo(model: model) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().foregroundStyle(DS.text2)
            }
            .padding(.horizontal, Space.sm).padding(.bottom, Space.xs)
            ForEach((studio.document?.layers ?? []).reversed()) { layer in
                let selected = studio.selectedLayer == layer.id
                HStack(spacing: Space.sm) {
                    Image(systemName: icon(layer)).font(.system(size: 12)).foregroundStyle(selected ? DS.accent : DS.text2).frame(width: 16)
                    Text(layer.name).font(DS.body).foregroundStyle(layer.isHidden ? DS.text3 : DS.text).lineLimit(1)
                    if layer.group != nil { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(DS.text3) }
                    Spacer()
                    Text(kind(layer)).font(DS.caption).foregroundStyle(DS.text3)
                    if layer.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(DS.text3) }
                }
                .padding(.horizontal, Space.sm).frame(height: 32)
                .background(selected ? DS.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { studio.selectedLayer = layer.id }
                .contextMenu {
                    Button(layer.isHidden ? "Show" : "Hide") { studio.changeLayer(layer.id) { $0.isHidden.toggle() } }
                    Button(layer.isLocked ? "Unlock" : "Lock") { studio.changeLayer(layer.id) { $0.isLocked.toggle() } }
                    Button(layer.group == nil ? "Group with Layer Below" : "Ungroup") { studio.toggleGroup(layer.id) }
                    Button("Duplicate") { studio.duplicateLayer(layer.id) }
                    Button("Bring Forward") { studio.move(layer.id, by: 1) }
                    Button("Send Backward") { studio.move(layer.id, by: -1) }
                    Divider()
                    Button("Delete", role: .destructive) { studio.delete(layer.id) }.disabled(layer.isLocked)
                }
            }
        }
        .padding(Space.sm)
        .frame(width: 220)
        .background(DS.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(DS.stroke))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .onDeleteCommand { if let id = studio.selectedLayer { studio.delete(id) } }
    }

    private func icon(_ l: CreativeLayer) -> String {
        switch l.content {
        case .text: "textformat"
        case .shape: "square"
        case .image(let i): i.role == "logo" ? "seal" : i.role == "photo" ? "photo.on.rectangle" : "photo"
        }
    }

    private func kind(_ l: CreativeLayer) -> String {
        switch l.content {
        case .text: "Text"
        case .shape: "Shape"
        case .image(let i): i.role == "logo" ? "Logo" : i.role == "photo" ? "Photo slot" : "Image"
        }
    }
}

/// The design's Smart resize strip: every platform size, rendered from the same live document.
struct SmartResizeStrip: View {
    @Environment(AppModel.self) private var model
    @State private var thumbs: [String: NSImage] = [:]

    var body: some View {
        let studio = model.studio
        HStack(alignment: .bottom, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart resize").font(DS.bodyMedium)
                Text("Text layers stay live. Layout scales to each size; nothing is regenerated.").font(DS.small).foregroundStyle(DS.text2)
                    .frame(width: 200, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: Space.lg) {
                    ForEach(CanvasPreset.all) { p in
                        let current = studio.document.map { $0.width == p.width && $0.height == p.height } ?? false
                        Button { studio.resize(to: p) } label: {
                            VStack(spacing: Space.xs) {
                                Group {
                                    if let img = thumbs[p.id] { Image(nsImage: img).resizable() } else { Rectangle().fill(DS.fillStrong) }
                                }
                                .frame(width: 72 * min(1, Double(p.width) / Double(p.height)), height: 72 * min(1, Double(p.height) / Double(p.width)))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(current ? DS.accentFill : DS.stroke, lineWidth: current ? 2 : 1))
                                Text("\(p.name) · \(p.ratio)").font(DS.caption).foregroundStyle(current ? DS.text : DS.text2)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Switch this design to \(p.width) × \(p.height)")
                    }
                }
            }
            Button { Task { await studio.generateAllSizes(model: model) } } label: {
                Label("Generate all sizes", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(studio.busy != nil)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .background(DS.main)
        .overlay(alignment: .top) { Divider().overlay(DS.stroke) }
        .task(id: studio.revision) { await renderThumbs() }
    }

    private func renderThumbs() async {
        guard let doc = model.studio.rendered(brand: model.brandKit?.style) else { return }
        try? await Task.sleep(for: .milliseconds(250))
        for p in CanvasPreset.all {
            let resized = doc.resized(width: p.width, height: p.height)
            let scale = 160.0 / Double(max(p.width, p.height))
            if let img = await Task.detached(priority: .utility, operation: { try? CreativeRenderer.render(resized, scale: scale, allowFallbackFonts: true) }).value {
                thumbs[p.id] = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        }
    }
}

/// No document open: templates and saved designs.
struct StudioGallery: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Design.updatedAt, order: .reverse) private var allDesigns: [Design]
    @Query(sort: \CreativeTemplate.createdAt) private var allTemplates: [CreativeTemplate]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Brand templates").font(DS.display(30))
                        Text("Text, colors, fonts, and logo follow the brand kit. Open one to edit it, or start a design from it.").foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button("New Design") { model.studio.openNew(model: model) }.buttonStyle(PrimaryButtonStyle())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(allTemplates.filter { $0.workspaceID == model.workspaceID }) { t in TemplateTile(template: t, large: true) }
                }
                let designs = allDesigns.filter { $0.workspaceID == model.workspaceID }
                if !designs.isEmpty {
                    Text("Designs").font(.system(size: 15, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.lg)], spacing: Space.lg) {
                        ForEach(designs) { d in
                            Button { if let doc = d.document { model.studio.open(doc, designID: d.uuid) } } label: {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    DesignThumb(doc: d.document).frame(height: 200)
                                    Text(d.name).font(DS.bodyMedium).lineLimit(1)
                                    Text(d.updatedAt, format: .relative(presentation: .named)).font(DS.small).foregroundStyle(DS.text2)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", role: .destructive) { model.context.delete(d); try? model.context.save() }
                            }
                        }
                    }
                }
            }
            .padding(Space.xxl)
        }
    }
}

/// A template card: thumbnail with the brand applied; click to start a design, menu to edit.
struct TemplateTile: View {
    let template: CreativeTemplate
    var large = false
    var selected = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            DesignThumb(doc: template.document?.applyingBrand(model.brandKit?.style ?? BrandStyle(palette: [], headlineFont: "", bodyFont: ""))
                .withPhoto(model.assets(model.mediaSelection).first?.storedPath ?? sampleImage),
                        values: model.studio.previewValues.merging(["brand": model.brandKit?.name ?? model.workspace?.name ?? ""]) { _, new in new })
                .frame(height: large ? 260 : 150)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? DS.accentFill : .clear, lineWidth: 2))
            Text(template.name).font(large ? DS.bodyMedium : DS.small).foregroundStyle(DS.text).lineLimit(1)
            if large { Text(template.category).font(DS.small).foregroundStyle(DS.text2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { startDesign() }
        .contextMenu {
            Button("New Design from Template") { startDesign() }
            Button("Edit Template") {
                if let doc = template.document { model.studio.open(doc, designID: nil, templateID: template.uuid); model.page = .studio }
            }
            Button("Duplicate") {
                if var doc = template.document, let ws = model.workspaceID {
                    doc.name += " copy"
                    model.context.insert(CreativeTemplate(workspaceID: ws, document: doc, category: template.category))
                    try? model.context.save()
                }
            }
            Button("Export Template…") { TemplateIO.export(template) }
            Divider()
            Button("Delete Template", role: .destructive) { model.context.delete(template); try? model.context.save() }
        }
        .help("Click to start a design from “\(template.name)”. Right-click to edit the template itself.")
    }

    private var sampleImage: String {
        (try? model.context.fetch(FetchDescriptor<MediaAsset>()))?.first { $0.workspaceID == model.workspaceID }?.storedPath ?? ""
    }

    private func startDesign() {
        guard var doc = template.document else { return }
        doc.name = template.name + " design"
        if let a = model.assets(model.mediaSelection).first, doc.hasPhotoSlot { doc = doc.withPhoto(a.storedPath) }
        else if !sampleImage.isEmpty, doc.hasPhotoSlot { doc = doc.withPhoto(sampleImage) }
        model.studio.open(doc, designID: nil)
        model.page = .studio
    }
}

struct DesignThumb: View {
    let doc: CreativeDocument?
    var values: [String: String] = [:]
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(DS.fillStrong)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: (try? doc?.json())?.hashValue ?? 0) {
            guard let doc = doc?.filled(values) else { return }
            let scale = 360.0 / Double(max(doc.width, doc.height))
            if let img = await Task.detached(operation: { try? CreativeRenderer.render(doc, scale: scale, allowFallbackFonts: true) }).value {
                image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            }
        }
    }
}

enum TemplateIO {
    /// Saves a template as a .sftemplate JSON file (layers, roles, sizes; no images).
    @MainActor
    static func export(_ t: CreativeTemplate) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = t.name + ".sftemplate"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? t.json.write(to: url)
    }

    @MainActor
    static func importTemplate(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              var doc = try? CreativeDocument.from(json: data), let ws = model.workspaceID else {
            return
        }
        // Imported images are not carried over; fixed images become empty photo slots.
        doc.layers = doc.layers.map { l in
            var l = l
            if case .image(var i) = l.content, i.role != "logo" { i.path = ""; i.role = "photo"; l.content = .image(i) }
            if case .image(var i) = l.content, i.role == "logo" { i.path = ""; l.content = .image(i) }
            return l
        }
        model.context.insert(CreativeTemplate(workspaceID: ws, document: doc, category: StudioModel.category(for: doc)))
        try? model.context.save()
    }
}

// MARK: - Inspector

struct StudioInspector: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \CreativeTemplate.createdAt) private var allTemplates: [CreativeTemplate]
    @Query(sort: \AIJob.createdAt, order: .reverse) private var jobs: [AIJob]
    private static let fonts: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private var studio: StudioModel { model.studio }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inspector") { Text(studio.selected.map { "\($0.name) selected" } ?? (studio.document == nil ? "" : "Canvas")) }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                if studio.document == nil {
                    Text("Start a design from a brand template, or open a saved design.").font(DS.body).foregroundStyle(DS.text2)
                } else {
                    if let layer = studio.selected { layerSection(layer) } else { canvasSection }
                    brandSection
                    aiBackground
                    if let layer = studio.selected, case .image = layer.content { transformSection }
                    valuesSection
                }
                templatesSection
            }
        }
    }

    // MARK: Layer

    @ViewBuilder
    private func layerSection(_ layer: CreativeLayer) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("\(kindName(layer)) layer · \(layer.name)")
            if case .text(let t) = layer.content {
                TextField("Text", text: textBind(layer.id, \.text), axis: .vertical)
                    .font(.custom(t.fontName, size: 17)).lineLimit(1...5).fieldStyle()
                HStack(spacing: Space.sm) {
                    Menu {
                        Button("Brand headline font") { setFontRole(layer.id, "headline") }
                        Button("Brand body font") { setFontRole(layer.id, "body") }
                        Divider()
                        ForEach(Self.fonts, id: \.self) { f in Button(f) { setFont(layer.id, f) } }
                    } label: {
                        Text(fontLabel(t)).font(DS.body).foregroundStyle(DS.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fieldStyle()
                    TextField("Size", value: textBind(layer.id, \.size), format: .number).frame(width: 64).fieldStyle()
                    TextField("Line", value: textBind(layer.id, \.lineHeight), format: .number.precision(.fractionLength(2))).frame(width: 64).fieldStyle()
                }
                if !FontCheck.isInstalled(resolvedFont(t)) {
                    Label("“\(resolvedFont(t))” is not installed. Export is blocked until you install it or pick another font.", systemImage: "textformat.alt")
                        .font(DS.small).foregroundStyle(DS.red)
                }
                PillPicker(options: TextLayer.Alignment.allCases, selection: textBind(layer.id, \.alignment)) {
                    switch $0 { case .leading: "Left"; case .center: "Center"; case .trailing: "Right" }
                }
                colorRow(layer.id, role: t.colorRole, current: t.color)
                HStack {
                    Toggle("Uppercase", isOn: Binding(get: { t.uppercase == true }, set: { v in studio.changeLayer(layer.id) { l in if case .text(var x) = l.content { x.uppercase = v; l.content = .text(x) } } }))
                        .toggleStyle(SFToggleStyle())
                    Toggle("Shadow", isOn: textBind(layer.id, \.shadow)).toggleStyle(SFToggleStyle())
                }
                .font(DS.body)
            }
            if case .shape(let s) = layer.content {
                colorRow(layer.id, role: s.fillRole, current: s.fill)
                HStack {
                    Text("Radius").font(DS.body).foregroundStyle(DS.text2)
                    Slider(value: shapeBind(layer.id, \.cornerRadius), in: 0...400)
                }
                Toggle("Gradient fade", isOn: Binding(get: { s.gradientTo != nil }, set: { on in
                    studio.changeLayer(layer.id) { l in if case .shape(var x) = l.content { x.gradientTo = on ? RGBA(0, 0, 0, 0) : nil; x.gradientRole = nil; l.content = .shape(x) } }
                })).toggleStyle(SFToggleStyle()).font(DS.body)
                Toggle("Shadow", isOn: Binding(get: { s.shadow == true }, set: { v in studio.changeLayer(layer.id) { l in if case .shape(var x) = l.content { x.shadow = v; l.content = .shape(x) } } }))
                    .toggleStyle(SFToggleStyle()).font(DS.body)
                HStack {
                    Text("Border").font(DS.body).foregroundStyle(DS.text2)
                    Slider(value: shapeBind(layer.id, \.borderWidth), in: 0...20)
                }
            }
            if case .image(let i) = layer.content {
                PillPicker(options: FitMode.allCases, selection: Binding(get: { i.mode }, set: { v in
                    studio.changeLayer(layer.id) { l in if case .image(var x) = l.content { x.mode = v; l.content = .image(x) } }
                })) { $0 == .fill ? "Fill" : "Fit" }
                Picker("Role", selection: Binding(get: { i.role ?? "" }, set: { v in
                    studio.changeLayer(layer.id) { l in if case .image(var x) = l.content { x.role = v.isEmpty ? nil : v; l.content = .image(x) } }
                })) {
                    Text("Fixed image").tag("")
                    Text("Photo slot (per image)").tag("photo")
                    Text("Brand logo").tag("logo")
                }
            }
            HStack(spacing: Space.sm) {
                numberField("X", layer.id, \.x)
                numberField("Y", layer.id, \.y)
                numberField("W", layer.id, \.width)
                numberField("H", layer.id, \.height)
            }
            HStack {
                Text("Opacity").font(DS.body).foregroundStyle(DS.text2)
                Slider(value: bind(layer.id, \.opacity), in: 0...1)
            }
            HStack {
                Toggle("Locked", isOn: bind(layer.id, \.isLocked)).toggleStyle(SFToggleStyle())
                Toggle("Hidden", isOn: bind(layer.id, \.isHidden)).toggleStyle(SFToggleStyle())
            }
            .font(DS.body)
        }
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Canvas")
            TextField("Name", text: Binding(get: { studio.document?.name ?? "" }, set: { n in studio.change { $0.name = n } })).fieldStyle()
            ColorPicker("Background", selection: Binding(get: { Color(cgColor: studio.document?.background.cgColor ?? .white) }, set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                studio.change { $0.background = RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent) }
            }))
            .font(DS.body)
            Text("Click a layer on the canvas or in Layers to edit it.").font(DS.small).foregroundStyle(DS.text2)
        }
    }

    /// Brand swatches bind the layer to the kit; the custom picker unbinds it.
    private func colorRow(_ id: UUID, role: String?, current: RGBA) -> some View {
        let palette = model.brandKit?.colors ?? []
        return HStack(spacing: Space.sm) {
            Text("Color").font(DS.body).foregroundStyle(DS.text2)
            ForEach(Array(palette.enumerated()), id: \.offset) { i, hex in
                Button { setColorRole(id, "brand.\(i)") } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: UInt32(hex))).frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(role == "brand.\(i)" ? DS.accentFill : DS.strokeStrong, lineWidth: role == "brand.\(i)" ? 2 : 1))
                }
                .buttonStyle(.plain).help("Brand color \(i + 1)")
            }
            ColorPicker("", selection: Binding(get: { Color(cgColor: current.cgColor) }, set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
                setColor(id, RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent))
            }))
            .labelsHidden()
            .help("A custom color (not tied to the brand kit)")
        }
    }

    // MARK: Brand, AI background, transforms, values, templates

    private var brandSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            let offBrand = offBrandLayers
            SectionLabel("Brand kit", trailing: AnyView(Text(offBrand.isEmpty ? "On brand" : "\(offBrand.count) off brand")
                .font(DS.small).foregroundStyle(offBrand.isEmpty ? DS.green : DS.amber)))
            if let kit = model.brandKit {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.md) {
                        WorkspaceBadge(name: kit.name, colorHex: kit.colors.dropFirst(2).first ?? 0xFF8A5C, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kit.name).font(DS.bodyMedium)
                            Text("\(kit.headlineFont) · \(kit.bodyFont) · \(kit.colors.count) colors").font(DS.small).foregroundStyle(DS.text2)
                        }
                    }
                    HStack(spacing: 0) { ForEach(kit.colors, id: \.self) { Rectangle().fill(Color(hex: UInt32($0))) } }
                        .frame(height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                    if !kit.voice.isEmpty { Text("Voice: \(kit.voice)").font(DS.small).foregroundStyle(DS.text2) }
                    if !offBrand.isEmpty {
                        Text("Custom colors or fonts on: \(offBrand.joined(separator: ", ")).").font(DS.small).foregroundStyle(DS.amber)
                        Button("Snap to brand") { snapToBrand() }.buttonStyle(LinkButtonStyle())
                    }
                }
                .card(padding: Space.md)
            } else {
                HStack {
                    Text("No brand kit yet.").font(DS.body).foregroundStyle(DS.text2)
                    Spacer()
                    Button("Create") { model.page = .brandKits }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var aiBackground: some View {
        let photoPath = studio.document?.layers.compactMap { l -> String? in if case .image(let i) = l.content, i.role == "photo" || i.role == nil { i.path } else { nil } }.first
        let job = jobs.first { j in j.outputAssetIDs.contains { model.asset($0)?.storedPath == photoPath } }
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("AI background")
            if let job {
                HStack(alignment: .top, spacing: Space.md) {
                    Thumbnail(path: photoPath, maxPixel: 120).frame(width: 44, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.prompt).font(DS.body).lineLimit(2)
                        Text("\(job.provider) · seed \(job.seed)").font(DS.small).foregroundStyle(DS.text2)
                    }
                }
            } else {
                Text("The background is a photo. Generate one in AI Studio; text and logo stay real layers here.").font(DS.small).foregroundStyle(DS.text2)
            }
            HStack(spacing: Space.sm) {
                Button("Variations") { model.aiStudio.prompt = job?.prompt ?? model.aiStudio.prompt; model.aiStudio.sendToStudio = true; model.page = .ai }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Button(job == nil ? "Generate" : "Regenerate") { model.aiStudio.prompt = job?.prompt ?? model.aiStudio.prompt; model.aiStudio.sendToStudio = true; model.page = .ai }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
        }
    }

    private var transformSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Transform image")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                op("Remove BG", "scissors", "Cut out the subject with Vision, on this Mac") { await studio.run(.removeBackground, model: model) }
                op("Upscale 2×", "arrow.up.left.and.arrow.down.right", "Lanczos resize with light sharpening (not AI super-resolution)") { await studio.run(.upscale, model: model) }
                unavailable("Extend", "arrow.up.backward.and.arrow.down.forward", "Needs an image provider with outpainting (milestone 5)")
                unavailable("Relight", "sun.max", "Needs an AI image provider (milestone 5)")
                op("Brand color", "drop", "Tone the image toward the brand accent color") { await studio.run(.brandTint, model: model) }
                op("Smart crop", "viewfinder", "Center the crop on the most eye-catching area (Vision)") { await studio.run(.smartCrop, model: model) }
            }
        }
    }

    private func op(_ title: String, _ symbol: String, _ help: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: symbol).font(DS.body).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SecondaryButtonStyle(fullWidth: true))
        .disabled(studio.busy != nil)
        .help(help)
    }

    private func unavailable(_ title: String, _ symbol: String, _ why: String) -> some View {
        Label(title, systemImage: symbol).font(DS.body).foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.md).frame(height: 32)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .help(why)
    }

    private var valuesSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Template values")
            let vars = studio.document?.variables ?? []
            if vars.isEmpty { Text("Type {{title}}, {{price}}, or {{cta}} in a text layer to fill it per post.").font(DS.small).foregroundStyle(DS.text2) }
            ForEach(vars, id: \.self) { v in
                HStack {
                    Text(v).font(DS.mono).foregroundStyle(DS.text2).frame(width: 88, alignment: .leading)
                    TextField(v, text: Binding(get: { studio.previewValues[v] ?? "" }, set: { studio.previewValues[v] = $0; studio.touch() })).fieldStyle()
                }
            }
        }
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Templates", trailing: AnyView(Menu {
                Button("Import Template…") { TemplateIO.importTemplate(model: model) }
                if studio.document != nil { Button("Save Current as Template") { studio.saveAsTemplate(model: model, name: studio.document?.name ?? "Template") } }
            } label: { Image(systemName: "plus") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                ForEach(allTemplates.filter { $0.workspaceID == model.workspaceID }) { t in
                    TemplateTile(template: t, selected: studio.templateID == t.uuid)
                }
            }
            Text("Click to start a design. Right-click to edit, duplicate, or export a template.").font(DS.caption).foregroundStyle(DS.text3)
        }
    }

    // MARK: Helpers

    private var offBrandLayers: [String] {
        guard let doc = studio.document, model.brandKit != nil else { return [] }
        return doc.layers.compactMap { l in
            switch l.content {
            case .text(let t): (t.colorRole == nil || t.fontRole == nil) ? l.name : nil
            case .shape(let s): s.fillRole == nil && s.fill.a > 0.5 ? l.name : nil
            case .image: nil
            }
        }
    }

    private func snapToBrand() {
        studio.change { doc in
            for i in doc.layers.indices {
                switch doc.layers[i].content {
                case .text(var t):
                    if t.colorRole == nil { t.colorRole = "brand.0" }
                    if t.fontRole == nil { t.fontRole = t.size >= 60 ? "headline" : "body" }
                    doc.layers[i].content = .text(t)
                case .shape(var s):
                    if s.fillRole == nil && s.fill.a > 0.5 { s.fillRole = "brand.1" }
                    doc.layers[i].content = .shape(s)
                case .image: break
                }
            }
        }
    }

    private func kindName(_ l: CreativeLayer) -> String {
        switch l.content { case .text: "Text"; case .shape: "Shape"; case .image: "Image" }
    }

    private func resolvedFont(_ t: TextLayer) -> String { model.brandKit?.style.font(t.fontRole) ?? t.fontName }

    private func fontLabel(_ t: TextLayer) -> String {
        switch t.fontRole {
        case "headline": "Brand headline · \(resolvedFont(t))"
        case "body": "Brand body · \(resolvedFont(t))"
        default: t.fontName
        }
    }

    private func setFont(_ id: UUID, _ f: String) {
        studio.changeLayer(id) { l in if case .text(var t) = l.content { t.fontName = f; t.fontRole = nil; l.content = .text(t) } }
    }

    private func setFontRole(_ id: UUID, _ role: String) {
        studio.changeLayer(id) { l in if case .text(var t) = l.content { t.fontRole = role; l.content = .text(t) } }
    }

    private func setColorRole(_ id: UUID, _ role: String) {
        studio.changeLayer(id) { l in
            switch l.content {
            case .text(var t): t.colorRole = role; l.content = .text(t)
            case .shape(var s): s.fillRole = role; l.content = .shape(s)
            case .image: break
            }
        }
    }

    private func setColor(_ id: UUID, _ c: RGBA) {
        studio.changeLayer(id) { l in
            switch l.content {
            case .text(var t): t.color = c; t.colorRole = nil; l.content = .text(t)
            case .shape(var s): s.fill = c; s.fillRole = nil; l.content = .shape(s)
            case .image: break
            }
        }
    }

    private func numberField(_ label: String, _ id: UUID, _ kp: WritableKeyPath<CreativeLayer, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DS.caption).foregroundStyle(DS.text3)
            TextField(label, value: bind(id, kp), format: .number.precision(.fractionLength(0))).fieldStyle()
        }
    }

    private func bind<T>(_ id: UUID, _ kp: WritableKeyPath<CreativeLayer, T>) -> Binding<T> {
        Binding(get: { studio.document!.layers.first { $0.id == id }![keyPath: kp] },
                set: { v in studio.changeLayer(id) { $0[keyPath: kp] = v } })
    }

    private func textBind<T>(_ id: UUID, _ kp: WritableKeyPath<TextLayer, T>) -> Binding<T> {
        Binding(get: {
            guard case .text(let t) = studio.document!.layers.first(where: { $0.id == id })!.content else { fatalError("not text") }
            return t[keyPath: kp]
        }, set: { v in
            studio.changeLayer(id) { l in if case .text(var t) = l.content { t[keyPath: kp] = v; l.content = .text(t) } }
        })
    }

    private func shapeBind<T>(_ id: UUID, _ kp: WritableKeyPath<ShapeLayer, T>) -> Binding<T> {
        Binding(get: {
            guard case .shape(let s) = studio.document!.layers.first(where: { $0.id == id })!.content else { fatalError("not a shape") }
            return s[keyPath: kp]
        }, set: { v in
            studio.changeLayer(id) { l in if case .shape(var s) = l.content { s[keyPath: kp] = v; l.content = .shape(s) } }
        })
    }
}

import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftData
import SocialForgeKit

/// The open Creative Studio document, what it is (a design or a template),
/// its selection, tool, and undo history.
@Observable
final class StudioModel {
    enum Tool: String, CaseIterable { case select, text, shape, image, ai, resize }

    var document: CreativeDocument?
    /// Set when editing a saved design.
    var designID: UUID?
    /// Set when editing a brand template; Save updates the template.
    var templateID: UUID?
    var selectedLayer: UUID?
    var tool: Tool = .select
    var zoom: Double = 0.42
    var exportMessage: String?
    var busy: String?
    /// Values for {{variables}} in the preview and export.
    var previewValues: [String: String] = ["title": "Slow mornings, warmer mugs.", "subtitle": "Hand-thrown stoneware, made in small batches.",
                                           "price": "$38", "cta": "Shop now", "brand": "Your Brand", "url": "", "product_name": "Stoneware Mug",
                                           "date": Date.now.formatted(date: .abbreviated, time: .omitted)]
    /// Bumped on edits, so previews re-render.
    private(set) var revision = 0
    private(set) var history: [CreativeDocument] = []
    private(set) var future: [CreativeDocument] = []
    private(set) var savedRevision = 0
    /// The document before a canvas drag began (one undo step per drag).
    var dragOrigin: CreativeDocument?

    // Video designs
    /// The playhead, in seconds.
    var time: Double = 0
    var isPlaying = false
    /// The selected audio track (Layers and the inspector show it).
    var selectedAudio: UUID?
    /// Export progress, 0...1, while a video renders.
    var videoProgress: Double?
    /// Progress, 0...1, while Generate all sizes runs.
    var sizesProgress: Double?
    /// What the last Generate all sizes made, for Show in Library and Show in Finder.
    var lastSizes: (collection: String, files: [URL])?
    @ObservationIgnored var playback: Task<Void, Never>?
    @ObservationIgnored var audioPlayer: AVPlayer?
    @ObservationIgnored var exportTask: Task<Void, Never>?

    /// Re-render without an undo step (template values changed).
    func touch() { revision += 1 }

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var hasUnsavedChanges: Bool { revision != savedRevision }

    /// Every change goes through here, so it can be undone.
    func change(_ edit: (inout CreativeDocument) -> Void) {
        guard var doc = document else { return }
        let before = doc
        edit(&doc)
        guard doc != before else { return }
        history.append(before)
        if history.count > 200 { history.removeFirst() }
        future.removeAll()
        document = doc
        revision += 1
    }

    /// Edits a layer; a grouped layer's move applies to its whole group.
    func changeLayer(_ id: UUID, _ edit: (inout CreativeLayer) -> Void) {
        change { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            edit(&doc.layers[i])
        }
    }

    func moveLayer(_ id: UUID, dx: Double, dy: Double, recordUndo: Bool) {
        guard let doc = document, let layer = doc.layers.first(where: { $0.id == id }), !layer.isLocked else { return }
        let ids = Set(doc.layers.filter { layer.group != nil && $0.group == layer.group }.map(\.id) + [id])
        let apply: (inout CreativeDocument) -> Void = { d in
            for i in d.layers.indices where ids.contains(d.layers[i].id) && !d.layers[i].isLocked {
                d.layers[i].x = (d.layers[i].x + dx).rounded()
                d.layers[i].y = (d.layers[i].y + dy).rounded()
            }
        }
        if recordUndo { change(apply) } else if var d = document { apply(&d); document = d; revision += 1 }
    }

    func undo() {
        guard let prev = history.popLast(), let cur = document else { return }
        future.append(cur)
        document = prev
        revision += 1
    }

    func redo() {
        guard let next = future.popLast(), let cur = document else { return }
        history.append(cur)
        document = next
        revision += 1
    }

    func open(_ doc: CreativeDocument, designID: UUID?, templateID: UUID? = nil) {
        document = doc
        self.designID = designID
        self.templateID = templateID
        selectedLayer = doc.layers.last { if case .text = $0.content { true } else { false } }?.id
        history = []
        future = []
        revision += 1
        savedRevision = revision
    }

    var selected: CreativeLayer? { document?.layers.first { $0.id == selectedLayer } }

    /// The document as it renders: brand roles resolved and template values filled.
    func rendered(brand: BrandStyle?) -> CreativeDocument? {
        guard var doc = document else { return nil }
        if let brand { doc = doc.applyingBrand(brand) }
        return doc.filled(previewValues)
    }

    // MARK: Layers

    func addText(model: AppModel) {
        guard let doc = document else { return }
        let layer = CreativeLayer(name: "Text", x: Double(doc.width) * 0.1, y: Double(doc.height) * 0.4,
                                  width: Double(doc.width) * 0.8, height: Double(doc.height) * 0.12,
                                  content: .text(TextLayer(text: "{{title}}", fontName: model.brandKit?.headlineFont ?? "Helvetica Neue",
                                                           size: Double(doc.width) / 12, color: .black, colorRole: "brand.0", fontRole: "headline")))
        change { $0.layers.append(layer) }
        selectedLayer = layer.id
        tool = .select
    }

    func addShape() {
        guard let doc = document else { return }
        let layer = CreativeLayer(name: "Shape", x: Double(doc.width) * 0.1, y: Double(doc.height) * 0.7,
                                  width: Double(doc.width) * 0.8, height: Double(doc.height) * 0.1,
                                  content: .shape(ShapeLayer(kind: .rectangle, fill: .black, cornerRadius: 24, fillRole: "brand.2")))
        change { $0.layers.append(layer) }
        selectedLayer = layer.id
        tool = .select
    }

    func addImage(path: String, role: String? = nil, below: Bool = true) {
        guard let doc = document else { return }
        let layer = CreativeLayer(name: role == "photo" ? "Photo" : role == "logo" ? "Logo" : "Image", x: 0, y: 0,
                                  width: Double(doc.width), height: Double(doc.height), content: .image(ImageLayer(path: path, role: role)))
        change { below ? $0.layers.insert(layer, at: 0) : $0.layers.append(layer) }
        selectedLayer = layer.id
        tool = .select
    }

    func addLogo(model: AppModel) {
        guard let doc = document else { return }
        let w = Double(doc.width) * 0.22
        let layer = CreativeLayer(name: "Logo", x: Double(doc.width) * 0.06, y: Double(doc.height) * 0.04, width: w, height: w * 0.45,
                                  content: .image(ImageLayer(path: "", mode: .fit, role: "logo")))
        change { $0.layers.append(layer) }
        selectedLayer = layer.id
        if model.brandKit?.logoPath.isEmpty ?? true { exportMessage = "Add a logo to the brand kit (Brand Kits) to fill this slot." }
    }

    func delete(_ id: UUID) {
        change { $0.layers.removeAll { $0.id == id && !$0.isLocked } }
        if selected == nil { selectedLayer = nil }
    }

    /// Something on the canvas or in the Layers panel is selected that Delete can remove.
    var canDeleteSelection: Bool { selectedAudio != nil || selected != nil }

    /// Delete key, Edit › Delete Layer: removes the selected layer or audio track.
    /// A locked layer stays and says why.
    func deleteSelection() {
        if let id = selectedAudio { removeTrack(id); return }
        guard let layer = selected else { return }
        if layer.isLocked {
            exportMessage = "“\(layer.name)” is locked. Unlock it in Layers to delete it."
            return
        }
        delete(layer.id)
    }

    func duplicateLayer(_ id: UUID) {
        guard var copy = document?.layers.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " copy"
        copy.x += 20
        copy.y += 20
        change { d in
            let i = (d.layers.firstIndex { $0.id == id } ?? d.layers.count - 1) + 1
            d.layers.insert(copy, at: i)
        }
        selectedLayer = copy.id
    }

    func move(_ id: UUID, by offset: Int) {
        change { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = max(0, min(doc.layers.count - 1, i + offset))
            let l = doc.layers.remove(at: i)
            doc.layers.insert(l, at: j)
        }
    }

    /// Groups the selected layer with the layer below it, or ungroups it.
    func toggleGroup(_ id: UUID) {
        change { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            if doc.layers[i].group != nil {
                let g = doc.layers[i].group
                for j in doc.layers.indices where doc.layers[j].group == g { doc.layers[j].group = nil }
            } else if i > 0 {
                let g = doc.layers[i - 1].group ?? "Group \(UUID().uuidString.prefix(4))"
                doc.layers[i - 1].group = g
                doc.layers[i].group = g
            }
        }
    }

    // MARK: Opening

    /// A new design from the first brand template (or the built-in Product Pin).
    func openNew(model: AppModel, photoPath: String? = nil) {
        model.ensureBuiltInTemplates()
        var doc = model.templates.first?.document ?? StudioModel.productPin()
        doc.name = "Untitled design"
        if let photoPath {
            if doc.hasPhotoSlot { doc = doc.withPhoto(photoPath) } else { doc.layers.insert(CreativeLayer(name: "Photo", x: 0, y: 0, width: Double(doc.width), height: Double(doc.height), content: .image(ImageLayer(path: photoPath, role: "photo"))), at: 0) }
        } else if let first = model.assets(model.mediaSelection).first, doc.hasPhotoSlot {
            doc = doc.withPhoto(first.storedPath)
        }
        open(doc, designID: nil)
    }

    // MARK: Save

    func save(model: AppModel) {
        guard let doc = document, let workspaceID = model.workspaceID else { return }
        let ctx = model.context
        if let templateID, let t = try? ctx.fetch(FetchDescriptor<CreativeTemplate>(predicate: #Predicate { $0.uuid == templateID })).first {
            t.json = (try? doc.json()) ?? t.json
            t.name = doc.name
            t.updatedAt = .now
            model.log("Saved template “\(doc.name)”", symbol: "rectangle.stack")
        } else if let designID, let existing = try? ctx.fetch(FetchDescriptor<Design>(predicate: #Predicate { $0.uuid == designID })).first {
            existing.json = (try? doc.json()) ?? existing.json
            existing.name = doc.name
            existing.updatedAt = .now
        } else {
            let d = Design(workspaceID: workspaceID, document: doc)
            ctx.insert(d)
            designID = d.uuid
        }
        try? ctx.save()
        savedRevision = revision
        exportMessage = templateID != nil ? "Template saved. Designs made from it later use these changes." : "Design saved."
    }

    /// Saves the current design as a brand template: its photo becomes a slot.
    func saveAsTemplate(model: AppModel, name: String) {
        guard var doc = document, let workspaceID = model.workspaceID else { return }
        doc.name = name.isEmpty ? doc.name : name
        if !doc.hasPhotoSlot, let i = doc.layers.firstIndex(where: { if case .image(let im) = $0.content { im.role == nil } else { false } }),
           case .image(var im) = doc.layers[i].content {
            im.role = "photo"
            doc.layers[i].content = .image(im)
        }
        let t = CreativeTemplate(workspaceID: workspaceID, document: doc, category: Self.category(for: doc))
        model.context.insert(t)
        try? model.context.save()
        document = doc
        templateID = t.uuid
        designID = nil
        savedRevision = revision
        model.log("Saved “\(doc.name)” as a brand template", symbol: "rectangle.stack.badge.plus")
        exportMessage = "Saved as template “\(doc.name)”. It appears in Templates and in Media Library > Apply Brand Template."
    }

    static func category(for doc: CreativeDocument) -> String {
        CanvasPreset.all.first { $0.width == doc.width && $0.height == doc.height }?.name ?? "\(doc.width) × \(doc.height)"
    }

    // MARK: Smart resize and export

    /// Switches the open document to another canvas size, keeping it editable.
    func resize(to preset: CanvasPreset) {
        change { $0 = $0.resized(width: preset.width, height: preset.height, name: $0.name) }
    }

    /// Renders with real fonts to Exports/ and adds the result to the library.
    @discardableResult
    func export(model: AppModel, document override: CreativeDocument? = nil, suffix: String = "", collection: String = "Branded") async -> MediaAsset? {
        guard let base = override ?? document else { return nil }
        var doc = base
        if let brand = model.brandKit?.style { doc = doc.applyingBrand(brand) }
        doc = doc.filled(previewValues)
        if !doc.missingFonts.isEmpty {
            exportMessage = "Install or replace these fonts first: \(doc.missingFonts.joined(separator: ", ")). Nothing was exported."
            return nil
        }
        let dir = model.storage.exports
        let safe = doc.name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        let url = dir.appending(path: "\(safe)\(suffix)-\(UUID().uuidString.prefix(6)).png")
        do {
            let final = doc
            _ = try await Task.detached { try CreativeRenderer.export(final, to: url) }.value
            // Importing selects what it adds. An export must not: the selected image fills the
            // photo slot of every template and new design, so each export showed up inside the
            // next ones (the "jumbled" sizes and template thumbnails).
            let selection = model.mediaSelection
            var added = await model.importMedia([url])
            model.mediaSelection = selection
            // The same picture is already in the library (an unchanged design exported again):
            // use that one, so the export still lands in its collection and is reported.
            if added.isEmpty, let hash = try? ContentHash.sha256(of: url), let ws = model.workspaceID,
               let same = ((try? model.context.fetch(FetchDescriptor<MediaAsset>(predicate: #Predicate { $0.sha256 == hash }))) ?? []).first(where: { $0.workspaceID == ws }) {
                try? FileManager.default.removeItem(at: url)
                added = [same]
            }
            if let a = added.first {
                a.title = previewValues["title"] ?? doc.name
                a.collection = collection
                a.tags = Array(Set(a.tags + ["branded"]))
                a.notes = "Made in Creative Studio from “\(base.name)” (\(doc.width) × \(doc.height))."
            }
            try? model.context.save()
            return added.first
        } catch {
            exportMessage = "Export failed: \(error)"
            return nil
        }
    }

    /// The design's "Generate all sizes": one PNG per platform canvas, text still live in each saved design.
    ///
    /// The sizes form a set named after the design: one Media Library collection
    /// ("Sizes · name") and one row in the Studio gallery. Running it again replaces
    /// the set's designs rather than adding another six.
    func generateAllSizes(model: AppModel) async {
        guard let doc = document, let workspaceID = model.workspaceID else { return }
        let setName = Self.sizeSetName(for: doc.name)
        let collection = "Sizes · \(setName)"
        let presets = CanvasPreset.all
        exportMessage = nil
        lastSizes = nil
        defer { busy = nil; sizesProgress = nil }
        let existing = ((try? model.context.fetch(FetchDescriptor<Design>())) ?? []).filter { $0.workspaceID == workspaceID && $0.sizeSet == setName }
        var files: [URL] = []
        for (i, preset) in presets.enumerated() {
            busy = "Making \(preset.name), \(i + 1) of \(presets.count)…"
            sizesProgress = Double(i) / Double(presets.count)
            let resized = doc.resized(width: preset.width, height: preset.height, name: "\(setName) · \(preset.name)")
            if let old = existing.first(where: { $0.name == resized.name }) {
                old.json = (try? resized.json()) ?? old.json
                old.updatedAt = .now
            } else {
                let d = Design(workspaceID: workspaceID, document: resized)
                d.sizeSet = setName
                model.context.insert(d)
            }
            if let a = await export(model: model, document: resized, suffix: "-\(preset.id)", collection: collection) {
                files.append(a.storedURL)
            }
        }
        try? model.context.save()
        lastSizes = (collection, files)
        exportMessage = files.count == presets.count
            ? "Done: \(files.count) sizes of “\(setName)”. The images are in the Media Library under “\(collection)”; the editable designs are in Designs."
            : "Made \(files.count) of \(presets.count) sizes. \(exportMessage ?? "")"
        model.log("Generated \(files.count) platform sizes of “\(setName)”", symbol: "aspectratio")
    }

    /// "Mug · Story" made from a size goes back to "Mug", so a set never nests.
    static func sizeSetName(for name: String) -> String {
        for p in CanvasPreset.all where name.hasSuffix(" · \(p.name)") { return String(name.dropLast(p.name.count + 3)) }
        return name
    }

    /// 100 product images → 100 branded graphics: one render per asset, with its title and price.
    func applyTemplate(_ template: CreativeTemplate, to assets: [MediaAsset], model: AppModel) async {
        guard var doc = template.document else { return }
        if !doc.hasPhotoSlot { doc.layers.insert(CreativeLayer(name: "Photo", x: 0, y: 0, width: Double(doc.width), height: Double(doc.height), content: .image(ImageLayer(path: "", role: "photo"))), at: 0) }
        busy = "Applying “\(template.name)” to \(assets.count) images…"
        model.variantProgress = (0, assets.count)
        defer { busy = nil; model.variantProgress = nil }
        let saved = previewValues
        var made: [MediaAsset] = []
        for (i, a) in assets.enumerated() {
            previewValues = saved.merging([
                "title": a.title.nonEmpty ?? BulkSession.titleFromFilename(a.filename),
                "product_name": a.title.nonEmpty ?? BulkSession.titleFromFilename(a.filename),
                "url": a.productURL, "brand": model.brandKit?.name ?? saved["brand"] ?? "",
            ]) { _, new in new }
            var one = doc.withPhoto(a.storedPath)
            one.name = "\(template.name) · \(a.filename)"
            if let out = await export(model: model, document: one, collection: "Branded · \(template.name)") {
                out.productURL = a.productURL
                made.append(out)
            }
            model.variantProgress = (i + 1, assets.count)
        }
        previewValues = saved
        try? model.context.save()
        model.mediaSelection = Set(made.map(\.uuid))
        model.log("Applied “\(template.name)” to \(made.count) images", symbol: "rectangle.stack")
        exportMessage = "Made \(made.count) branded graphics in “Branded · \(template.name)”."
    }

    // MARK: Image operations on the selected image layer

    enum ImageOp { case removeBackground, upscale, brandTint, smartCrop }

    func run(_ op: ImageOp, model: AppModel) async {
        guard let layer = selected, case .image(let img) = layer.content, !img.path.isEmpty else {
            exportMessage = "Select an image layer first."
            return
        }
        let url = URL(fileURLWithPath: img.path)
        let tintColor = model.brandKit?.style.palette.dropFirst(2).first ?? RGBA(hex: 0xFF8A5C)
        busy = "Working…"
        defer { busy = nil }
        do {
            if op == .smartCrop {
                let focus = try await Task.detached { try ImageOps.saliencyFocus(url) }.value
                changeLayer(layer.id) { l in
                    if case .image(var i) = l.content { i.focusX = focus.x; i.focusY = focus.y; i.mode = .fill; l.content = .image(i) }
                }
                exportMessage = "Cropped around the subject."
                return
            }
            let data: Data = try await Task.detached {
                switch op {
                case .removeBackground: try ImageOps.removeBackground(url)
                case .upscale: try ImageOps.upscale2x(url)
                case .brandTint: try ImageOps.tint(url, color: tintColor)
                case .smartCrop: Data()
                }
            }.value
            let name = url.deletingPathExtension().lastPathComponent + "-" + "\(op)".lowercased() + ".png"
            let out = model.storage.exports.appending(path: name)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out)
            let added = await model.importMedia([out])
            guard let a = added.first else { exportMessage = "The result was already in the library."; return }
            a.notes = "\(op) of \(url.lastPathComponent)"
            changeLayer(layer.id) { l in
                if case .image(var i) = l.content { i.path = a.storedPath; l.content = .image(i) }
            }
            exportMessage = "Done. The new image is in the Media Library; the original is unchanged."
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    // MARK: Built-in templates

    /// "Editorial": photo, spaced wordmark, big serif headline, subtitle, and a price + CTA pill.
    static func productPin() -> CreativeDocument {
        CreativeDocument(name: "Editorial", width: 1000, height: 1500, background: RGBA(hex: 0xB98A68), layers: [
            CreativeLayer(name: "Photo", x: 0, y: 0, width: 1000, height: 1500, content: .image(ImageLayer(path: "", role: "photo"))),
            CreativeLayer(name: "Shade", x: 0, y: 0, width: 1000, height: 700,
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(0, 0, 0, 0.28), gradientTo: RGBA(0, 0, 0, 0)))),
            CreativeLayer(name: "Wordmark", x: 100, y: 80, width: 800, height: 40,
                          content: .text(TextLayer(text: "{{brand}}", fontName: "Helvetica Neue", size: 26, color: RGBA(1, 1, 1, 0.85), alignment: .center,
                                                   colorRole: "brand.1", fontRole: "body", tracking: 8, uppercase: true))),
            CreativeLayer(name: "Headline", x: 80, y: 150, width: 840, height: 330,  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{title}}", fontName: "Instrument Serif", size: 150, lineHeight: 0.98, color: .white,  // grid: ok canvas pixels or computed position
                                                   colorRole: "brand.1", fontRole: "headline"))),
            CreativeLayer(name: "Subhead", x: 84, y: 500, width: 700, height: 110,  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{subtitle}}", fontName: "Helvetica Neue", size: 34, lineHeight: 1.3, color: RGBA(1, 1, 1, 0.9),  // grid: ok canvas pixels or computed position
                                                   colorRole: "brand.1", fontRole: "body"))),
            CreativeLayer(name: "Price tag", x: 250, y: 1300, width: 500, height: 92, group: "Price",
                          content: .shape(ShapeLayer(kind: .rectangle, fill: .white, cornerRadius: 46, fillRole: "brand.1", shadow: true))),  // grid: ok canvas pixels or computed position
            CreativeLayer(name: "Price", x: 280, y: 1322, width: 130, height: 50, group: "Price",  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{price}}", fontName: "Helvetica Neue", size: 36, color: .black, alignment: .center,
                                                   colorRole: "brand.0", fontRole: "body"))),
            CreativeLayer(name: "Call to action", x: 410, y: 1322, width: 320, height: 50, group: "Price",  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{cta}}", fontName: "Helvetica Neue", size: 34, color: .black, alignment: .center,
                                                   colorRole: "brand.0", fontRole: "body"))),
        ])
    }

    /// "Centered": photo with a centered serif headline and a solid band.
    static func centered() -> CreativeDocument {
        CreativeDocument(name: "Centered", width: 1000, height: 1500, background: RGBA(hex: 0x2A211C), layers: [
            CreativeLayer(name: "Photo", x: 0, y: 0, width: 1000, height: 1500, content: .image(ImageLayer(path: "", role: "photo"))),
            CreativeLayer(name: "Band", x: 0, y: 1060, width: 1000, height: 440,
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(hex: 0x2A211C, alpha: 0.92), fillRole: "brand.0"))),
            CreativeLayer(name: "Headline", x: 80, y: 1110, width: 840, height: 220,
                          content: .text(TextLayer(text: "{{title}}", fontName: "Instrument Serif", size: 96, lineHeight: 1.0, color: .white, alignment: .center,
                                                   colorRole: "brand.1", fontRole: "headline"))),
            CreativeLayer(name: "Link", x: 80, y: 1370, width: 840, height: 50,  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{cta}}", fontName: "Helvetica Neue", size: 30, color: .white, alignment: .center,
                                                   colorRole: "brand.2", fontRole: "body", tracking: 2, uppercase: true))),
        ])
    }

    /// "Price card": photo on top, a paper card with name, price, and button.
    static func priceCard() -> CreativeDocument {
        CreativeDocument(name: "Price card", width: 1000, height: 1500, background: RGBA(hex: 0xF4EFE8), layers: [
            CreativeLayer(name: "Photo", x: 0, y: 0, width: 1000, height: 1060, content: .image(ImageLayer(path: "", role: "photo"))),
            CreativeLayer(name: "Card", x: 0, y: 1040, width: 1000, height: 460,
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(hex: 0xF4EFE8), fillRole: "brand.1"))),
            CreativeLayer(name: "Brand", x: 80, y: 1090, width: 840, height: 40,
                          content: .text(TextLayer(text: "{{brand}}", fontName: "Helvetica Neue", size: 26, color: RGBA(hex: 0x2A211C, alpha: 0.7),
                                                   colorRole: "brand.0", fontRole: "body", tracking: 4, uppercase: true))),
            CreativeLayer(name: "Headline", x: 80, y: 1140, width: 840, height: 180,
                          content: .text(TextLayer(text: "{{product_name}}", fontName: "Instrument Serif", size: 76, lineHeight: 1.02, color: RGBA(hex: 0x2A211C),  // grid: ok canvas pixels or computed position
                                                   colorRole: "brand.0", fontRole: "headline"))),
            CreativeLayer(name: "Price", x: 80, y: 1380, width: 300, height: 60,
                          content: .text(TextLayer(text: "{{price}}", fontName: "Helvetica Neue", size: 44, color: RGBA(hex: 0x2A211C), colorRole: "brand.0", fontRole: "body"))),
            CreativeLayer(name: "Button", x: 560, y: 1366, width: 360, height: 80, group: "Button",
                          content: .shape(ShapeLayer(kind: .rectangle, fill: RGBA(hex: 0xFF8A5C), cornerRadius: 40, fillRole: "brand.2"))),
            CreativeLayer(name: "Call to action", x: 560, y: 1388, width: 360, height: 50, group: "Button",  // grid: ok canvas pixels or computed position
                          content: .text(TextLayer(text: "{{cta}}", fontName: "Helvetica Neue", size: 30, color: .white, alignment: .center,
                                                   colorRole: "brand.1", fontRole: "body"))),
        ])
    }
}

extension AppModel {
    var templates: [CreativeTemplate] {
        guard let workspaceID else { return [] }
        return (try? context.fetch(FetchDescriptor<CreativeTemplate>(predicate: #Predicate { $0.workspaceID == workspaceID },
                                                                    sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Every workspace starts with three editable brand templates.
    func ensureBuiltInTemplates() {
        guard let workspaceID, templates.isEmpty else { return }
        for doc in [StudioModel.productPin(), StudioModel.centered(), StudioModel.priceCard()] {
            context.insert(CreativeTemplate(workspaceID: workspaceID, document: doc, category: "Pinterest Pin"))
        }
        try? context.save()
    }
}

import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

struct MediaLibraryView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \MediaAsset.importedAt, order: .reverse) private var allAssets: [MediaAsset]
    @Query(sort: \CreativeTemplate.updatedAt, order: .reverse) private var allTemplates: [CreativeTemplate]
    @State private var filter: Filter = .all
    @State private var sort: Sort = .filename
    @State private var collection: String?
    @State private var dropTargeted = false
    @State private var lastClicked: UUID?
    @State private var newCollection = ""
    @State private var showCollectionPrompt = false

    enum Filter: String, CaseIterable { case all = "All", favorites = "Favorites", images = "Images", videos = "Videos", audio = "Audio", variants = "Branded" }
    enum Sort: String, CaseIterable { case filename = "Filename", newest = "Newest", size = "Size" }

    private var mine: [MediaAsset] { allAssets.filter { $0.workspaceID == model.workspaceID } }
    private var collections: [String] { Array(Set(mine.map(\.collection).filter { !$0.isEmpty })).sorted() }

    private var assets: [MediaAsset] {
        let q = model.searchText
        let filtered = mine.filter { a in
            (collection == nil || a.collection == collection) && {
                switch filter {
                case .all: true
                case .favorites: a.isFavorite
                case .images: a.kind == "image"
                case .videos: a.kind == "video"
                case .audio: a.kind == "audio"
                case .variants: a.tags.contains("branded")
                }
            }() && (q.isEmpty || a.filename.localizedCaseInsensitiveContains(q) || a.title.localizedCaseInsensitiveContains(q)
                    || a.tags.contains { $0.localizedCaseInsensitiveContains(q) })
        }
        switch sort {
        case .newest: return filtered
        case .filename: return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        }
    }

    var body: some View {
        let shown = assets
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.lg) {
                AutomationBar()
                dropZone
                HStack(spacing: Space.sm) {
                    Menu {
                        Button("All media") { collection = nil }
                        if !collections.isEmpty { Divider() }
                        ForEach(collections, id: \.self) { c in Button(c) { collection = c } }
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text(collection ?? "All media").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                            Image(systemName: "chevron.down").font(.caption).foregroundStyle(DS.text2)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Text("· " + selectionText(shown)).font(DS.body).foregroundStyle(DS.text2)
                    Spacer()
                    PillPicker(options: Filter.allCases, selection: $filter) { $0.rawValue }
                    Menu {
                        ForEach(Sort.allCases, id: \.self) { s in Button(s.rawValue) { sort = s } }
                    } label: { Text("Sort: \(sort.rawValue)").font(DS.body).foregroundStyle(DS.text2) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                if !model.mediaSelection.isEmpty { bulkBar(shown) }
            }
            .padding([.horizontal, .top], Space.xxl)
            .padding(.bottom, Space.lg)
            if shown.isEmpty {
                EmptyState(symbol: "photo.on.rectangle", title: mine.isEmpty ? "Your library is empty" : "Nothing matches",
                           message: mine.isEmpty ? "Drop images, folders, or a CSV anywhere on this page. Files are copied in; your originals are never changed."
                                                  : "Try another filter or search.") {
                    if mine.isEmpty { Button("Import…") { ImportPanel.run(model: model) }.buttonStyle(PrimaryButtonStyle()) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Space.lg)], spacing: Space.lg) {
                        ForEach(shown) { a in
                            MediaTile(asset: a, selected: model.mediaSelection.contains(a.uuid))
                                .onTapGesture { click(a, in: shown) }
                                .contextMenu { menu(for: a) }
                                .draggable(a.storedURL)
                        }
                    }
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.xxl)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { _ = await model.importMedia(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert("Add to collection", isPresented: $showCollectionPrompt) {
            TextField("Collection name", text: $newCollection)
            Button("Add") { setCollection(newCollection) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var dropZone: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18)).foregroundStyle(DS.accent)
                .frame(width: 44, height: 44).background(DS.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                if let p = model.importProgress {
                    Text("Importing \(p.done) of \(p.total)…").font(DS.bodyMedium)
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 240)
                } else if let p = model.variantProgress {
                    Text("Making variants \(p.done) of \(p.total)…").font(DS.bodyMedium)
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 240)
                } else {
                    Text("Drop images, folders or a CSV").font(DS.bodyMedium)
                    Text(model.lastImportSummary?.components(separatedBy: "\n").first ?? "Files are matched to CSV rows by filename or SKU. Originals are never changed.")
                        .font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
                }
            }
            Spacer()
            if let csv = model.bulk.csvName {
                HStack(spacing: Space.sm) {
                    Image(systemName: "doc.text").foregroundStyle(DS.green)
                    Text(csv).font(DS.bodyMedium)
                    Text(model.bulk.report.map { "\($0.matched.count) rows matched" } ?? "\(model.bulk.table?.rows.count ?? 0) rows")
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                .padding(.horizontal, Space.md).frame(height: 36)
                .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            }
            Button("Import…") { ImportPanel.run(model: model) }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(Space.lg)
        .background(dropTargeted ? DS.accentSoft : DS.accentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(DS.accentFill.opacity(dropTargeted ? 1 : 0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
    }

    private func bulkBar(_ shown: [MediaAsset]) -> some View {
        let targets = model.assets(model.mediaSelection)
        let templates = allTemplates.filter { $0.workspaceID == model.workspaceID }
        return HStack(spacing: Space.sm) {
            Text("\(targets.count) selected").font(DS.bodyMedium)
            Menu("Make Variant") {
                ForEach(ExportPreset.builtIn) { preset in
                    Button("\(preset.name) · \(preset.width) × \(preset.height)") { Task { _ = await model.makeVariants(targets, preset: preset) } }
                }
            }
            .fixedSize()
            Menu("Apply Brand Template") {
                if templates.isEmpty { Text("No templates yet. Save one in Creative Studio.") }
                ForEach(templates) { t in
                    Button(t.name) { Task { await model.studio.applyTemplate(t, to: targets, model: model) } }
                }
            }
            .fixedSize()
            .help("Make one branded graphic per image with real, editable text")
            Menu("Collection") {
                ForEach(collections, id: \.self) { c in Button(c) { setCollection(c) } }
                Divider()
                Button("New Collection…") { newCollection = ""; showCollectionPrompt = true }
                Button("Remove from Collection") { setCollection("") }
            }
            .fixedSize()
            Button("Use in Bulk Publisher") {
                model.bulk.assetIDs = shown.filter { model.mediaSelection.contains($0.uuid) }.map(\.uuid)
                model.page = .bulk
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button("Select All") { model.mediaSelection = Set(shown.map(\.uuid)) }.buttonStyle(.plain).foregroundStyle(DS.text2)
            Button("Clear") { model.mediaSelection = [] }.buttonStyle(.plain).foregroundStyle(DS.text2)
        }
        .card(padding: Space.sm)
    }

    private func setCollection(_ name: String) {
        for a in model.assets(model.mediaSelection) { a.collection = name.trimmingCharacters(in: .whitespaces) }
        try? model.context.save()
    }

    private func selectionText(_ shown: [MediaAsset]) -> String {
        let n = model.mediaSelection.count
        return n == 0 ? "\(shown.count) items" : "\(n) of \(shown.count) selected"
    }

    /// Click selects one; Command-click toggles; Shift-click extends.
    private func click(_ a: MediaAsset, in shown: [MediaAsset]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.mediaSelection.contains(a.uuid) { model.mediaSelection.remove(a.uuid) } else { model.mediaSelection.insert(a.uuid) }
        } else if flags.contains(.shift), let last = lastClicked,
                  let i = shown.firstIndex(where: { $0.uuid == last }), let j = shown.firstIndex(where: { $0.uuid == a.uuid }) {
            model.mediaSelection.formUnion(shown[min(i, j)...max(i, j)].map(\.uuid))
        } else {
            model.mediaSelection = [a.uuid]
        }
        lastClicked = a.uuid
    }

    @ViewBuilder
    private func menu(for a: MediaAsset) -> some View {
        let targets = model.mediaSelection.contains(a.uuid) ? model.assets(model.mediaSelection) : [a]
        Button(a.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            let on = !a.isFavorite
            for t in targets { t.isFavorite = on }
            try? model.context.save()
        }
        Button("Open in Creative Studio") {
            model.studio.openNew(model: model, photoPath: a.storedPath)
            model.page = .studio
        }
        Button("Use as AI Background Reference") { model.aiStudio.referenceAssetID = a.uuid; model.page = .ai }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.storedURL)) }
        Divider()
        Button("Remove from Library", role: .destructive) {
            for t in targets {
                for v in model.variants(of: t.uuid) { model.context.delete(v) }
                model.context.delete(t)
            }
            model.mediaSelection.subtract(targets.map(\.uuid))
            try? model.context.save()
        }
    }
}

struct MediaTile: View {
    let asset: MediaAsset
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Thumbnail(path: asset.storedPath, maxPixel: 440)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? DS.accentFill : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(selected ? DS.accentFill : .black.opacity(0.25)).frame(width: 24, height: 24)
                        Circle().strokeBorder(.white.opacity(selected ? 0 : 0.8), lineWidth: 2).frame(width: 24, height: 24)
                        if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.onAccent) }
                    }
                    .padding(Space.sm)
                }
                .overlay(alignment: .topLeading) {
                    if asset.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).padding(Space.sm) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if asset.duration > 0 {
                        Text(Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond))).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, Space.sm).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule()).padding(Space.sm)
                    }
                }
            Text(asset.filename).font(DS.mono).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(asset.filename)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Inspector

struct MediaInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var allAssets: [MediaAsset]
    @State private var preset = ExportPreset.builtIn[0]
    @State private var mode: FitMode = .fill
    @State private var format: OutputFormat = .jpeg
    @State private var quality = 0.85
    @State private var keepMetadata = false

    private var selected: [MediaAsset] { allAssets.filter { model.mediaSelection.contains($0.uuid) } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Selection") { Text(selected.isEmpty ? "None" : "\(selected.count) image\(selected.count == 1 ? "" : "s")") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                if model.bulk.table != nil { CSVMappingPanel() }
                if selected.count == 1, let a = selected.first { AssetDetails(asset: a) }
                if selected.isEmpty && model.bulk.table == nil {
                    Text("Select media to see its details, make platform variants, or apply a brand template.").font(DS.body).foregroundStyle(DS.text2)
                }
                if !selected.isEmpty { transform }
            }
        }
    }

    private var transform: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Transform image")
            Picker("Preset", selection: $preset) {
                ForEach(ExportPreset.builtIn) { Text("\($0.name) · \($0.width) × \($0.height)").tag($0) }
            }
            PillPicker(options: FitMode.allCases, selection: $mode) { $0 == .fill ? "Fill and crop" : "Fit and pad" }
            if let a = selected.first { CropPreview(asset: a, preset: preset, mode: mode) }
            HStack {
                Picker("Format", selection: $format) { ForEach(OutputFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()) } }.fixedSize()
                Spacer()
                Text("Quality \(Int(quality * 100))").font(DS.small).foregroundStyle(DS.text2)
                Slider(value: $quality, in: 0.5...1).frame(width: 100)
            }
            Toggle("Keep camera metadata (EXIF)", isOn: $keepMetadata).toggleStyle(SFToggleStyle()).font(DS.body)
            Button("Make \(selected.count == 1 ? "Variant" : "\(selected.count) Variants")") {
                var p = preset
                p.mode = mode
                p.format = format
                p.quality = quality
                p.stripMetadata = !keepMetadata
                let targets = selected
                Task { _ = await model.makeVariants(targets, preset: p) }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            .disabled(model.variantProgress != nil)
            Text("Originals are never changed. Variants are sRGB; camera metadata and location are removed unless you keep them.")
                .font(DS.caption).foregroundStyle(DS.text3)
        }
    }
}

/// Shows which part of the image a preset keeps, before anything is made.
struct CropPreview: View {
    let asset: MediaAsset
    let preset: ExportPreset
    let mode: FitMode

    var body: some View {
        let canvas = CGSize(width: preset.width, height: preset.height)
        let src = CGSize(width: max(1, asset.width), height: max(1, asset.height))
        let (draw, _) = ImageTransformer.layout(source: src, canvas: canvas, mode: mode)
        GeometryReader { geo in
            let s = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white)
                Thumbnail(path: asset.storedPath, maxPixel: 600, contentMode: .fit)
                    .frame(width: draw.width * s, height: draw.height * s)
                    .offset(x: draw.minX * s, y: (canvas.height - draw.maxY) * s)  // grid: ok maps preset pixels to the preview
            }
            .frame(width: canvas.width * s, height: canvas.height * s)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 200)
        .accessibilityLabel("Preview of \(preset.name)")
    }
}

struct AssetDetails: View {
    @Bindable var asset: MediaAsset
    @Environment(AppModel.self) private var model
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Group {
                if asset.kind == "image" {
                    Thumbnail(path: asset.storedPath, maxPixel: 600, contentMode: .fit)
                } else {
                    // Plays video and audio in place.
                    VideoPlayer(player: AVPlayer(url: asset.storedURL))
                }
            }
            .frame(height: asset.kind == "audio" ? 64 : 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .id(asset.uuid)
            VStack(spacing: 0) {
                KeyValueRow("File", asset.filename)
                KeyValueRow("Size", "\(asset.kind == "audio" ? "Audio" : asset.dimensions) · \(asset.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(asset.bytes), countStyle: .file))")
                if asset.duration > 0 { KeyValueRow("Length", Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)))) }
                if asset.hasAlpha { KeyValueRow("Transparency", "Yes") }
                KeyValueRow(key: "SHA-256") { Text(asset.sha256.prefix(16) + "…").font(DS.mono).textSelection(.enabled) }
            }
            SectionLabel("Publishing metadata")
            TextField("Title", text: $asset.title).fieldStyle()
            TextField("Product URL", text: $asset.productURL).fieldStyle()
            TextField("Alt text", text: $asset.altText, axis: .vertical).lineLimit(1...3).fieldStyle()
            TextField("Collection", text: $asset.collection).fieldStyle()
            TextField("Tags (comma separated)", text: $tagText).fieldStyle()
                .onSubmit { asset.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                .onAppear { tagText = asset.tags.joined(separator: ", ") }
            Toggle("Favorite", isOn: $asset.isFavorite).toggleStyle(SFToggleStyle()).font(DS.body)
            let variants = model.variants(of: asset.uuid)
            if !variants.isEmpty {
                SectionLabel("Variants · history")
                ForEach(variants) { v in
                    HStack {
                        Thumbnail(path: v.path, maxPixel: 96).frame(width: 28, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading) {
                            Text(v.presetName).font(DS.body)
                            Text("\(v.width) × \(v.height) · \(ByteCountFormatter.string(fromByteCount: Int64(v.bytes), countStyle: .file)) · \(v.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(DS.caption).foregroundStyle(DS.text2)
                        }
                        Spacer()
                        Button("Show", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([v.url]) }
                            .labelStyle(.iconOnly).buttonStyle(IconButtonStyle()).help("Show in Finder")
                    }
                }
            }
        }
    }
}

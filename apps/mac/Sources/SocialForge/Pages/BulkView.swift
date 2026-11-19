import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SocialForgeKit

// MARK: - Cadence controls mapped onto the schedule rule

enum CadenceUnit: String, CaseIterable { case hours, days, weeks }

extension BulkSession {
    var pickDates: Bool {
        get { rule.onlyDays != nil }
        set { rule.onlyDays = newValue ? (rule.onlyDays ?? []) : nil }
    }

    var unit: CadenceUnit {
        get { rule.everyHours != nil ? .hours : (rule.everyDays % 7 == 0 && rule.everyDays >= 7 ? .weeks : .days) }
        set {
            let n = every
            switch newValue {
            case .hours: rule.everyHours = n; rule.everyDays = 1
            case .days: rule.everyHours = nil; rule.everyDays = n
            case .weeks: rule.everyHours = nil; rule.everyDays = n * 7
            }
        }
    }

    var every: Int {
        get { rule.everyHours ?? (unit == .weeks ? rule.everyDays / 7 : rule.everyDays) }
        set {
            let n = max(1, min(60, newValue))
            switch unit {
            case .hours: rule.everyHours = n
            case .days: rule.everyDays = n
            case .weeks: rule.everyDays = n * 7
            }
        }
    }

    var skipWeekends: Bool {
        get { rule.weekdays == ScheduleRule.weekdaysOnly }
        set { rule.weekdays = newValue ? ScheduleRule.weekdaysOnly : [] }
    }

    func toggleTime(_ t: LocalTime) {
        if rule.times.contains(t) {
            if rule.times.count > 1 { rule.times.removeAll { $0 == t } }
        } else {
            rule.times = (rule.times + [t]).sorted()
        }
    }

    func togglePicked(_ d: LocalDay) {
        var set = rule.onlyDays ?? []
        if set.contains(d) { set.remove(d) } else { set.insert(d) }
        rule.onlyDays = set
    }

    struct PreviewRow: Identifiable {
        let id: UUID
        let asset: MediaAsset
        let when: Date?
        let title: String
        let link: String
        let ambiguous: Bool
    }

    /// What "Save draft" would create, so the queue shows the run before anything is stored.
    func preview(_ assets: [MediaAsset]) -> [PreviewRow] {
        let ambiguous = Set(report?.ambiguous.keys.map { $0 } ?? [])
        let rows = Dictionary((report?.matched ?? []).map { ($0.mediaID, $0) }, uniquingKeysWith: { a, _ in a })
        let usable = assets.filter { !ambiguous.contains($0.uuid.uuidString) }
        let slots = (try? ScheduleBuilder.slots(rule, count: usable.count)) ?? []
        var slotFor: [UUID: Date] = [:]
        for (a, s) in zip(usable, slots) { slotFor[a.uuid] = s.instant }
        return assets.map { a in
            let row = useCSV ? rows[a.uuid.uuidString] : nil
            return PreviewRow(id: a.uuid, asset: a, when: slotFor[a.uuid],
                              title: row?.title.nonEmpty ?? a.title.nonEmpty ?? BulkSession.titleFromFilename(a.filename),
                              link: row?.url.nonEmpty ?? a.productURL, ambiguous: ambiguous.contains(a.uuid.uuidString))
        }
    }

    /// "Winter Collection → Pinterest · Every day at 9:00 AM".
    @MainActor
    func sentence(model: AppModel) -> String {
        let acct = model.accounts.first { $0.serverID == accountID }
        var s = assetIDs.isEmpty ? "No run yet" : runName
        if let acct { s += " → " + (PlatformRegistry.spec(acct.platform)?.name ?? acct.platform) }
        let times = rule.times.map(\.label).joined(separator: ", ")
        if rule.onlyDays != nil {
            s += " · \(rule.onlyDays?.count ?? 0) picked dates at \(times)"
        } else if let h = rule.everyHours {
            s += " · Every \(h) hours from \(times)"
        } else {
            s += " · " + (every == 1 ? "Every \(unit == .weeks ? "week" : "day")" : "Every \(every) \(unit.rawValue)") + " at \(times)"
        }
        if skipWeekends { s += ", weekdays" }
        return s
    }
}

extension LocalTime {
    var label: String { String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM") }
}

extension LocalDay {
    var formatted: String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        guard let d = c.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return description }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }
}

// MARK: - Page

struct BulkView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query private var allAssets: [MediaAsset]
    @State private var dropTargeted = false

    private var bulk: BulkSession { model.bulk }
    private var runAssets: [MediaAsset] {
        let byID = Dictionary(allAssets.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        return bulk.assetIDs.compactMap { byID[$0] }
    }
    /// Posts of this workspace not yet live: the review queue.
    private var queue: [Publication] {
        allPubs.filter { $0.workspaceID == model.workspaceID && ($0.status.isLocal || $0.status == .paused) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                AutomationBar()
                imagesCard
                queueSection
            }
            .padding(Space.xxl)
        }
        .onChange(of: bulk.assetIDs) { bulk.rematch(assets: runAssets) }
        .onChange(of: bulk.mapping) { bulk.rematch(assets: runAssets) }
        .onChange(of: bulk.strategy) { bulk.rematch(assets: runAssets) }
        .onChange(of: bulk.csvName) { bulk.rematch(assets: runAssets) }
        .onAppear { bulk.rematch(assets: runAssets) }
    }

    private var imagesCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("Images").font(.system(size: 15, weight: .semibold))
                Text(imagesSubtitle).font(DS.body).foregroundStyle(DS.text2).lineLimit(1)
                if let e = bulk.csvError { Label(e, systemImage: "exclamationmark.triangle.fill").font(DS.small).foregroundStyle(DS.red) }
                Spacer()
                Label("Drop images from Finder · drag thumbnails to reorder", systemImage: "square.and.arrow.up")
                    .font(DS.small).foregroundStyle(DS.text2).lineLimit(1)
                Menu {
                    Button("Use Library Selection (\(model.mediaSelection.count))") { bulk.assetIDs = orderedSelection() }
                        .disabled(model.mediaSelection.isEmpty)
                    Button("Import Folder…") { ImportPanel.run(model: model); takeNextImport() }
                    Button("Choose CSV…") { chooseCSV() }
                    if !runAssets.isEmpty {
                        Divider()
                        Button("Clear Images") { bulk.assetIDs = [] }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
                .help("Add images or a CSV")
            }
            if runAssets.isEmpty {
                VStack(spacing: Space.sm) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 22)).foregroundStyle(DS.accent)
                    Text("Drop a folder of images and a CSV here").font(DS.bodyMedium)
                    Text("Images are matched to rows by filename or SKU. Rows that could belong to two images are flagged, never guessed.")
                        .font(DS.small).foregroundStyle(DS.text2).multilineTextAlignment(.center)
                    HStack {
                        Button("Use Library Selection") { bulk.assetIDs = orderedSelection() }.buttonStyle(SecondaryButtonStyle())
                            .disabled(model.mediaSelection.isEmpty)
                        Button("Import Folder…") { ImportPanel.run(model: model); takeNextImport() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.top, Space.xs)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 15), spacing: Space.sm) {
                    ForEach(Array(runAssets.enumerated()), id: \.element.uuid) { i, a in
                        RunTile(asset: a, index: i + 1, state: matchState(a))
                            .draggable(a.uuid.uuidString)
                            .dropDestination(for: String.self) { items, _ in return move(items, before: a.uuid) }
                    }
                }
            }
        }
        .card(padding: Space.lg)
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(DS.accentFill, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).opacity(dropTargeted ? 1 : 0))
        .dropDestination(for: URL.self) { urls, _ in
            Task {
                let made = await model.importMedia(urls)
                let existing = Set(bulk.assetIDs)
                bulk.assetIDs += made.map(\.uuid).filter { !existing.contains($0) }
                bulk.rematch(assets: runAssets)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var imagesSubtitle: String {
        var s = "\(runAssets.count) images"
        if let csv = bulk.csvName { s += " · \(csv)" }
        if let r = bulk.report, bulk.useCSV { s += " · " + r.summary }
        return s
    }

    @ViewBuilder
    private var queueSection: some View {
        let preview = queue.isEmpty ? bulk.preview(runAssets) : []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("Queue").font(.system(size: 15, weight: .semibold))
                Text(queueSubtitle(preview: preview)).font(DS.body).foregroundStyle(DS.text2)
                Spacer()
                if !queue.isEmpty {
                    Button("Reschedule") {
                        do { try bulk.reschedule(queue.filter { $0.status.isLocal }) } catch { model.lastError = "\(error)" }
                        try? model.context.save()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Put these posts on the cadence in the inspector, keeping images and copy")
                } else if !preview.isEmpty {
                    Text("Preview · nothing is saved yet").font(DS.small).foregroundStyle(DS.text3)
                }
            }
            .padding(.bottom, Space.md)
            if let r = bulk.report, !r.ambiguous.isEmpty {
                ForEach(r.ambiguous.keys.sorted(), id: \.self) { id in
                    let name = runAssets.first { $0.uuid.uuidString == id }?.filename ?? id
                    Label("\(name) could match rows \(r.ambiguous[id]!.map { String($0 + 2) }.joined(separator: ", ")). It is left out until you rename the file or fix the CSV.",
                          systemImage: "questionmark.diamond.fill")
                        .font(DS.small).foregroundStyle(DS.amber).padding(.bottom, Space.sm)
                }
            }
            Divider().overlay(DS.stroke)
            if queue.isEmpty && preview.isEmpty {
                Text("Add images to see the run here.").foregroundStyle(DS.text2).padding(.vertical, Space.xl)
            }
            ForEach(queue) { p in
                QueueRow(thumb: model.asset(p.assetID)?.storedPath, title: p.title, link: p.link, when: p.scheduledAt,
                         platforms: [p.platform], status: p.status, issues: p.issues(model: model).filter { $0.level == .error }.count,
                         selected: model.publicationSelection.contains(p.id))
                    .contentShape(Rectangle())
                    .onTapGesture { select(p) }
                    .contextMenu { PublicationMenu(ids: model.publicationSelection.contains(p.id) ? model.publicationSelection : [p.id]) }
                Divider().overlay(DS.stroke)
            }
            ForEach(preview) { r in
                QueueRow(thumb: r.asset.storedPath, title: r.title, link: r.link, when: r.when, platforms: bulk.accountID == nil ? [] : ["pinterest"],
                         status: nil, issues: r.ambiguous ? 1 : 0, selected: false)
                Divider().overlay(DS.stroke)
            }
        }
    }

    private func queueSubtitle(preview: [BulkSession.PreviewRow]) -> String {
        let dates = queue.isEmpty ? preview.compactMap(\.when) : queue.map(\.scheduledAt)
        let n = queue.isEmpty ? preview.count : queue.count
        guard let first = dates.min(), let last = dates.max() else { return "\(n) posts" }
        let f = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        return "\(n) posts · \(first.formatted(f)) → \(last.formatted(f))"
    }

    private func select(_ p: Publication) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.publicationSelection.contains(p.id) { model.publicationSelection.remove(p.id) } else { model.publicationSelection.insert(p.id) }
        } else {
            model.publicationSelection = [p.id]
        }
    }

    private func matchState(_ a: MediaAsset) -> RunTile.State {
        guard let r = bulk.report, bulk.useCSV else { return .noCSV }
        let id = a.uuid.uuidString
        if r.ambiguous[id] != nil { return .ambiguous }
        if r.matched.contains(where: { $0.mediaID == id }) { return .matched }
        return .unmatched
    }

    private func move(_ items: [String], before target: UUID) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), id != target,
              let from = bulk.assetIDs.firstIndex(of: id) else { return false }
        var ids = bulk.assetIDs
        ids.remove(at: from)
        let to = ids.firstIndex(of: target) ?? ids.endIndex
        ids.insert(id, at: to)
        bulk.assetIDs = ids
        return true
    }

    private func orderedSelection() -> [UUID] {
        allAssets.filter { model.mediaSelection.contains($0.uuid) && $0.workspaceID == model.workspaceID }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }.map(\.uuid)
    }

    private func takeNextImport() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            while model.importProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
            if !model.mediaSelection.isEmpty { bulk.assetIDs = orderedSelection() }
        }
    }

    private func chooseCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a CSV with filenames or SKUs and destination links."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bulk.loadCSV(url)
        bulk.rematch(assets: runAssets)
    }
}

struct RunTile: View {
    let asset: MediaAsset
    let index: Int
    let state: State

    enum State { case noCSV, matched, unmatched, ambiguous }

    var body: some View {
        Thumbnail(path: asset.storedPath, maxPixel: 200)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("\(index)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                switch state {
                case .noCSV, .matched: EmptyView()
                case .unmatched: Circle().fill(DS.text3).frame(width: 8, height: 8).padding(4)
                case .ambiguous: Circle().fill(DS.amber).frame(width: 8, height: 8).padding(4)
                }
            }
            .help(asset.filename + (state == .ambiguous ? " · ambiguous CSV match" : state == .unmatched ? " · no CSV row" : ""))
    }
}

struct QueueRow: View {
    let thumb: String?
    let title: String
    let link: String
    let when: Date?
    let platforms: [String]
    let status: PublicationStatus?
    let issues: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.lg) {
            Thumbnail(path: thumb, maxPixel: 120).frame(width: 40, height: 52).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title).font(DS.bodyMedium).foregroundStyle(DS.text).lineLimit(1)
                Text(link.isEmpty ? "No destination link" : link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                    .font(DS.small).foregroundStyle(link.isEmpty ? DS.amber : DS.text2).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(when.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "No slot")
                .font(DS.body).foregroundStyle(DS.textBody).frame(width: 192, alignment: .leading)
            HStack(spacing: 4) { ForEach(platforms, id: \.self) { PlatformBadge(platform: $0, size: 16) } }.frame(width: 60, alignment: .leading)
            Group {
                if issues > 0 {
                    StatusDot(text: "\(issues) problem\(issues == 1 ? "" : "s")", color: DS.red)
                } else if let status {
                    StatusChip(status: status)
                } else {
                    StatusDot(text: "Preview", color: DS.text3)
                }
            }
            .frame(width: 128, alignment: .leading)
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.sm)
        .background(selected ? DS.fillSelected : .clear, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
    }
}

/// The design's automation bar: AI | Manual, the run in one line, counts, and Pause.
struct AutomationBar: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @State private var aiMode = false
    @State private var request = ""

    var body: some View {
        let pubs = allPubs.filter { $0.workspaceID == model.workspaceID }
        let live = pubs.filter { [.scheduled, .approved].contains($0.status) && $0.serverID == nil }
        let paused = pubs.filter { $0.status == .paused }
        let waiting = pubs.filter { $0.status == .needsReview }.count
        HStack(spacing: Space.md) {
            HStack(spacing: 2) {
                modeButton("AI", "sparkles", on: aiMode) { aiMode = true }
                modeButton("Manual", "cursorarrow", on: !aiMode) { aiMode = false }
            }
            .padding(2)
            .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            if aiMode {
                TextField("Tell SocialForge what to do: “Schedule these 20 Pins over the next month”", text: $request)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { plan() }
                Button("Plan") { plan() }.buttonStyle(SecondaryButtonStyle()).disabled(request.isEmpty)
            } else {
                Text(model.bulk.sentence(model: model)).font(.system(size: 14)).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                Text("\(pubs.filter { $0.status != .canceled }.count) posts · \(waiting) awaiting approval").font(DS.small).foregroundStyle(DS.text2)
                Button(paused.isEmpty ? "Pause" : "Resume") {
                    if paused.isEmpty {
                        for p in live { p.status = .paused }
                        model.log("Paused \(live.count) posts", symbol: "pause.circle")
                    } else {
                        for p in paused { p.status = .needsReview }
                        model.log("Resumed \(paused.count) posts for review", symbol: "play.circle")
                    }
                    try? model.context.save()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(live.isEmpty && paused.isEmpty)
                .help(paused.isEmpty ? "Hold every post scheduled on this Mac" : "Send paused posts back to review")
            }
        }
        .card(padding: Space.sm)
    }

    private func plan() {
        guard !request.isEmpty else { return }
        model.aiStudio.pendingCommand = request
        model.showCommandPanel = true
    }

    private func modeButton(_ title: String, _ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? DS.text : DS.text2)
                .padding(.horizontal, Space.md).frame(height: 32)
                .background(on ? DS.fillSelected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inspector

struct BulkInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.publicationSelection.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Button { model.publicationSelection = [] } label: { Label("Pipeline", systemImage: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(DS.text2)
                    Spacer()
                }
                .padding(.horizontal, Space.xl).frame(height: 40)
                PublicationInspector()
            }
        } else {
            BulkPipelinePanel()
        }
    }
}

struct BulkPipelinePanel: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query private var allAssets: [MediaAsset]
    @State private var startDate = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
    @State private var customTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now)!
    @State private var confirmSchedule = false
    @State private var result: String?
    @State private var showMapping = false

    private var bulk: BulkSession { model.bulk }
    private var queue: [Publication] { allPubs.filter { $0.workspaceID == model.workspaceID && $0.status.isLocal } }
    private var approved: [Publication] { queue.filter { $0.status == .approved } }
    private var runAssets: [MediaAsset] {
        let byID = Dictionary(allAssets.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        return bulk.assetIDs.compactMap { byID[$0] }
    }

    static let timeOptions = [LocalTime(8), LocalTime(9), LocalTime(12, 30), LocalTime(20, 30)]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Pipeline") { Text("\(max(queue.count, runAssets.count)) posts") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                postTo
                csvSection
                cadence
                optimize
                GenerateSection(publications: queue)
                approval
            }
            Divider().overlay(DS.stroke)
            footer
        }
        .onAppear { syncDates() }
        .confirmationDialog("Schedule \(approved.count) approved posts?", isPresented: $confirmSchedule) {
            Button("Schedule \(approved.count) Posts") {
                let send = approved
                Task {
                    let r = await model.activate(send)
                    result = r.failed.isEmpty ? "Scheduled \(r.sent) posts." : "Scheduled \(r.sent). Not scheduled:\n" + r.failed.joined(separator: "\n")
                }
            }
        } message: {
            Text(model.publishMode == .mac
                 ? "This Mac publishes them at their times while SocialForge is open, or while it is closed if the background publisher is on. Posts due while the Mac sleeps go out when it wakes."
                 : "They go to the publishing service and publish at their times, even while this Mac is asleep.")
        }
        .alert("Schedule", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") { result = nil }
        } message: { Text(result ?? "") }
    }

    private var postTo: some View {
        @Bindable var bulk = model.bulk
        let pins = model.accounts.filter { $0.platform == "pinterest" }
        return VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Post to")
            ForEach(pins) { a in
                HStack(spacing: Space.md) {
                    PlatformBadge(platform: "pinterest", size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name + (a.isMock ? " (mock)" : "")).font(DS.bodyMedium)
                        Menu {
                            ForEach(model.boards[a.serverID] ?? []) { b in Button(b.name) { bulk.accountID = a.serverID; bulk.boardID = b.id } }
                            Button("Reload Boards") { Task { await model.refreshAccounts() } }
                        } label: {
                            Text("Board · " + ((model.boards[a.serverID] ?? []).first { $0.id == bulk.boardID }?.name ?? "Choose…"))
                                .font(DS.small).foregroundStyle(DS.text2)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { bulk.accountID == a.serverID }, set: { bulk.accountID = $0 ? a.serverID : nil }))
                        .toggleStyle(SFToggleStyle()).labelsHidden().fixedSize()
                }
                ForEach(a.capabilities.filter { !$0.allowed }, id: \.contentType.id) { c in
                    Label(c.reason ?? "", systemImage: "lock.fill").font(DS.small).foregroundStyle(DS.amber)
                }
            }
            if pins.isEmpty {
                HStack {
                    Text("No Pinterest account yet.").font(DS.body).foregroundStyle(DS.text2)
                    Spacer()
                    Button("Add Mock") { model.addMockAccount() }.buttonStyle(SecondaryButtonStyle())
                    Button("Connect") { model.page = .accounts }.buttonStyle(SecondaryButtonStyle())
                }
            }
            ForEach(["facebook", "x", "linkedin"], id: \.self) { p in
                HStack(spacing: Space.md) {
                    PlatformBadge(platform: p, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PlatformRegistry.spec(p)?.name ?? p).font(DS.bodyMedium).foregroundStyle(DS.text2)
                        Text("Publishing comes in milestone 4").font(DS.small).foregroundStyle(DS.text3)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(false)).toggleStyle(SFToggleStyle()).labelsHidden().fixedSize().disabled(true).opacity(0.4)
                }
            }
        }
    }

    private var csvSection: some View {
        @Bindable var bulk = model.bulk
        return VStack(alignment: .leading, spacing: Space.sm) {
            Toggle(isOn: $bulk.useCSV) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Product links from CSV").font(DS.bodyMedium)
                    Text(bulk.csvName.map { "\($0) → \(bulk.mapping.url ?? "no link column")" } ?? "No CSV yet").font(DS.small).foregroundStyle(DS.text2)
                }
            }
            .toggleStyle(SFToggleStyle())
            .disabled(bulk.table == nil)
            if bulk.table != nil {
                Button("Column mapping…") { showMapping.toggle() }.buttonStyle(LinkButtonStyle())
                    .popover(isPresented: $showMapping, arrowEdge: .leading) { CSVMappingPanel().frame(width: 340).padding(Space.lg) }
            }
        }
    }

    private var cadence: some View {
        @Bindable var bulk = model.bulk
        return VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Cadence", trailing: AnyView(
                PillPicker(options: [false, true], selection: Binding(get: { bulk.pickDates }, set: { bulk.pickDates = $0 })) { $0 ? "Pick dates" : "Interval" }))
            if bulk.pickDates {
                MiniMonthPicker(start: bulk.rule.start, selected: bulk.rule.onlyDays ?? []) { bulk.togglePicked($0) }
            } else {
                HStack {
                    Text("Every").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                    HStack(spacing: 0) {
                        Button("−") { bulk.every -= 1 }.buttonStyle(.plain).frame(width: 24).accessibilityLabel("Fewer")
                        Text("\(bulk.every)").font(DS.bodyMedium).monospacedDigit().frame(width: 24)
                        Button("+") { bulk.every += 1 }.buttonStyle(.plain).frame(width: 24).accessibilityLabel("More")
                    }
                    .frame(height: 28)
                    .background(DS.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    PillPicker(options: CadenceUnit.allCases, selection: Binding(get: { bulk.unit }, set: { bulk.unit = $0 })) { $0.rawValue }
                }
            }
            HStack(alignment: .top) {
                Text("At").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading).padding(.top, Space.xs)
                FlowLayout(spacing: Space.xs) {
                    ForEach(Array(Set(Self.timeOptions + bulk.rule.times)).sorted(), id: \.self) { t in
                        Chip(text: t.label, selected: bulk.rule.times.contains(t)) { bulk.toggleTime(t) }
                    }
                    DatePicker("", selection: $customTime, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                        .onChange(of: customTime) {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: customTime)
                            bulk.toggleTime(LocalTime(c.hour ?? 9, c.minute ?? 0))
                        }
                        .help("Add another time")
                }
            }
            HStack {
                Text("Starts").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                DatePicker("", selection: $startDate, displayedComponents: .date).labelsHidden().fixedSize()
                    .onChange(of: startDate) { bulk.rule.start = LocalDay(startDate, in: .current) }
                Spacer()
            }
            Toggle(isOn: Binding(get: { bulk.skipWeekends }, set: { bulk.skipWeekends = $0 })) {
                HStack {
                    Text("Skip").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                    Text("Weekends").font(DS.body)
                }
            }
            .toggleStyle(SFToggleStyle())
            HStack {
                Text("Zone").font(DS.body).foregroundStyle(DS.text2).frame(width: 52, alignment: .leading)
                Picker("", selection: $bulk.rule.timeZoneID) {
                    ForEach(BulkPipelinePanel.zones, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                Spacer()
            }
            Text("Times stay at the same local time across daylight saving changes.").font(DS.caption).foregroundStyle(DS.text3)
        }
    }

    private var optimize: some View {
        @Bindable var bulk = model.bulk
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Optimize")
            Picker("Image", selection: $bulk.presetID) {
                Text("Original image").tag(String?.none)
                ForEach(ExportPreset.builtIn.filter { $0.platform == "pinterest" }) { Text($0.name).tag(String?.some($0.id)) }
            }
            .pickerStyle(.menu)
            if let id = bulk.presetID, let preset = ExportPreset.builtIn.first(where: { $0.id == id }) {
                let missing = runAssets.filter { a in !model.variants(of: a.uuid).contains { $0.presetID == id } }
                HStack {
                    Text("\(runAssets.count - missing.count) of \(runAssets.count) ready").font(DS.small).foregroundStyle(DS.text2)
                    Spacer()
                    Button("Make \(missing.count) Variants") { Task { _ = await model.makeVariants(missing, preset: preset) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(missing.isEmpty || model.variantProgress != nil)
                }
            }
        }
    }

    private var approval: some View {
        let total = max(1, queue.count)
        let ok = approved.count
        let waiting = queue.filter { $0.status == .needsReview }.count
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionLabel("Approval")
            Text("You review every post before anything publishes.").font(DS.body)
            ThinProgress(segments: [(Double(ok) / Double(total), DS.green), (Double(waiting) / Double(total), DS.amber)])
            HStack {
                Text("\(ok) approved").font(DS.small).foregroundStyle(DS.text2)
                Spacer()
                Text("\(waiting) waiting on you").font(DS.small).foregroundStyle(DS.text2)
            }
            if waiting > 0 {
                Button("Approve All Without Problems") {
                    for p in queue where p.status == .needsReview && !p.hasErrors(model: model) { p.status = .approved }
                    try? model.context.save()
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
        }
    }

    private var footer: some View {
        let preview = queue.isEmpty ? bulk.preview(runAssets) : []
        let dates = queue.isEmpty ? preview.compactMap(\.when) : queue.map(\.scheduledAt)
        let f = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        return VStack(alignment: .leading, spacing: Space.md) {
            Text(dates.isEmpty ? "No posts yet" : "\(dates.count) posts · \(dates.min()!.formatted(f)) → \(dates.max()!.formatted(f))")
                .font(DS.small).foregroundStyle(DS.text2)
            HStack(spacing: Space.sm) {
                Button("Save draft") { saveDraft() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(runAssets.isEmpty)
                    .help("Create the posts for review. Nothing publishes yet.")
                Button(approved.isEmpty ? "Schedule posts" : "Schedule \(approved.count) posts") { confirmSchedule = true }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    .disabled(approved.isEmpty || !model.canActivate)
                    .help(approved.isEmpty ? "Approve posts first" : "Publish approved posts at their times")
            }
        }
        .padding(Space.xl)
    }

    private func saveDraft() {
        let acct = model.accounts.first { $0.serverID == bulk.accountID }
        let board = model.boards[bulk.accountID ?? ""]?.first { $0.id == bulk.boardID }
        do {
            let made = try bulk.createPosts(model: model, assets: runAssets, account: acct, board: board)
            if !made.isEmpty { bulk.assetIDs = [] }
        } catch {
            model.lastError = "Could not build the schedule: \(error)"
        }
    }

    private func syncDates() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: bulk.rule.timeZoneID) ?? .current
        let r = bulk.rule.start
        startDate = cal.date(from: DateComponents(year: r.year, month: r.month, day: r.day, hour: 12)) ?? startDate
    }

    static var zones: [String] {
        var z = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Europe/London", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney", "UTC"]
        if !z.contains(TimeZone.current.identifier) { z.insert(TimeZone.current.identifier, at: 0) }
        return z
    }
}

/// CSV column mapping: the design's "filename → Image ✓" list plus pickers.
struct CSVMappingPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var bulk = model.bulk
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel(bulk.csvName.map { "CSV mapping · \($0)" } ?? "CSV mapping")
            if let table = bulk.table {
                PillPicker(options: MatchStrategy.allCases, selection: $bulk.strategy) {
                    switch $0 { case .filename: "Filename / SKU"; case .assetID: "Asset ID"; case .rowOrder: "Row order" }
                }
                if bulk.strategy == .rowOrder {
                    Text("Row 1 goes with image 1 in the order shown. Use only after checking the order.").font(DS.small).foregroundStyle(DS.amber)
                }
                mapRow("Image", table.header, $bulk.mapping.file)
                mapRow("SKU", table.header, $bulk.mapping.sku)
                if bulk.strategy == .assetID { mapRow("Asset ID", table.header, $bulk.mapping.assetID) }
                mapRow("Destination link", table.header, $bulk.mapping.url)
                mapRow("Pin title", table.header, $bulk.mapping.title)
                mapRow("Description", table.header, $bulk.mapping.description)
                mapRow("Alt text", table.header, $bulk.mapping.altText)
                if let row = table.rows.first {
                    SectionLabel("Sample row")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(zip(table.header, row).prefix(6)), id: \.0) { h, v in
                            Text("\(h): \(v)").font(DS.mono).foregroundStyle(DS.textBody).lineLimit(1)
                        }
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                }
            } else {
                Text("No CSV. Drop one with your images, or choose one from the Images menu.").font(DS.body).foregroundStyle(DS.text2)
            }
        }
    }

    private func mapRow(_ field: String, _ header: [String], _ binding: Binding<String?>) -> some View {
        HStack(spacing: Space.sm) {
            Menu {
                Button("None") { binding.wrappedValue = nil }
                ForEach(header, id: \.self) { h in Button(h) { binding.wrappedValue = h } }
            } label: {
                Text(binding.wrappedValue ?? "—").font(DS.mono).foregroundStyle(DS.textBody)
                    .padding(.horizontal, Space.sm).padding(.vertical, 2)
                    .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(DS.text3)
            Text(field).font(DS.body)
            Spacer()
            if binding.wrappedValue != nil { Image(systemName: "checkmark").foregroundStyle(DS.green) }
        }
        .padding(.vertical, 2)
    }
}

/// A month of day cells to pick posting dates.
struct MiniMonthPicker: View {
    let start: LocalDay
    let selected: Set<LocalDay>
    let toggle: (LocalDay) -> Void
    @State private var offset = 0

    var body: some View {
        let cal = Calendar.current
        let base = cal.date(from: DateComponents(year: start.year, month: start.month, day: 1)).flatMap { cal.date(byAdding: .month, value: offset, to: $0) } ?? .now
        let first = cal.dateInterval(of: .weekOfYear, for: base)?.start ?? base
        VStack(spacing: Space.xs) {
            HStack {
                Text(base.formatted(.dateTime.month(.wide).year())).font(DS.bodyMedium)
                Spacer()
                Button("Previous", systemImage: "chevron.left") { offset -= 1 }.labelStyle(.iconOnly).buttonStyle(.plain)
                Button("Next", systemImage: "chevron.right") { offset += 1 }.labelStyle(.iconOnly).buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<42, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: first)!
                    let ld = LocalDay(d, in: .current)
                    let inMonth = cal.isDate(d, equalTo: base, toGranularity: .month)
                    Button { toggle(ld) } label: {
                        Text("\(cal.component(.day, from: d))").font(DS.small)
                            .foregroundStyle(selected.contains(ld) ? DS.onAccent : inMonth ? DS.text : DS.text3)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(selected.contains(ld) ? DS.accentFill : DS.fill, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(ld < start)
                }
            }
            Text("\(selected.count) dates picked").font(DS.small).foregroundStyle(DS.text2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

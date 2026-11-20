import SwiftData
import SwiftUI
import SocialForgeKit

struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Publication.scheduledAt) private var allPubs: [Publication]
    @Query(sort: \Campaign.name) private var allCampaigns: [Campaign]
    @State private var mode: Mode = .month
    @State private var anchor: Date = .now
    @State private var platformFilter: String?
    @State private var statusFilter: PublicationStatus?
    @State private var campaignFilter: UUID?
    @State private var didJump = false

    enum Mode: String, CaseIterable { case month = "Month", week = "Week", day = "Day", queue = "Queue" }

    private var cal: Calendar { Calendar.current }
    private var mine: [Publication] { allPubs.filter { $0.workspaceID == model.workspaceID && $0.status != .canceled } }
    private var pubs: [Publication] {
        mine.filter { p in
            (platformFilter == nil || p.platform == platformFilter)
                && (statusFilter == nil || p.status == statusFilter)
                && (campaignFilter == nil || p.campaignID == campaignFilter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            AutomationBar()
            header
            switch mode {
            case .month: month
            case .week: week
            case .day: day
            case .queue: queue
            }
        }
        .padding(Space.xxl)
        .onAppear {
            guard !didJump else { return }
            didJump = true
            if let selected = mine.first(where: { model.publicationSelection.contains($0.id) }) { anchor = selected.scheduledAt }
            else if let next = mine.first(where: { $0.scheduledAt >= .now }) ?? mine.last { anchor = next.scheduledAt }
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(titleMain).font(DS.display(30)).foregroundStyle(DS.text)
                Text(titleYear).font(DS.display(30)).foregroundStyle(DS.text3)
            }
            Button("Previous", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
            Button("Next", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly).buttonStyle(IconButtonStyle())
            Button("Today") { anchor = .now }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            ForEach(["pinterest", "instagram", "facebook", "threads", "x", "linkedin"], id: \.self) { p in
                let n = mine.filter { $0.platform == p }.count
                if n > 0 || p == "pinterest" {
                    Button { platformFilter = platformFilter == p ? nil : p } label: {
                        HStack(spacing: 8) { PlatformBadge(platform: p, size: 18); Text("\(n)").font(DS.small).monospacedDigit() }
                            .padding(.horizontal, Space.sm).frame(height: 28)
                            .background(platformFilter == p ? DS.fillSelected : DS.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain).help("Show only \(PlatformRegistry.spec(p)?.name ?? p)")
                }
            }
            Menu {
                Picker("Status", selection: $statusFilter) {
                    Text("All statuses").tag(PublicationStatus?.none)
                    ForEach(PublicationStatus.allCases, id: \.self) { Text($0.title).tag(PublicationStatus?.some($0)) }
                }
                Picker("Campaign", selection: $campaignFilter) {
                    Text("All campaigns").tag(UUID?.none)
                    ForEach(allCampaigns.filter { $0.workspaceID == model.workspaceID }) { Text($0.name).tag(UUID?.some($0.uuid)) }
                }
            } label: { Image(systemName: statusFilter == nil && campaignFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
            .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize().help("Filter by status or campaign")
            PillPicker(options: Mode.allCases, selection: $mode) { $0.rawValue }
        }
    }

    private var titleMain: String {
        switch mode {
        case .month: anchor.formatted(.dateTime.month(.wide))
        case .week: "Week of " + startOfWeek(anchor).formatted(.dateTime.month(.abbreviated).day())
        case .day: anchor.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .queue: "Queue"
        }
    }
    private var titleYear: String { mode == .queue ? "\(pubs.count)" : anchor.formatted(.dateTime.year()) }

    private func step(_ n: Int) {
        let unit: Calendar.Component = switch mode { case .week: .weekOfYear; case .day: .day; default: .month }
        anchor = cal.date(byAdding: unit, value: n, to: anchor) ?? anchor
    }

    private func startOfWeek(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
    private func posts(on day: Date) -> [Publication] { pubs.filter { cal.isDate($0.scheduledAt, inSameDayAs: day) } }

    // MARK: Month

    private var monthDays: [Date] {
        guard let month = cal.dateInterval(of: .month, for: anchor) else { return [] }
        let first = startOfWeek(month.start)
        let weeks = Int(ceil((month.end.timeIntervalSince(first) / 86_400) / 7))
        return (0..<(weeks * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }

    private var month: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.shortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7].uppercased())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, Space.xs)
                }
            }
            GeometryReader { geo in
                let days = monthDays
                let rows = max(1, days.count / 7)
                let h = (geo.size.height - CGFloat(rows - 1) * Space.sm) / CGFloat(rows)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 7), spacing: Space.sm) {
                    ForEach(days, id: \.self) { d in
                        DayTile(day: d, posts: posts(on: d), inMonth: cal.isDate(d, equalTo: anchor, toGranularity: .month))
                            .frame(height: max(80, h))
                    }
                }
            }
        }
    }

    // MARK: Week and day

    private var week: some View {
        let start = startOfWeek(anchor)
        return HStack(alignment: .top, spacing: Space.sm) {
            ForEach(0..<7, id: \.self) { i in
                let d = cal.date(byAdding: .day, value: i, to: start)!
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated).day())).font(DS.bodyMedium)
                        .foregroundStyle(cal.isDateInToday(d) ? DS.accent : DS.text)
                    ScrollView {
                        VStack(spacing: Space.sm) { ForEach(posts(on: d)) { p in PostCard(pub: p, height: 152) } }
                    }
                }
                .padding(Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { CalendarCompose.open(on: d, model: model) }
                .help("Double-click to schedule a post on this day")
                .dropDestination(for: String.self) { ids, _ in CalendarDrop.move(ids, to: d, model: model) }
            }
        }
    }

    private var day: some View {
        let list = posts(on: anchor)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                if list.isEmpty { Text("Nothing scheduled this day.").foregroundStyle(DS.text2) }
                ForEach(list) { p in
                    HStack(alignment: .top, spacing: Space.lg) {
                        Text(p.scheduledAt.formatted(date: .omitted, time: .shortened)).font(DS.bodyMedium).frame(width: 80, alignment: .leading)
                        PostCard(pub: p, height: 220).frame(width: 160)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(p.title).font(DS.bodyMedium)
                            Text(p.desc).font(DS.body).foregroundStyle(DS.text2).lineLimit(4)
                            Text(p.link).font(DS.small).foregroundStyle(DS.text3).lineLimit(1)
                        }
                    }
                    .card()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CalendarCompose.open(on: anchor, model: model) }
        .help("Double-click to schedule a post on this day")
        .dropDestination(for: String.self) { ids, _ in CalendarDrop.move(ids, to: anchor, model: model) }
    }

    // MARK: Queue

    private var queue: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pubs) { p in
                    QueueRow(thumb: model.asset(p.assetID)?.storedPath, title: p.title, link: p.link, when: p.scheduledAt, platforms: [p.platform],
                             status: p.status, issues: p.status.isLocal ? p.issues(model: model).filter { $0.level == .error }.count : 0,
                             selected: model.publicationSelection.contains(p.id))
                        .contentShape(Rectangle())
                        .onTapGesture { CalendarSelect.click(p, model: model) }
                        .contextMenu { PublicationMenu(ids: model.publicationSelection.contains(p.id) ? model.publicationSelection : [p.id]) }
                        .draggable(p.uuid.uuidString)
                    Divider().overlay(DS.stroke)
                }
            }
        }
    }
}

/// Double-click a day: a new post in the Composer, set for that day.
enum CalendarCompose {
    /// Returns false (and beeps) for a day that has no time left to schedule.
    @MainActor
    @discardableResult
    static func open(on day: Date, model: AppModel) -> Bool {
        guard let time = CalendarSlot.defaultTime(on: day) else { NSSound.beep(); return false }
        model.composer.startNew(model: model, at: time)
        model.page = .composer
        return true
    }
}

enum CalendarSelect {
    @MainActor
    static func click(_ p: Publication, model: AppModel) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.publicationSelection.contains(p.id) { model.publicationSelection.remove(p.id) } else { model.publicationSelection.insert(p.id) }
        } else {
            model.publicationSelection = [p.id]
        }
    }
}

/// One day in the month grid: the first post as a picture tile, more as a count.
struct DayTile: View {
    let day: Date
    let posts: [Publication]
    let inMonth: Bool
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    private var cal: Calendar { Calendar.current }

    var body: some View {
        let selected = posts.contains { model.publicationSelection.contains($0.id) }
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: cal.isDateInToday(day) ? .bold : .medium))
                    .foregroundStyle(selected || cal.isDateInToday(day) ? DS.accent : inMonth ? DS.text : DS.text3)
                Spacer()
                if posts.count > 1 { Text("+\(posts.count - 1)").font(DS.caption).foregroundStyle(DS.text2) }
            }
            if let p = posts.first {
                GeometryReader { g in PostCard(pub: p, height: g.size.height).frame(width: g.size.width) }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(inMonth ? DS.fill : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted || selected ? DS.accentFill : DS.stroke, lineWidth: targeted || selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CalendarCompose.open(on: day, model: model) }
        .help("Double-click to schedule a post on this day")
        .dropDestination(for: String.self) { ids, _ in CalendarDrop.move(ids, to: day, model: model) } isTargeted: { targeted = $0 }
        .contextMenu { if !posts.isEmpty { PublicationMenu(ids: Set(posts.map(\.id))) } }
    }
}

/// The design's post tile: image, platform badges and time at the bottom, a status dot at the top.
struct PostCard: View {
    let pub: Publication
    var height: CGFloat?
    @Environment(AppModel.self) private var model

    var body: some View {
        Thumbnail(path: model.asset(pub.assetID)?.storedPath, maxPixel: 360)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Circle().fill(pub.status.color).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)).padding(Space.sm)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    PlatformBadge(platform: pub.platform, size: 14)
                    Text(pub.scheduledAt.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(Space.xs)
            }
            .overlay {
                if pub.assetID != nil, model.asset(pub.assetID) == nil {
                    Label("Missing media", systemImage: "photo.badge.exclamationmark").font(DS.caption).foregroundStyle(DS.red)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { CalendarSelect.click(pub, model: model) }
            .draggable(pub.uuid.uuidString) { Text(pub.title).padding(Space.xs) }
            .help("\(pub.title) · \(pub.status.title)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pub.title), \(pub.status.title), \(pub.scheduledAt.formatted())")
    }
}

enum CalendarDrop {
    /// Drag a post onto another day: same time of day, new date. Only posts not yet live.
    @MainActor
    @discardableResult
    static func move(_ ids: [String], to day: Date, model: AppModel) -> Bool {
        let all = (try? model.context.fetch(FetchDescriptor<Publication>())) ?? []
        var moved = false
        for id in ids {
            guard let uuid = UUID(uuidString: id), let p = all.first(where: { $0.uuid == uuid }), p.status.isLocal || p.status == .paused else { continue }
            var tz = Calendar(identifier: .gregorian)
            tz.timeZone = TimeZone(identifier: p.timeZoneID) ?? .current
            let t = tz.dateComponents([.hour, .minute], from: p.scheduledAt)
            let d = Calendar.current.dateComponents([.year, .month, .day], from: day)
            if let new = tz.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: t.hour, minute: t.minute)) {
                p.scheduledAt = new
                p.updatedAt = .now
                moved = true
            }
        }
        try? model.context.save()
        return moved
    }
}

/// Context menu actions for one or more posts.
struct PublicationMenu: View {
    let ids: Set<PersistentIdentifier>
    @Environment(AppModel.self) private var model

    private var pubs: [Publication] {
        ((try? model.context.fetch(FetchDescriptor<Publication>())) ?? []).filter { ids.contains($0.id) }
    }

    var body: some View {
        Button("Approve") { for p in pubs where p.status == .needsReview && !p.hasErrors(model: model) { p.status = .approved }; save() }
        Button("Send Back to Review") { for p in pubs where p.status == .approved || p.status == .draft { p.status = .needsReview }; save() }
        Button("Pause") { for p in pubs where p.status.isLocal || (p.status == .scheduled && p.serverID == nil) { p.status = .paused }; save() }
        Button("Resume") { for p in pubs where p.status == .paused { p.status = .needsReview }; save() }
        Button("Duplicate") {
            for p in pubs {
                let c = Publication(workspaceID: p.workspaceID, scheduledAt: p.scheduledAt.addingTimeInterval(86_400), timeZoneID: p.timeZoneID)
                c.assetID = p.assetID; c.variantID = p.variantID; c.platform = p.platform; c.accountID = p.accountID; c.accountName = p.accountName
                c.boardID = p.boardID; c.boardName = p.boardName; c.title = p.title; c.desc = p.desc; c.link = p.link; c.altText = p.altText
                c.runName = p.runName; c.campaignID = p.campaignID; c.status = .needsReview
                model.context.insert(c)
            }
            save()
        }
        Divider()
        Button("Cancel Scheduled") {
            Task { for p in pubs where p.status == .scheduled { await model.cancelOnServer(p) } }
        }
        .disabled(!pubs.contains { $0.status == .scheduled })
        Button("Remove", role: .destructive) {
            for p in pubs where p.status.isLocal || p.status == .paused || p.status == .canceled || p.status == .failed { model.context.delete(p) }
            model.publicationSelection.subtract(ids)
            save()
        }
    }

    private func save() { try? model.context.save() }
}

// MARK: - Post inspector

struct PublicationInspector: View {
    @Environment(AppModel.self) private var model
    @Query private var allPubs: [Publication]

    private var selected: [Publication] { allPubs.filter { model.publicationSelection.contains($0.id) } }

    var body: some View {
        if selected.count == 1, let p = selected.first {
            SinglePostEditor(pub: p)
        } else if selected.count > 1 {
            MultiPostEditor(pubs: selected)
        } else {
            VStack(spacing: 0) {
                PanelHeader(title: "Post")
                Divider().overlay(DS.stroke)
                EmptyState(symbol: "calendar", title: "No post selected", message: "Click a post to preview it and edit its copy, link, and time. Command-click to edit several at once. Double-click a day to schedule a new post.")
            }
        }
    }
}

struct SinglePostEditor: View {
    @Bindable var pub: Publication
    @Environment(AppModel.self) private var model
    @State private var suggestions: [String] = []
    @State private var suggesting = false
    @State private var suggestError: String?

    var body: some View {
        let locked = !(pub.status.isLocal || pub.status == .paused)
        let issues = pub.issues(model: model)
        VStack(spacing: 0) {
            PanelHeader(title: "Post") { Text(pub.scheduledAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · " + pub.scheduledAt.formatted(date: .omitted, time: .shortened)) }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                PinPreview(pub: pub)
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Post")
                    field("Title", count: pub.title.count, max: 100) {
                        TextField("Title", text: $pub.title, axis: .vertical).lineLimit(1...3).fieldStyle()
                    }
                    field("Description", count: pub.desc.count, max: 800) {
                        TextField("Description", text: $pub.desc, axis: .vertical).lineLimit(3...8).fieldStyle()
                    }
                    field("Destination link", count: nil, max: nil) {
                        TextField("https://", text: $pub.link).fieldStyle()
                    }
                    field("Alt text", count: pub.altText.count, max: 500) {
                        TextField("What the image shows", text: $pub.altText, axis: .vertical).lineLimit(1...3).fieldStyle()
                    }
                }
                .disabled(locked)
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Schedule").padding(.bottom, Space.xs)
                    KeyValueRow("Board", pub.boardName.isEmpty ? "None" : pub.boardName)
                    KeyValueRow(key: "Publish") {
                        DatePicker("", selection: $pub.scheduledAt).labelsHidden().disabled(locked)
                    }
                    KeyValueRow("Queue", pub.runName.isEmpty ? "—" : pub.runName)
                    KeyValueRow(key: "Approval") { StatusChip(status: pub.status) }
                }
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("Checks")
                        ForEach(issues, id: \.self) { IssueRow(issue: $0) }
                    }
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("AI suggestions", trailing: AnyView(Image(systemName: "sparkles").foregroundStyle(DS.accent)))
                    if suggestions.isEmpty {
                        Button(suggesting ? "Writing…" : "Suggest titles") { Task { await suggest() } }
                            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                            .disabled(suggesting || locked || model.textProvider == nil)
                        if model.textProvider == nil {
                            Text("Add a text provider key in Settings > AI Providers.").font(DS.small).foregroundStyle(DS.text2)
                        }
                        if let suggestError { Text(suggestError).font(DS.small).foregroundStyle(DS.red) }
                    }
                    ForEach(suggestions, id: \.self) { s in
                        HStack(alignment: .top) {
                            Text(s).font(DS.body).foregroundStyle(DS.textBody)
                            Spacer()
                            Button("Use title") { pub.title = s }.buttonStyle(LinkButtonStyle()).disabled(locked)
                        }
                        .card(padding: Space.md)
                    }
                }
                if pub.status == .failed || pub.publishedURL != nil || pub.attempts > 0 {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionLabel("Result")
                        KeyValueRow("Attempts", "\(pub.attempts)")
                        if let next = pub.nextAttemptAt, pub.status == .scheduled { KeyValueRow("Next try", next.formatted(.dateTime.hour().minute())) }
                        if let e = pub.lastError { Text(e).font(DS.small).foregroundStyle(pub.status == .failed ? DS.red : DS.amber) }
                        if let url = pub.publishedURL, let u = URL(string: url) { Link("Open published post", destination: u).font(DS.bodyMedium) }
                        AttemptHistory(publicationID: pub.uuid)
                    }
                }
            }
            if pub.status == .needsReview || pub.status == .approved || pub.status == .draft {
                Divider().overlay(DS.stroke)
                HStack(spacing: Space.sm) {
                    if pub.status == .needsReview {
                        Button("Request changes") { pub.status = .draft }.buttonStyle(SecondaryButtonStyle(fullWidth: true))
                        Button("Approve") { pub.status = .approved; try? model.context.save() }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                            .disabled(issues.contains { $0.level == .error })
                    } else {
                        Button("Back to review") { pub.status = .needsReview }.buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    }
                }
                .padding(Space.xl)
            }
        }
        .onChange(of: pub.title) { pub.updatedAt = .now }
        .onChange(of: pub.uuid) { suggestions = []; suggestError = nil }
    }

    private func field<C: View>(_ label: String, count: Int?, max: Int?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(label).font(DS.small).foregroundStyle(DS.text2)
                Spacer()
                if let count, let max { Text("\(count) / \(max)").font(DS.caption).foregroundStyle(count > max ? DS.red : DS.text3).monospacedDigit() }
            }
            content()
        }
    }

    private func suggest() async {
        guard let provider = model.textProvider else { return }
        suggesting = true
        defer { suggesting = false }
        let asset = model.asset(pub.assetID)
        var titles: [String] = []
        for _ in 0..<3 {
            let req = CopyRequest(platform: pub.platform, productName: pub.title, filename: asset?.filename ?? "", link: pub.link,
                                  existingTitle: pub.title, existingDescription: pub.desc, extra: [:], brand: model.brandKit?.voiceForAI)
            do {
                let (copy, usage) = try await PostCopyGenerator.generate(req, provider: provider)
                model.recordAI(kind: "text", prompt: "Title ideas for \(pub.title)", usage: usage, ok: true)
                if !titles.contains(copy.title) { titles.append(copy.title) }
            } catch {
                suggestError = error.localizedDescription
                model.recordAI(kind: "text", prompt: "Title ideas for \(pub.title)", usage: nil, ok: false, detail: error.localizedDescription)
                break
            }
        }
        suggestions = titles
    }
}

/// The design's Pinterest-style preview: image, "Save", domain chip, title, brand.
struct PinPreview: View {
    let pub: Publication
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.sm) {
            Thumbnail(path: model.asset(pub.assetID)?.storedPath, maxPixel: 600)
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Text("Save").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, Space.md).frame(height: 28)
                        .background(Color(hex: 0xE60023), in: Capsule()).padding(Space.sm)
                }
                .overlay(alignment: .bottomLeading) {
                    if let host = URL(string: pub.link)?.host() {
                        Text(host.replacingOccurrences(of: "www.", with: "")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, Space.sm).frame(height: 24)
                            .background(.white.opacity(0.9), in: Capsule()).padding(Space.sm)
                    }
                }
            Text(pub.title.isEmpty ? "Untitled" : pub.title).font(DS.bodyMedium).multilineTextAlignment(.center).lineLimit(2)
            HStack(spacing: Space.xs) {
                PlatformBadge(platform: pub.platform, size: 16)
                Text(pub.accountName.isEmpty ? "No account" : pub.accountName).font(DS.small).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct MultiPostEditor: View {
    let pubs: [Publication]
    @Environment(AppModel.self) private var model
    @State private var description = ""
    @State private var altText = ""
    @State private var link = ""
    @State private var shiftDays = 0

    var body: some View {
        let editable = pubs.filter { $0.status.isLocal || $0.status == .paused }
        VStack(spacing: 0) {
            PanelHeader(title: "\(pubs.count) posts") { Text("\(editable.count) editable") }
            Divider().overlay(DS.stroke)
            InspectorScroll {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionLabel("Change all")
                    Text("Fields left empty stay as they are.").font(DS.small).foregroundStyle(DS.text2)
                    TextField("Description for all", text: $description, axis: .vertical).lineLimit(2...6).fieldStyle()
                    TextField("Destination link for all", text: $link).fieldStyle()
                    TextField("Alt text for all", text: $altText).fieldStyle()
                    HStack {
                        Text("Move by \(shiftDays) day\(abs(shiftDays) == 1 ? "" : "s")").font(DS.body)
                        Spacer()
                        Stepper("", value: $shiftDays, in: -60...60).labelsHidden()
                    }
                    Button("Apply to \(editable.count) posts") {
                        for p in editable {
                            if !description.isEmpty { p.desc = description }
                            if !link.isEmpty { p.link = link }
                            if !altText.isEmpty { p.altText = altText }
                            if shiftDays != 0 { p.scheduledAt = Calendar.current.date(byAdding: .day, value: shiftDays, to: p.scheduledAt) ?? p.scheduledAt }
                            p.updatedAt = .now
                        }
                        try? model.context.save()
                        description = ""; altText = ""; link = ""; shiftDays = 0
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .disabled(editable.isEmpty)
                }
                let ok = pubs.filter { $0.status == .needsReview && !$0.hasErrors(model: model) }
                Button("Approve \(ok.count) without problems") { for p in ok { p.status = .approved }; try? model.context.save() }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    .disabled(ok.isEmpty)
            }
        }
    }
}

struct IssueRow: View {
    let issue: ValidationIssue
    var body: some View {
        Label {
            Text(issue.message).font(DS.small).foregroundStyle(DS.textBody)
        } icon: {
            Image(systemName: issue.level == .error ? "xmark.octagon.fill" : issue.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(issue.level == .error ? DS.red : issue.level == .warning ? DS.amber : DS.text2)
        }
    }
}

struct AttemptHistory: View {
    let publicationID: UUID
    @Query private var attempts: [PublishAttempt]

    init(publicationID: UUID) {
        self.publicationID = publicationID
        _attempts = Query(filter: #Predicate<PublishAttempt> { $0.publicationID == publicationID }, sort: \.attempt)
    }

    var body: some View {
        ForEach(attempts) { a in
            HStack(alignment: .firstTextBaseline) {
                Text("#\(a.attempt)").monospacedDigit().foregroundStyle(DS.text3)
                Text(a.outcome ?? "running")
                if let s = a.httpStatus { Text("HTTP \(s)").foregroundStyle(DS.text2) }
                Spacer()
                Text(a.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())).foregroundStyle(DS.text2)
            }
            .font(DS.small)
            .help(a.error ?? "")
        }
    }
}

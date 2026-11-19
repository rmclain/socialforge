import Foundation

/// The sidebar pages, in sidebar order. UI-free so tests can check that
/// every page has a title, a symbol, and a section.
public enum AppPage: String, CaseIterable, Identifiable, Sendable {
    case home, calendar, composer, media, studio, ai
    case bulk, automations, campaigns, analytics
    case accounts, brandKits, settings

    public var id: String { rawValue }

    public enum Section: String, CaseIterable, Sendable {
        case create = ""
        case publishing = "Publishing"
        case workspace = "Workspace"
    }

    public var section: Section {
        switch self {
        case .home, .calendar, .composer, .media, .studio, .ai: .create
        case .bulk, .automations, .campaigns, .analytics: .publishing
        case .accounts, .brandKits, .settings: .workspace
        }
    }

    public var title: String {
        switch self {
        case .home: "Dashboard"
        case .calendar: "Calendar"
        case .composer: "Composer"
        case .media: "Media Library"
        case .studio: "Creative Studio"
        case .ai: "AI Studio"
        case .bulk: "Bulk Publisher"
        case .automations: "Automations"
        case .campaigns: "Campaigns"
        case .analytics: "Analytics"
        case .accounts: "Accounts"
        case .brandKits: "Brand Kits"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .calendar: "calendar"
        case .composer: "square.and.pencil"
        case .media: "photo.on.rectangle"
        case .studio: "paintbrush.pointed"
        case .ai: "sparkles"
        case .bulk: "square.stack.3d.up"
        case .automations: "bolt"
        case .campaigns: "flag"
        case .analytics: "chart.bar"
        case .accounts: "person.2"
        case .brandKits: "swatchpalette"
        case .settings: "gearshape"
        }
    }
}

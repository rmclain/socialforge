import Foundation
import SwiftData
import SocialForgeKit

// Every record carries the id of the workspace it belongs to, so a workspace
// is a clean boundary: switching shows only its media, posts, and kits.

@Model
final class Workspace {
    var uuid: UUID = UUID()
    var name: String
    var colorHex: Int = 0xFF8A5C
    var voice: String = ""
    var createdAt: Date = Date.now

    init(name: String, colorHex: Int = 0xFF8A5C) {
        self.name = name
        self.colorHex = colorHex
    }

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

@Model
final class MediaAsset {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var filename: String
    /// The copy in managed storage. The source file is never written to.
    var storedPath: String
    var sourcePath: String
    var sha256: String
    var bytes: Int
    var width: Int = 0
    var height: Int = 0
    var format: String = ""
    var kind: String = "image"
    var hasAlpha: Bool = false
    var importedAt: Date = Date.now
    var tags: [String] = []
    var isFavorite: Bool = false
    var title: String = ""
    var altText: String = ""
    var productURL: String = ""
    var notes: String = ""
    /// A named group of media, like "Winter Collection".
    var collection: String = ""
    var campaignID: UUID?

    init(workspaceID: UUID, filename: String, storedPath: String, sourcePath: String, sha256: String, bytes: Int) {
        self.workspaceID = workspaceID
        self.filename = filename
        self.storedPath = storedPath
        self.sourcePath = sourcePath
        self.sha256 = sha256
        self.bytes = bytes
    }

    var storedURL: URL { URL(fileURLWithPath: storedPath) }
    var dimensions: String { width > 0 ? "\(width) × \(height)" : "—" }
    var imageFacts: ImageFacts { ImageFacts(width: width, height: height, bytes: bytes, format: format) }
}

/// A derived file made from an asset by an export preset. Originals stay as they were.
@Model
final class MediaVariant {
    var uuid: UUID = UUID()
    var assetID: UUID
    var presetID: String
    var presetName: String
    var path: String
    var width: Int
    var height: Int
    var bytes: Int
    var format: String
    var createdAt: Date = Date.now

    init(assetID: UUID, preset: ExportPreset, result: TransformResult) {
        self.assetID = assetID
        self.presetID = preset.id
        self.presetName = preset.name
        self.path = result.url.path
        self.width = result.width
        self.height = result.height
        self.bytes = result.bytes
        self.format = preset.format.rawValue
    }

    var url: URL { URL(fileURLWithPath: path) }
    var imageFacts: ImageFacts { ImageFacts(width: width, height: height, bytes: bytes, format: format) }
}

/// The lifecycle of one platform post.
enum PublicationStatus: String, CaseIterable, Codable {
    case draft, needsReview, approved, scheduled, preparing, publishing, published, failed, paused, canceled

    var title: String {
        switch self {
        case .draft: "Draft"
        case .needsReview: "Needs Review"
        case .approved: "Approved"
        case .scheduled: "Scheduled"
        case .preparing: "Preparing"
        case .publishing: "Publishing"
        case .published: "Published"
        case .failed: "Failed"
        case .paused: "Paused"
        case .canceled: "Canceled"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "doc"
        case .needsReview: "eye"
        case .approved: "checkmark.circle"
        case .scheduled: "clock"
        case .preparing, .publishing: "arrow.up.circle"
        case .published: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .canceled: "xmark.circle"
        }
    }

    /// Editable in the app. Once the service has it, changes go through the service.
    var isLocal: Bool { [.draft, .needsReview, .approved].contains(self) }

    /// The server's status names.
    init(server: String) {
        self = PublicationStatus(rawValue: server) ?? (server == "queued" ? .scheduled : .failed)
    }
}

/// One post for one platform and account: the definition. Attempts live on the server.
@Model
final class Publication {
    /// Also the clientId the server stores, so sync can match rows.
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var assetID: UUID?
    var variantID: UUID?
    var platform: String = "pinterest"
    var accountID: String = ""
    var accountName: String = ""
    var boardID: String = ""
    var boardName: String = ""
    var title: String = ""
    var desc: String = ""
    var link: String = ""
    var altText: String = ""
    var scheduledAt: Date
    var timeZoneID: String
    var statusRaw: String = PublicationStatus.needsReview.rawValue
    var serverID: String?
    var providerPostID: String?
    /// When a retry is due (on-Mac publishing). Nil means "as scheduled".
    var nextAttemptAt: Date?
    var firstTriedAt: Date?
    var publishedURL: String?
    var lastError: String?
    var attempts: Int = 0
    var runName: String = ""
    var campaignID: UUID?
    /// The canonical post this platform version belongs to (Composer).
    var contentItemID: UUID?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(workspaceID: UUID, scheduledAt: Date, timeZoneID: String) {
        self.workspaceID = workspaceID
        self.scheduledAt = scheduledAt
        self.timeZoneID = timeZoneID
    }

    var status: PublicationStatus {
        get { PublicationStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue; updatedAt = .now }
    }

    /// Stable per post: a resubmission after a timeout creates no second post.
    var idempotencyKey: String { "sf-\(uuid.uuidString.lowercased())" }
}

/// A connected account, as last reported by the publishing service.
@Model
final class SocialAccount {
    var serverID: String
    var workspaceID: UUID
    var platform: String
    var name: String
    var handle: String = ""
    var status: String
    var scopes: [String] = []
    var tokenExpiresAt: Date?
    var lastPublishedAt: Date?
    var isMock: Bool = false
    /// "mac" for accounts this Mac connected itself (tokens in the Keychain), "service" for the optional publishing service.
    var source: String = "service"
    var refreshedAt: Date = Date.now

    init(serverID: String, workspaceID: UUID, platform: String, name: String, status: String) {
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.platform = platform
        self.name = name
        self.status = status
    }

    /// Keychain item that holds this account's access token (on-Mac accounts only).
    var tokenKey: String { "token.\(serverID)" }

    var capabilities: [AccountCapability] {
        Capabilities.forAccount(platform: platform, grantedScopes: Set(scopes), status: status)
    }
}

@Model
final class BrandKit {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var name: String
    var colors: [Int] = []
    var headlineFont: String = "Baskerville"
    var bodyFont: String = "Helvetica Neue"
    var voice: String = ""
    var audience: String = ""
    var ctas: [String] = []
    var hashtags: [String] = []
    var avoid: String = ""
    /// Logo file in the library (PNG with transparency works best).
    var logoPath: String = ""
    var imageStyle: String = ""

    init(workspaceID: UUID, name: String) {
        self.workspaceID = workspaceID
        self.name = name
    }

    var style: BrandStyle {
        BrandStyle(palette: colors.map { RGBA(hex: UInt32($0)) }, headlineFont: headlineFont, bodyFont: bodyFont,
                   logoPath: logoPath.isEmpty ? nil : logoPath)
    }

    var voiceForAI: BrandVoice {
        BrandVoice(name: name, voice: voice, audience: audience, avoid: avoid, ctas: ctas, hashtags: hashtags)
    }
}

/// A reusable design whose text, colors, fonts, logo, and photo are slots and
/// brand roles. Editing it in Creative Studio and saving updates it in place.
@Model
final class CreativeTemplate {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var name: String
    var category: String = "Pinterest"
    var json: Data
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(workspaceID: UUID, document: CreativeDocument, category: String = "Pinterest") {
        self.workspaceID = workspaceID
        self.name = document.name
        self.category = category
        self.json = (try? document.json()) ?? Data()
    }

    var document: CreativeDocument? { try? CreativeDocument.from(json: json) }
}

/// A campaign: goal, dates, accounts, UTM tags, and the posts and media in it.
@Model
final class Campaign {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var name: String
    var goal: String = ""
    var kind: String = "Product launch"
    var startDate: Date = Date.now
    var endDate: Date = Date.now.addingTimeInterval(30 * 86_400)
    var utmSource: String = "pinterest"
    var utmMedium: String = "social"
    var utmCampaign: String = ""
    var notes: String = ""
    var templateID: UUID?
    var createdAt: Date = Date.now

    init(workspaceID: UUID, name: String) {
        self.workspaceID = workspaceID
        self.name = name
        self.utmCampaign = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// The canonical post from the Composer. Each platform version is a Publication.
@Model
final class ContentItem {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var title: String = ""
    var body: String = ""
    var link: String = ""
    var altText: String = ""
    var hashtags: [String] = []
    var assetID: UUID?
    var campaignID: UUID?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(workspaceID: UUID) { self.workspaceID = workspaceID }
}

/// One AI request: copy, an image batch, or a command plan. Kept for history and token usage.
@Model
final class AIJob {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var provider: String
    var kind: String
    var prompt: String
    var status: String = "running"
    var detail: String = ""
    var outputAssetIDs: [UUID] = []
    var seed: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var progress: Double = 0
    var createdAt: Date = Date.now
    var finishedAt: Date?

    init(workspaceID: UUID, provider: String, kind: String, prompt: String) {
        self.workspaceID = workspaceID
        self.provider = provider
        self.kind = kind
        self.prompt = prompt
    }
}

/// An imported ComfyUI workflow (API format) and its parameter mapping.
@Model
final class ComfyWorkflowRecord {
    var uuid: UUID = UUID()
    var name: String
    var json: Data
    var isDefault: Bool = false
    var createdAt: Date = Date.now

    init(name: String, json: Data) {
        self.name = name
        self.json = json
    }
}

/// A saved automation: a trigger and a chain of steps that ends in posts waiting for approval.
@Model
final class Automation {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var name: String
    var isEnabled: Bool = false
    /// folder, manual, weekly
    var trigger: String = "folder"
    var folderPath: String = ""
    var weekday: Int = 2
    var hour: Int = 9
    var presetID: String = ""
    var templateID: UUID?
    var generateCopy: Bool = false
    var accountID: String = ""
    var boardID: String = ""
    var boardName: String = ""
    var everyDays: Int = 1
    var postHour: Int = 9
    var postMinute: Int = 0
    var tag: String = ""
    var lastRunAt: Date?
    var createdAt: Date = Date.now

    init(workspaceID: UUID, name: String) {
        self.workspaceID = workspaceID
        self.name = name
    }
}

@Model
final class AutomationRun {
    var uuid: UUID = UUID()
    var automationID: UUID
    var startedAt: Date = Date.now
    var finishedAt: Date?
    var dryRun: Bool = false
    var outcome: String = "running"
    var log: [String] = []

    init(automationID: UUID, dryRun: Bool) {
        self.automationID = automationID
        self.dryRun = dryRun
    }
}

/// A Creative Studio document. The layers live in `json` (CreativeDocument).
@Model
final class Design {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var name: String
    var json: Data
    var updatedAt: Date = Date.now

    init(workspaceID: UUID, document: CreativeDocument) {
        self.workspaceID = workspaceID
        self.name = document.name
        self.json = (try? document.json()) ?? Data()
    }

    var document: CreativeDocument? { try? CreativeDocument.from(json: json) }
}

/// One try at publishing a post from this Mac. Never overwritten, for auditing.
@Model
final class PublishAttempt {
    var publicationID: UUID
    var attempt: Int
    var startedAt: Date = Date.now
    var finishedAt: Date?
    /// success, reconciled, retryable, uncertain, auth, permanent
    var outcome: String?
    var httpStatus: Int?
    var requestID: String?
    var error: String?

    init(publicationID: UUID, attempt: Int) {
        self.publicationID = publicationID
        self.attempt = attempt
    }
}

/// What happened, for Home's activity list.
@Model
final class ActivityEntry {
    var workspaceID: UUID
    var text: String
    var symbol: String
    var at: Date = Date.now

    init(workspaceID: UUID, text: String, symbol: String) {
        self.workspaceID = workspaceID
        self.text = text
        self.symbol = symbol
    }
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Workspace.self, MediaAsset.self, MediaVariant.self, Publication.self,
        SocialAccount.self, BrandKit.self, Design.self, ActivityEntry.self, PublishAttempt.self,
        CreativeTemplate.self, Campaign.self, ContentItem.self, AIJob.self, ComfyWorkflowRecord.self, Automation.self, AutomationRun.self,
    ]
}

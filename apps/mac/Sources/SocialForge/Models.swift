import Foundation
import SwiftData
import SocialForgeKit

// Every record carries the id of the workspace it belongs to, so a workspace
// is a clean boundary: switching shows only its media, posts, and kits.
// All fields added after Schema v1 carry default values or are Optional so
// SwiftData performs automatic non-destructive lightweight migration for
// existing user libraries.

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
    var safeColorHex: UInt32 { UInt32(bitPattern: Int32(truncatingIfNeeded: colorHex)) & 0xFFFFFF }
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
    /// Seconds, for video and audio.
    var duration: Double = 0
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
    /// Structured provenance JSON for AI-generated or externally produced assets.
    var provenanceJSON: Data = Data()
    /// Soft-archive flag for recoverable removal before moving to Trash.
    var isArchived: Bool = false

    init(workspaceID: UUID, filename: String, storedPath: String, sourcePath: String, sha256: String, bytes: Int) {
        self.workspaceID = workspaceID
        self.filename = filename
        self.storedPath = storedPath
        self.sourcePath = sourcePath
        self.sha256 = sha256
        self.bytes = bytes
    }

    var storedURL: URL { URL(fileURLWithPath: storedPath) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: storedPath) }
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
    case draft
    case needsReview
    case approved
    case scheduled
    case preparing
    case uploading
    case awaitingProcessing
    case publishing
    case verifying
    case published
    case retryScheduled
    case authRequired
    case actionRequired
    case outcomeUnknown
    case failed
    case paused
    case canceled
    case manualRequired

    var title: String {
        switch self {
        case .draft: "Draft"
        case .needsReview: "Needs Review"
        case .approved: "Approved"
        case .scheduled: "Scheduled"
        case .preparing: "Preparing Media"
        case .uploading: "Uploading"
        case .awaitingProcessing: "Awaiting Processing"
        case .publishing: "Publishing"
        case .verifying: "Verifying"
        case .published: "Published"
        case .retryScheduled: "Retry Scheduled"
        case .authRequired: "Auth Required"
        case .actionRequired: "Action Required"
        case .outcomeUnknown: "Outcome Unknown"
        case .failed: "Failed"
        case .paused: "Paused"
        case .canceled: "Canceled"
        case .manualRequired: "Manual Publishing"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "doc"
        case .needsReview: "eye"
        case .approved: "checkmark.circle"
        case .scheduled: "clock"
        case .preparing, .uploading, .awaitingProcessing, .publishing, .verifying: "arrow.up.circle"
        case .published: "checkmark.seal.fill"
        case .retryScheduled: "arrow.clockwise.circle"
        case .authRequired: "key.slash"
        case .actionRequired: "exclamationmark.circle"
        case .outcomeUnknown: "questionmark.diamond.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        case .canceled: "xmark.circle"
        case .manualRequired: "hand.raised.circle"
        }
    }

    /// Editable in the app without external coordination.
    var isLocal: Bool { [.draft, .needsReview, .approved].contains(self) }

    /// Currently executing an external publish pipeline step.
    var isActivePublishing: Bool { [.preparing, .uploading, .awaitingProcessing, .publishing, .verifying].contains(self) }

    /// Queued for automatic publishing (first try or scheduled retry).
    var isQueuedForPublish: Bool { self == .scheduled || self == .retryScheduled }

    /// Requires user inspection or intervention.
    var needsAttention: Bool {
        [.needsReview, .failed, .authRequired, .actionRequired, .outcomeUnknown, .manualRequired].contains(self)
    }

    /// Maps backend server status strings to local PublicationStatus.
    init(server: String) {
        if let exact = PublicationStatus(rawValue: server) {
            self = exact
        } else if server == "queued" {
            self = .scheduled
        } else {
            self = .failed
        }
    }
}

/// Explicit publishing owner for each scheduled publication.
enum PublishOwner: String, CaseIterable, Codable {
    case mac = "mac"
    case service = "service"
    case manual = "manual"

    var label: String {
        switch self {
        case .mac: "This Mac"
        case .service: "Publishing Service"
        case .manual: "Manual Export"
        }
    }
}

/// Missed-post policy when a Mac wakes after a scheduled time passed.
enum MissedPostPolicy: String, CaseIterable, Codable, Identifiable {
    case publishWhenAvailable
    case skipForReview
    case rescheduleInWindow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .publishWhenAvailable: "Publish when available (mark late)"
        case .skipForReview: "Skip and return to Needs Review"
        case .rescheduleInWindow: "Reschedule to next valid slot"
        }
    }
}

/// One post for one platform and account.
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
    var boardSectionID: String = ""
    var title: String = ""
    var desc: String = ""
    var link: String = ""
    var altText: String = ""
    var scheduledAt: Date
    var timeZoneID: String
    var statusRaw: String = PublicationStatus.needsReview.rawValue
    /// Explicit persisted publishing owner: "mac", "service", or "manual".
    var publishOwnerRaw: String = PublishOwner.mac.rawValue
    var serverID: String?
    var providerPostID: String?
    /// Persisted remote upload/container ID so processing can resume after crash.
    var containerID: String?
    /// When a retry is due (on-Mac publishing). Nil means "as scheduled".
    var nextAttemptAt: Date?
    var firstTriedAt: Date?
    var publishedAt: Date?
    var publishedURL: String?
    var lastError: String?
    var attempts: Int = 0
    var runName: String = ""
    var campaignID: UUID?
    /// The canonical post this platform version belongs to (Composer).
    var contentItemID: UUID?
    /// Additional asset UUIDs for carousels / multi-photo posts.
    var extraAssetIDs: [UUID] = []
    /// Provider-specific disclosure/visibility metadata JSON (e.g. YouTube, TikTok).
    var metadataJSON: Data = Data()
    /// Inbound MCP request ID that created this post (prevents crash-recovery duplicates).
    var agentRequestID: String?
    /// Fingerprint of content/media/destination at approval time so edits invalidate approval.
    var approvedFingerprint: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(workspaceID: UUID, scheduledAt: Date, timeZoneID: String) {
        self.workspaceID = workspaceID
        self.scheduledAt = scheduledAt
        self.timeZoneID = timeZoneID
    }

    var status: PublicationStatus {
        get { PublicationStatus(rawValue: statusRaw) ?? .draft }
        set {
            statusRaw = newValue.rawValue
            if newValue == .approved { approvedFingerprint = contentFingerprint }
            updatedAt = .now
        }
    }

    var publishOwner: PublishOwner {
        get { PublishOwner(rawValue: publishOwnerRaw) ?? (serverID != nil ? .service : .mac) }
        set { publishOwnerRaw = newValue.rawValue; updatedAt = .now }
    }

    var metadata: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: metadataJSON)) ?? [:] }
        set { metadataJSON = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }

    /// Stable fingerprint of editable content/media/destination/disclosures.
    var contentFingerprint: String {
        let extras = extraAssetIDs.map(\.uuidString).joined(separator: ",")
        let meta = String(data: metadataJSON, encoding: .utf8) ?? ""
        return [platform, accountID, boardID, boardSectionID, title, desc, link, altText,
                assetID?.uuidString ?? "", variantID?.uuidString ?? "", extras, meta].joined(separator: "|")
    }

    /// Invalidates approval back to `.needsReview` if an approved post's content, media, destination, or disclosures changed.
    func invalidateApprovalIfChanged() {
        guard status == .approved, !approvedFingerprint.isEmpty, approvedFingerprint != contentFingerprint else { return }
        status = .needsReview
    }

    /// Stable per post: a resubmission after a timeout creates no second post.
    var idempotencyKey: String { "sf-\(uuid.uuidString.lowercased())" }
}

/// A connected account, associated with one workspace.
/// Provider credentials may be shared across multiple workspaces via `credentialProfileID`
/// without duplicating tokens, and disconnecting in one workspace does not revoke tokens
/// still referenced by other workspaces.
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
    var lastVerifiedAt: Date?
    var lastError: String?
    var isMock: Bool = false
    /// "mac" for accounts this Mac connected itself (tokens in the Keychain), "service" for the optional publishing service.
    var source: String = "service"
    /// Optional shared provider credential profile ID (allows one OAuth identity across multiple brand workspaces).
    var credentialProfileID: String = ""
    /// Dynamic capability metadata: e.g. "business", "creator", "page", "organization", "channel".
    var accountType: String = ""
    /// Authentication mode / environment: e.g. "facebook_login", "instagram_login", "oauth2_pkce", "sandbox", "production".
    var authMode: String = ""
    var refreshedAt: Date = Date.now

    init(serverID: String, workspaceID: UUID, platform: String, name: String, status: String) {
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.platform = platform
        self.name = name
        self.status = status
    }

    /// Keychain item that holds this account's access token (on-Mac accounts only).
    /// Uses shared credentialProfileID when set, otherwise falls back to legacy token.<serverID>.
    var tokenKey: String {
        credentialProfileID.isEmpty ? "token.\(serverID)" : "cred.\(credentialProfileID)"
    }

    var refreshTokenKey: String { tokenKey + ".refresh" }

    /// The platform's own id (Page, Instagram account, Threads user, LinkedIn URN, etc.) for accounts this Mac connected.
    var platformID: String {
        let prefix = "mac-\(platform)-"
        return serverID.hasPrefix(prefix) ? String(serverID.dropFirst(prefix.count)) : serverID
    }

    var capabilities: [AccountCapability] {
        Capabilities.forAccount(platform: platform, grantedScopes: Set(scopes), status: status)
    }

    var connectionStatus: ConnectionStatus {
        let missing = Array(Set(capabilities.flatMap(\.missingScopes))).sorted()
        let hasCred = isMock || source == "service" || (Keychain.read(tokenKey)?.isEmpty == false)
        let hasLimitations = authMode == "sandbox" || (platform == "instagram" && PublicMediaSettings.config() == nil)
            || (platform == "threads" && PublicMediaSettings.config() == nil)
        return ConnectionStatus.fromAccount(
            status: status, tokenExpiresAt: tokenExpiresAt, missingPermissions: missing,
            hasCredential: hasCred, isMock: isMock, hasLimitations: hasLimitations
        )
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
    var preferredTerms: [String] = []
    var website: String = ""
    var defaultLink: String = ""
    var defaultAIProviderID: String = ""
    var isPrimary: Bool = false
    /// Logo file in the library (PNG with transparency works best).
    var logoPath: String = ""
    var imageStyle: String = ""
    /// Where this brand's imports, exports, and AI generations are saved, such as
    /// ~/Documents/Oak & Ember. Empty: the app's library in Application Support.
    var folderPath: String = ""

    init(workspaceID: UUID, name: String) {
        self.workspaceID = workspaceID
        self.name = name
    }

    var style: BrandStyle {
        BrandStyle(
            palette: colors.map { RGBA(hex: UInt32(bitPattern: Int32(truncatingIfNeeded: $0)) & 0xFFFFFF) },
            headlineFont: headlineFont,
            bodyFont: bodyFont,
            logoPath: logoPath.isEmpty ? nil : logoPath
        )
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
    var utmContent: String = ""
    var utmTerm: String = ""
    /// When true, each platform uses its own name as utm_source (e.g. pinterest, instagram, linkedin).
    var perPlatformUTMSource: Bool = true
    var accountIDs: [String] = []
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
    var extraAssetIDs: [UUID] = []
    var campaignID: UUID?
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(workspaceID: UUID) { self.workspaceID = workspaceID }
}

/// One AI request: copy, an image batch, video/music generation, or a command plan.
@Model
final class AIJob {
    var uuid: UUID = UUID()
    var workspaceID: UUID
    var provider: String
    var modelName: String = ""
    var workflowName: String = ""
    var serverURL: String = ""
    var remoteJobID: String = ""
    var kind: String
    var prompt: String
    var negativePrompt: String = ""
    var status: String = "running"
    var detail: String = ""
    var outputAssetIDs: [UUID] = []
    var seed: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cachedTokens: Int = 0
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
    /// folder, manual, weekly, tag
    var trigger: String = "folder"
    var folderPath: String = ""
    var weekday: Int = 2
    var hour: Int = 9
    var presetID: String = ""
    var templateID: UUID?
    var generateCopy: Bool = false
    var platform: String = "pinterest"
    var accountID: String = ""
    var boardID: String = ""
    var boardName: String = ""
    var campaignID: UUID?
    var everyDays: Int = 1
    var postHour: Int = 9
    var postMinute: Int = 0
    var tag: String = ""
    /// Persisted file/asset fingerprints already processed so folders/tags are never reprocessed.
    var processedFingerprints: [String] = []
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
    /// Human-readable name of the size set this design belongs to.
    var sizeSet: String = ""
    /// Stable UUID grouping key for generated size sets (prevents name collisions).
    var sizeSetID: String = ""

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
    var idempotencyKey: String = ""
    var provider: String = ""
    var accountID: String = ""
    var route: String = "mac"
    var operation: String = "publish"
    var containerID: String?
    var startedAt: Date = Date.now
    var finishedAt: Date?
    /// success, reconciled, retryable, rateLimited, uncertain, auth, permission, permanent
    var outcome: String?
    var httpStatus: Int?
    var requestID: String?
    var error: String?
    var nextRetryAt: Date?

    init(publicationID: UUID, attempt: Int) {
        self.publicationID = publicationID
        self.attempt = attempt
    }
}

/// What happened, for Home's activity list and Operations log.
@Model
final class ActivityEntry {
    var workspaceID: UUID
    var category: String = "general"
    var text: String
    var symbol: String
    var at: Date = Date.now

    init(workspaceID: UUID, text: String, symbol: String, category: String = "general") {
        self.workspaceID = workspaceID
        self.category = category
        self.text = text
        self.symbol = symbol
    }
}

enum AppSchema {
    static let currentVersion = "2.0.0"

    static let models: [any PersistentModel.Type] = [
        Workspace.self, MediaAsset.self, MediaVariant.self, Publication.self,
        SocialAccount.self, BrandKit.self, Design.self, ActivityEntry.self, PublishAttempt.self,
        CreativeTemplate.self, Campaign.self, ContentItem.self, AIJob.self, ComfyWorkflowRecord.self, Automation.self, AutomationRun.self,
    ]
}

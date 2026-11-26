import Foundation

/// One platform's capabilities and media rules, from spec/platforms/<id>.json.
/// The app and the backend read the same files.
public struct PlatformSpec: Sendable, Codable, Identifiable {
    public struct Source: Sendable, Codable { public let title: String; public let url: String; public let checked: String }
    public struct ContentType: Sendable, Codable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let requiredScopes: [String]
        public let needsDestination: String
    }
    public struct TextRule: Sendable, Codable {
        public let max: Int
        public let required: Bool
        public let enforced: Bool
    }
    public struct Size: Sendable, Codable { public let width: Int; public let height: Int; public let aspect: String }
    public struct ImageRule: Sendable, Codable {
        public let formats: [String]
        public let maxBytes: Int
        public let maxBytesEnforced: Bool
        public let recommended: Size
        public let recommendedMinWidth: Int
        public let note: String?
    }
    /// Video rules. Optional fields are absent when the platform publishes no limit.
    public struct VideoRule: Sendable, Codable {
        public let formats: [String]
        public let codecs: [String]
        public let audio: [String]
        public let maxBytes: Int?
        public let minSeconds: Double?
        public let maxSeconds: Double?
        public let recommended: Size
        public let maxFps: Double?
        public let minFps: Double?
        public let note: String?
    }

    public let platform: String
    public let name: String
    public let specVersion: String
    /// "available" or "planned". Planned platforms are never offered for posting.
    public let status: String
    /// True only after a real publish against the live API succeeded.
    public let liveVerified: Bool
    public let sources: [Source]
    public let contentTypes: [ContentType]
    public let text: [String: TextRule]
    /// Nil when the platform takes no image posts (YouTube Shorts).
    public let image: ImageRule?
    /// Nil when the platform takes no video posts through its API.
    public let video: VideoRule?

    public var id: String { platform }
    public var isAvailable: Bool { status == "available" }
}

public enum PlatformRegistry {
    public static let all: [PlatformSpec] = {
        let decoder = JSONDecoder()
        return PlatformSpecData.json.keys.sorted().compactMap { key in
            guard let data = PlatformSpecData.json[key]?.data(using: .utf8) else { return nil }
            do { return try decoder.decode(PlatformSpec.self, from: data) } catch {
                assertionFailure("spec \(key): \(error)")
                return nil
            }
        }
    }()

    public static func spec(_ platform: String) -> PlatformSpec? {
        all.first { $0.platform == platform }
    }
}

// MARK: - Validation

public struct ValidationIssue: Sendable, Equatable, Hashable {
    public enum Level: String, Sendable { case error, warning, info }
    public let level: Level
    public let field: String
    public let message: String
    public init(_ level: Level, _ field: String, _ message: String) {
        self.level = level; self.field = field; self.message = message
    }
}

/// Explicit platform integration maturity & availability level.
public enum PlatformSupportLevel: String, Sendable, Codable, CaseIterable {
    case notImplemented
    case exportOnly
    case implementedTested
    case connectedAccount
    case liveVerified
    case approvalRestricted
    case productionReady

    public var label: String {
        switch self {
        case .notImplemented: "Not implemented"
        case .exportOnly: "Export only"
        case .implementedTested: "Built · automated tests"
        case .connectedAccount: "Connected"
        case .liveVerified: "Live verified"
        case .approvalRestricted: "Restricted by provider approval"
        case .productionReady: "Ready for production"
        }
    }
}

/// X (Twitter) weighted character length: URLs count as 23 chars via t.co,
/// CJK / fullwidth / emoji codepoints outside standard Latin blocks count as 2.
public enum XTextLength {
    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: [.caseInsensitive])

    public static func weightedCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let ns = text as NSString
        var replaced = text
        var urlCount = 0
        if let regex = urlRegex {
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            urlCount = matches.count
            for m in matches.reversed() {
                if let range = Range(m.range, in: replaced) {
                    replaced.removeSubrange(range)
                }
            }
        }
        var weight = urlCount * 23
        for scalar in replaced.unicodeScalars {
            let v = scalar.value
            // Standard Latin, punctuation, general symbols weight 1; CJK / emoji / wide glyphs weight 2.
            let isWeightedOne =
                (0x0000...0x10FF).contains(v) ||
                (0x2000...0x200D).contains(v) ||
                (0x2010...0x201F).contains(v) ||
                (0x2032...0x2037).contains(v)
            weight += isWeightedOne ? 1 : 2
        }
        return weight
    }
}

/// The fields of one platform post that validation looks at.
public struct PostDraft: Sendable, Equatable {
    public var platform: String
    public var title: String
    public var description: String
    public var link: String
    public var altText: String
    public var destinationID: String?
    public var image: ImageFacts?
    public var isVideo: Bool
    public var hasPublicMediaHost: Bool?

    public init(platform: String, title: String = "", description: String = "", link: String = "",
                altText: String = "", destinationID: String? = nil, image: ImageFacts? = nil,
                isVideo: Bool = false, hasPublicMediaHost: Bool? = nil) {
        self.platform = platform; self.title = title; self.description = description; self.link = link
        self.altText = altText; self.destinationID = destinationID; self.image = image
        self.isVideo = isVideo; self.hasPublicMediaHost = hasPublicMediaHost
    }
}

public struct ImageFacts: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bytes: Int
    /// Lowercase format name: jpeg, png, heic, webp...
    public var format: String
    public init(width: Int, height: Int, bytes: Int, format: String) {
        self.width = width; self.height = height; self.bytes = bytes; self.format = format
    }
}

public enum PostValidator {
    public static func validate(_ post: PostDraft) -> [ValidationIssue] {
        guard let spec = PlatformRegistry.spec(post.platform) else {
            return [ValidationIssue(.error, "platform", "Unknown platform “\(post.platform)”.")]
        }
        var issues: [ValidationIssue] = []
        if !spec.isAvailable {
            issues.append(ValidationIssue(.error, "platform", "\(spec.name) publishing is not available yet."))
        }
        func checkText(_ key: String, _ label: String, _ value: String, weighted: Bool = false) {
            guard let rule = spec.text[key] else { return }
            if rule.required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(.error, key, "\(label) is required."))
            }
            let length = weighted ? XTextLength.weightedCount(value) : value.count
            if length > rule.max {
                issues.append(ValidationIssue(rule.enforced ? .error : .warning, key,
                                              "\(label) is \(length) characters; \(spec.name) allows \(rule.max)."))
            }
        }
        switch post.platform {
        case "pinterest":
            checkText("title", "Title", post.title)
            checkText("description", "Description", post.description)
            checkText("alt_text", "Alt text", post.altText)
            checkText("link", "Link", post.link)
            if post.destinationID == nil {
                issues.append(ValidationIssue(.error, "board", "Choose a board."))
            }
            if post.link.isEmpty {
                issues.append(ValidationIssue(.warning, "link", "No destination link; the Pin will not lead anywhere."))
            } else if !MetadataMatcher.isWebURL(post.link) {
                issues.append(ValidationIssue(.error, "link", "The link must start with http:// or https://."))
            }
            if post.title.isEmpty {
                issues.append(ValidationIssue(.warning, "title", "No title. Titles help Pins show up in search."))
            }
            if post.altText.isEmpty {
                issues.append(ValidationIssue(.info, "alt_text", "Add alt text so people using screen readers know what the image shows."))
            }
        case "facebook":
            checkText("message", "Message", post.description.isEmpty ? post.title : post.description)
            if !post.link.isEmpty && !MetadataMatcher.isWebURL(post.link) {
                issues.append(ValidationIssue(.error, "link", "The link must start with http:// or https://."))
            }
        case "instagram":
            checkText("caption", "Caption", post.description.isEmpty ? post.title : post.description)
            if post.image != nil && !post.isVideo && post.hasPublicMediaHost == false {
                issues.append(ValidationIssue(.error, "storage", "Instagram image posts require configured public media storage (S3/R2)."))
            }
        case "threads":
            checkText("text", "Text", post.description.isEmpty ? post.title : post.description)
            if (post.image != nil || post.isVideo) && post.hasPublicMediaHost == false {
                issues.append(ValidationIssue(.error, "storage", "Threads photo and video posts require configured public media storage (S3/R2)."))
            }
        case "linkedin":
            checkText("commentary", "Commentary", post.description.isEmpty ? post.title : post.description)
            if !post.link.isEmpty && !MetadataMatcher.isWebURL(post.link) {
                issues.append(ValidationIssue(.error, "link", "The link must start with http:// or https://."))
            }
        case "x":
            checkText("text", "Post text", post.description.isEmpty ? post.title : post.description, weighted: true)
            if !post.link.isEmpty && !MetadataMatcher.isWebURL(post.link) {
                issues.append(ValidationIssue(.error, "link", "The link must start with http:// or https://."))
            }
        case "tiktok":
            checkText("caption", "Caption", post.description.isEmpty ? post.title : post.description)
        case "youtube":
            checkText("title", "Title", post.title)
            checkText("description", "Description", post.description)
        default:
            for key in spec.text.keys.sorted() {
                let value = key == "title" ? post.title : post.description
                checkText(key, key.capitalized, value)
            }
        }
        if let img = post.image {
            guard let rule = spec.image else {
                issues.append(ValidationIssue(.error, "image", "\(spec.name) does not take image posts."))
                return issues
            }
            if !rule.formats.contains(img.format) {
                issues.append(ValidationIssue(.error, "image", "\(img.format.uppercased()) is not accepted by \(spec.name). Make a variant in \(rule.formats.map { $0.uppercased() }.joined(separator: ", "))."))
            }
            if img.bytes > rule.maxBytes {
                let mb = Double(rule.maxBytes) / 1_048_576
                issues.append(ValidationIssue(rule.maxBytesEnforced ? .error : .warning, "image",
                                              String(format: "The image is %.1f MB; the limit is %.0f MB.", Double(img.bytes) / 1_048_576, mb)))
            }
            if img.width < rule.recommendedMinWidth {
                issues.append(ValidationIssue(.warning, "image", "The image is \(img.width) px wide; \(rule.recommendedMinWidth) px or more is recommended."))
            }
            let rec = rule.recommended
            let want = Double(rec.width) / Double(rec.height)
            let have = Double(img.width) / Double(max(1, img.height))
            if abs(want - have) / want > 0.03 {
                issues.append(ValidationIssue(.info, "image", "Recommended: \(rec.aspect) (\(rec.width) × \(rec.height)). This image is \(img.width) × \(img.height)."))
            }
        }
        return issues
    }

    /// Checks a video against a platform's rules. Errors are limits the platform enforces;
    /// a size that differs from the recommended one is only information.
    public static func validateVideo(platform: String, seconds: Double, width: Int, height: Int, bytes: Int, format: String,
                                     fps: Double? = nil, requireShortsAspect: Bool = false) -> [ValidationIssue] {
        guard let spec = PlatformRegistry.spec(platform) else {
            return [ValidationIssue(.error, "platform", "Unknown platform “\(platform)”.")]
        }
        guard let rule = spec.video else { return [ValidationIssue(.error, "video", "\(spec.name) does not take video posts.")] }
        var issues: [ValidationIssue] = []
        let fmt = format.lowercased()
        if !rule.formats.contains(fmt) {
            issues.append(ValidationIssue(.error, "video", "\(fmt.uppercased()) is not accepted by \(spec.name). Export \(rule.formats.map { $0.uppercased() }.joined(separator: " or "))."))
        }
        if let min = rule.minSeconds, seconds < min {
            issues.append(ValidationIssue(.error, "video", String(format: "The video is %.1f s; %@ needs at least %@ s.", seconds, spec.name, Self.number(min))))
        }
        if let max = rule.maxSeconds, seconds > max {
            issues.append(ValidationIssue(.error, "video", String(format: "The video is %.1f s; %@ allows up to %@.", seconds, spec.name, Self.duration(max))))
        }
        if let max = rule.maxBytes, bytes > max {
            issues.append(ValidationIssue(.error, "video", String(format: "The video is %.0f MB; the limit is %.0f MB.", Double(bytes) / 1_048_576, Double(max) / 1_048_576)))
        }
        if let fps {
            if let max = rule.maxFps, fps > max + 0.01 { issues.append(ValidationIssue(.error, "video", "\(Self.number(fps)) fps is above \(spec.name)'s \(Self.number(max)) fps.")) }
            if let min = rule.minFps, fps < min - 0.01 { issues.append(ValidationIssue(.error, "video", "\(Self.number(fps)) fps is below \(spec.name)'s \(Self.number(min)) fps.")) }
        }
        if platform == "youtube" && requireShortsAspect && width > height {
            issues.append(ValidationIssue(.error, "video", "YouTube Shorts must be square or vertical (width ≤ height). This video is \(width) × \(height)."))
        }
        let rec = rule.recommended
        let want = Double(rec.width) / Double(rec.height)
        let have = Double(width) / Double(max(1, height))
        if abs(want - have) / want > 0.03 {
            issues.append(ValidationIssue(.info, "video", "Recommended: \(rec.aspect) (\(rec.width) × \(rec.height)). This video is \(width) × \(height)."))
        }
        return issues
    }

    /// "90 s", "3 min", "1 h 30 min".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return s % 3600 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \((s % 3600) / 60) min"
    }

    static func number(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }

    /// Warnings across a whole run: the same image or link used twice.
    public static func duplicates(_ posts: [(id: String, imageHash: String?, link: String)]) -> [String: [ValidationIssue]] {
        var out: [String: [ValidationIssue]] = [:]
        let byHash = Dictionary(grouping: posts.filter { $0.imageHash != nil }, by: { $0.imageHash! })
        for (_, group) in byHash where group.count > 1 {
            for p in group { out[p.id, default: []].append(ValidationIssue(.warning, "image", "The same image is used in \(group.count) posts.")) }
        }
        let byLink = Dictionary(grouping: posts.filter { !$0.link.isEmpty }, by: { $0.link.lowercased() })
        for (_, group) in byLink where group.count > 1 {
            for p in group { out[p.id, default: []].append(ValidationIssue(.warning, "link", "The same link is used in \(group.count) posts; platforms may treat repeats as spam.")) }
        }
        return out
    }
}

// MARK: - Account capabilities

public struct AccountCapability: Sendable, Equatable {
    public let contentType: PlatformSpec.ContentType
    public let allowed: Bool
    /// Why it is not allowed, in words a person can act on.
    public let reason: String?
    public let missingScopes: [String]
}

public enum Capabilities {
    /// What a connected account can do, from the spec and its granted scopes.
    /// Never allows a content type whose platform is planned, or whose scopes are missing.
    public static func forAccount(platform: String, grantedScopes: Set<String>, status: String) -> [AccountCapability] {
        guard let spec = PlatformRegistry.spec(platform) else { return [] }
        return spec.contentTypes.map { ct in
            let missing = ct.requiredScopes.filter { !grantedScopes.contains($0) }
            if !spec.isAvailable {
                return AccountCapability(contentType: ct, allowed: false, reason: PlatformStatus.notBuiltReason(spec), missingScopes: missing)
            }
            if status != "connected" {
                return AccountCapability(contentType: ct, allowed: false, reason: "The account is \(status). Reconnect it to publish.", missingScopes: missing)
            }
            if !missing.isEmpty {
                return AccountCapability(contentType: ct, allowed: false,
                                         reason: "Missing permission: \(missing.joined(separator: ", ")). Reconnect and allow it.", missingScopes: missing)
            }
            return AccountCapability(contentType: ct, allowed: true, reason: nil, missingScopes: [])
        }
    }
}

// MARK: - What SocialForge does for each platform today

public enum PlatformStatus {
    /// One honest line per platform, for Connections and Settings.
    public static func summary(_ spec: PlatformSpec) -> String {
        switch spec.platform {
        case "pinterest":
            "Posts from this Mac (not yet verified live): image & video Pins with board discovery and refresh tokens."
        case "facebook":
            "Posts from this Mac (not yet verified live): text, photos, multi-photos, links, and Reels to managed Pages."
        case "instagram":
            "Posts from this Mac (not yet verified live): Reels upload directly; photos & carousels require public media storage."
        case "threads":
            "Posts from this Mac (not yet verified live): text posts directly; photos, videos & carousels require public media storage."
        case "linkedin":
            "Posts from this Mac (not yet verified live): personal profiles (Share on LinkedIn) and company pages (Community Management API approval)."
        case "x":
            "Posts from this Mac (not yet verified live): OAuth 2.0 PKCE + v2 text and chunked media upload (subject to X API tier limits)."
        case "tiktok":
            "Posts from this Mac (not yet verified live): Content Posting API v2 (Creator Inbox drafts or audited Direct Post) plus manual export fallback."
        case "youtube":
            "Posts from this Mac (not yet verified live): YouTube Data API v3 resumable video & Shorts uploads with channel selection and disclosures."
        default:
            spec.video != nil
                ? "Export only: SocialForge makes the video at the right size; you upload it."
                : "Export only: SocialForge makes the post at the right size; you upload it."
        }
    }

    public static func supportLevel(_ spec: PlatformSpec, connected: Bool = false, approvalRestricted: Bool = false) -> PlatformSupportLevel {
        guard spec.isAvailable else { return spec.video != nil ? .exportOnly : .notImplemented }
        if spec.liveVerified && connected && !approvalRestricted { return .productionReady }
        if spec.liveVerified { return .liveVerified }
        if approvalRestricted { return .approvalRestricted }
        if connected { return .connectedAccount }
        return .implementedTested
    }

    public static func notBuiltReason(_ spec: PlatformSpec) -> String {
        spec.video != nil
            ? "Posting to \(spec.name) isn't built yet. Export the video from Studio and upload it in \(spec.name)."
            : "Posting to \(spec.name) isn't built yet. Export the image from Studio and upload it in \(spec.name)."
    }
}

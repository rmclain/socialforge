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
    public let image: ImageRule

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

/// The fields of one platform post that validation looks at.
public struct PostDraft: Sendable, Equatable {
    public var platform: String
    public var title: String
    public var description: String
    public var link: String
    public var altText: String
    public var destinationID: String?
    public var image: ImageFacts?

    public init(platform: String, title: String = "", description: String = "", link: String = "",
                altText: String = "", destinationID: String? = nil, image: ImageFacts? = nil) {
        self.platform = platform; self.title = title; self.description = description; self.link = link
        self.altText = altText; self.destinationID = destinationID; self.image = image
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
        func checkText(_ key: String, _ label: String, _ value: String) {
            guard let rule = spec.text[key] else { return }
            if rule.required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(.error, key, "\(label) is required."))
            }
            if value.count > rule.max {
                issues.append(ValidationIssue(rule.enforced ? .error : .warning, key,
                                              "\(label) is \(value.count) characters; \(spec.name) allows \(rule.max)."))
            }
        }
        if post.platform == "pinterest" {
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
        }
        if let img = post.image {
            if !spec.image.formats.contains(img.format) {
                issues.append(ValidationIssue(.error, "image", "\(img.format.uppercased()) is not accepted by \(spec.name). Make a variant in \(spec.image.formats.map { $0.uppercased() }.joined(separator: ", "))."))
            }
            if img.bytes > spec.image.maxBytes {
                let mb = Double(spec.image.maxBytes) / 1_048_576
                issues.append(ValidationIssue(spec.image.maxBytesEnforced ? .error : .warning, "image",
                                              String(format: "The image is %.1f MB; the limit is %.0f MB.", Double(img.bytes) / 1_048_576, mb)))
            }
            if img.width < spec.image.recommendedMinWidth {
                issues.append(ValidationIssue(.warning, "image", "The image is \(img.width) px wide; \(spec.image.recommendedMinWidth) px or more is recommended."))
            }
            let rec = spec.image.recommended
            let want = Double(rec.width) / Double(rec.height)
            let have = Double(img.width) / Double(max(1, img.height))
            if abs(want - have) / want > 0.03 {
                issues.append(ValidationIssue(.info, "image", "Recommended: \(rec.aspect) (\(rec.width) × \(rec.height)). This image is \(img.width) × \(img.height)."))
            }
        }
        return issues
    }

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
                return AccountCapability(contentType: ct, allowed: false, reason: "\(spec.name) publishing comes in milestone 4.", missingScopes: missing)
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

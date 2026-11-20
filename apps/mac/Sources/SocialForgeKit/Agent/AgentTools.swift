import Foundation

/// A tool that Claude, Codex, or another agent can call through `SocialForge --mcp`.
public struct AgentTool: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let inputSchema: JSONValue
    /// True for tools that change the library: they go through the Agent Inbox and the app applies them.
    public let queued: Bool
}

/// The tools `SocialForge --mcp` offers, and the checks a queued request passes before it is accepted.
public enum AgentTools {
    public static let all: [AgentTool] = [
        AgentTool(name: "list_brands",
                  description: "List the brands (workspaces) in SocialForge. Other tools take a `brand` (id or name); without one they use the brand marked default, the one open in the app.",
                  inputSchema: object([:]), queued: false),
        AgentTool(name: "list_accounts",
                  description: "List the social accounts connected for a brand. Use an account's `id` in create_posts.",
                  inputSchema: object(["brand": brandArg]), queued: false),
        AgentTool(name: "list_media",
                  description: "List media in a brand's library, newest first. Use a media `id` in create_posts or update_media.",
                  inputSchema: object([
                    "brand": brandArg,
                    "query": string("Text to match in the filename, title, or tags."),
                    "collection": string("Only media in this collection."),
                    "kind": .object(["type": .string("string"), "enum": .array(["image", "video", "audio"].map(JSONValue.string))]),
                    "limit": integer("At most this many (default 50, up to 500)."),
                  ]), queued: false),
        AgentTool(name: "list_posts",
                  description: "List a brand's posts, soonest first.",
                  inputSchema: object([
                    "brand": brandArg,
                    "status": .object(["type": .string("string"), "description": .string("Only posts with this status."),
                                       "enum": .array(statuses.map(JSONValue.string))]),
                    "from": string("Scheduled at or after this ISO 8601 date-time."),
                    "to": string("Scheduled before this ISO 8601 date-time."),
                    "limit": integer("At most this many (default 50, up to 500)."),
                  ]), queued: false),
        AgentTool(name: "import_media",
                  description: "Copy image, video, or audio files (or folders of them) on this Mac into a brand's library. Queued: SocialForge adds them while it is open, or the next time it opens. The originals are never changed. Check the result with get_request_status, which lists the new media ids.",
                  inputSchema: object([
                    "brand": brandArg,
                    "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                      "description": .string("Absolute paths of files or folders.")]),
                    "collection": string("Put the new media in this collection."),
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                  ], required: ["paths"]), queued: true),
        AgentTool(name: "create_posts",
                  description: "Create posts for a brand. Every post goes to the person's review queue (Needs Review) and is only published after they approve it in SocialForge. Queued like import_media. Each post needs an account and either a media id or a file path.",
                  inputSchema: object([
                    "brand": brandArg,
                    "posts": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(Double(maxPosts)), "items": object([
                        "account_id": string("An account id from list_accounts."),
                        "media_id": string("A media id from list_media."),
                        "file": string("Or an absolute path to a file to import first."),
                        "title": string("Title (Pin title, video title)."),
                        "description": string("Post text or description."),
                        "link": string("Destination link."),
                        "alt_text": string("Alt text for the image."),
                        "board_id": string("Pinterest board id, if known."),
                        "scheduled_at": string("When to post: ISO 8601, e.g. 2026-12-01T09:00:00-05:00, or 2026-12-01T09:00 in time_zone."),
                        "time_zone": string("IANA time zone, e.g. America/New_York. Defaults to this Mac's."),
                    ], required: ["account_id", "scheduled_at"])]),
                  ], required: ["posts"]), queued: true),
        AgentTool(name: "update_media",
                  description: "Change a media item's title, alt text, product link, collection, or tags. Queued like import_media.",
                  inputSchema: object([
                    "media_id": string("A media id from list_media."),
                    "title": string("New title."),
                    "alt_text": string("New alt text."),
                    "product_url": string("New product link."),
                    "collection": string("New collection; empty takes it out of its collection."),
                    "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                     "description": .string("Replaces the tags.")]),
                  ], required: ["media_id"]), queued: true),
        AgentTool(name: "get_request_status",
                  description: "Whether queued requests (import_media, create_posts, update_media) are done, and what they made. Without request_id, lists the latest ones.",
                  inputSchema: object(["request_id": string("The id a queued tool returned.")]), queued: false),
    ]

    public static let maxPosts = 100
    public static let statuses = ["draft", "needsReview", "approved", "scheduled", "preparing", "publishing", "published", "failed", "paused", "canceled"]

    public static func tool(_ name: String) -> AgentTool? { all.first { $0.name == name } }

    /// Why a queued request cannot be accepted, or nil when it can. Runs before anything is queued,
    /// so an agent hears about a bad path or date at once instead of in a later status check.
    public static func problem(tool: String, args: [String: JSONValue], now: Date = .now) -> String? {
        switch tool {
        case "import_media":
            guard let paths = args["paths"]?.arrayValue?.compactMap(\.stringValue), !paths.isEmpty else { return "paths needs at least one file or folder." }
            if let missing = paths.first(where: { !$0.hasPrefix("/") || !FileManager.default.fileExists(atPath: $0) }) {
                return "Not found (use an absolute path): \(missing)"
            }
            return nil
        case "create_posts":
            guard let posts = args["posts"]?.arrayValue, !posts.isEmpty else { return "posts needs at least one post." }
            guard posts.count <= maxPosts else { return "At most \(maxPosts) posts per request." }
            for (i, value) in posts.enumerated() {
                let n = "Post \(i + 1)"
                guard let p = value.objectValue else { return "\(n) is not an object." }
                guard p["account_id"]?.stringValue?.isEmpty == false else { return "\(n) needs an account_id (see list_accounts)." }
                let media = p["media_id"]?.stringValue ?? "", file = p["file"]?.stringValue ?? ""
                if media.isEmpty && file.isEmpty { return "\(n) needs a media_id or a file." }
                if !file.isEmpty, !file.hasPrefix("/") || !FileManager.default.fileExists(atPath: file) { return "\(n): file not found (use an absolute path): \(file)" }
                if !media.isEmpty, UUID(uuidString: media) == nil { return "\(n): media_id is not a media id from list_media." }
                let zoneID = p["time_zone"]?.stringValue ?? ""
                if !zoneID.isEmpty, TimeZone(identifier: zoneID) == nil { return "\(n): unknown time_zone \(zoneID)." }
                guard let when = date(p["scheduled_at"]?.stringValue ?? "", timeZone: TimeZone(identifier: zoneID) ?? .current) else {
                    return "\(n): scheduled_at must be ISO 8601, e.g. 2026-12-01T09:00:00-05:00."
                }
                if when < now.addingTimeInterval(-60) { return "\(n): scheduled_at is in the past." }
            }
            return nil
        case "update_media":
            guard let id = args["media_id"]?.stringValue, UUID(uuidString: id) != nil else { return "media_id is not a media id from list_media." }
            let fields = ["title", "alt_text", "product_url", "collection", "tags"]
            return fields.contains(where: { args[$0] != nil }) ? nil : "Nothing to change: give title, alt_text, product_url, collection, or tags."
        default:
            return nil
        }
    }

    /// ISO 8601 with an offset or Z, with or without seconds and fractions; without an offset it is read in `timeZone`.
    public static func date(_ text: String, timeZone: TimeZone) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: Schema helpers

    static let brandArg = string("Brand id or name from list_brands. Defaults to the brand open in the app.")

    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { o["required"] = .array(required.map(JSONValue.string)) }
        return .object(o)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}

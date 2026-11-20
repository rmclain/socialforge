import Foundation

/// Where to get the developer app ID and secret (the "keys") for each platform.
///
/// SocialForge never ships a shared app: every person makes their own developer app
/// on the platform's site and pastes its ID and secret into Settings > Publishing.
public struct PlatformKeys: Sendable, Identifiable, Equatable {
    public var id: String { platform }
    public let platform: String
    /// The developer site page where the app is created and its keys are shown.
    public let portal: URL
    /// The platform's own guide for that step.
    public let guide: URL
    /// One line: what to make there and what to copy.
    public let steps: String
    /// What to copy back into SocialForge.
    public let keys: [String]
    /// True when SocialForge has a place for these keys today (Settings > Publishing).
    public let usedBySocialForge: Bool

    public static let all: [PlatformKeys] = [
        PlatformKeys(platform: "pinterest",
                     portal: URL(string: "https://developers.pinterest.com/apps/")!,
                     guide: URL(string: "https://developers.pinterest.com/docs/getting-started/set-up-app/")!,
                     steps: "Create an app (Trial access is enough to start), add the redirect URI, then copy its App ID and secret.",
                     keys: ["App ID", "App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "facebook",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/development/create-an-app/")!,
                     steps: "Create a Business app with Facebook Login, add the redirect URI, then copy the App ID and App secret from App settings > Basic.",
                     keys: ["App ID", "App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "instagram",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/instagram-platform/content-publishing/")!,
                     steps: "Uses the same Meta app as Facebook. The Instagram account must be a professional account linked to a Facebook Page you manage.",
                     keys: ["Meta App ID", "Meta App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "threads",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/threads/get-started/")!,
                     steps: "In your Meta app, add the Threads use case, register the https redirect URI, then copy the Threads App ID and secret.",
                     keys: ["Threads App ID", "Threads App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "tiktok",
                     portal: URL(string: "https://developers.tiktok.com/apps/")!,
                     guide: URL(string: "https://developers.tiktok.com/doc/content-posting-api-get-started/")!,
                     steps: "Export only for now: SocialForge makes the video and you upload it. Direct posting needs an app with the Content Posting API and TikTok's audit.",
                     keys: ["Client key", "Client secret"], usedBySocialForge: false),
        PlatformKeys(platform: "youtube",
                     portal: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!,
                     guide: URL(string: "https://developers.google.com/youtube/v3/getting-started")!,
                     steps: "Export only for now. Direct uploads need a Google Cloud project with the YouTube Data API v3 and an OAuth client ID.",
                     keys: ["OAuth client ID", "Client secret"], usedBySocialForge: false),
        PlatformKeys(platform: "x",
                     portal: URL(string: "https://developer.x.com/en/portal/dashboard")!,
                     guide: URL(string: "https://docs.x.com/fundamentals/developer-apps")!,
                     steps: "Drafts only for now. Posting needs a project and app in the X developer portal with OAuth 2.0 turned on.",
                     keys: ["Client ID", "Client secret"], usedBySocialForge: false),
        PlatformKeys(platform: "linkedin",
                     portal: URL(string: "https://www.linkedin.com/developers/apps")!,
                     guide: URL(string: "https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api")!,
                     steps: "Drafts only for now. Posting needs a LinkedIn app with the Share on LinkedIn product.",
                     keys: ["Client ID", "Client secret"], usedBySocialForge: false),
    ]

    public static func forPlatform(_ platform: String) -> PlatformKeys? { all.first { $0.platform == platform } }
}

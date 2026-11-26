import Foundation

/// Where to get the developer app ID and secret (the "keys") for each platform.
///
/// SocialForge never ships a shared app: every person makes their own developer app
/// on the platform's site and pastes its ID and secret into Connections.
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
    /// True when SocialForge has a place for these keys today (Connections).
    public let usedBySocialForge: Bool

    public static let all: [PlatformKeys] = [
        PlatformKeys(platform: "pinterest",
                     portal: URL(string: "https://developers.pinterest.com/apps/")!,
                     guide: URL(string: "https://developers.pinterest.com/docs/getting-started/set-up-app/")!,
                     steps: "Create an app (Trial access writes to Sandbox; Standard access writes to live Pinterest), add the redirect URI, and copy its App ID and secret.",
                     keys: ["App ID", "App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "facebook",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/development/create-an-app/")!,
                     steps: "Create a Business app with Facebook Login, add the redirect URI, and copy the App ID and App secret from App settings > Basic. Publishes to managed Pages only.",
                     keys: ["App ID", "App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "instagram",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/instagram-platform/content-publishing/")!,
                     steps: "Connect via Facebook Login (linked Page) or direct Instagram Business Login. Requires a professional (Business or Creator) account; photo posts need public media storage.",
                     keys: ["App ID", "App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "threads",
                     portal: URL(string: "https://developers.facebook.com/apps/")!,
                     guide: URL(string: "https://developers.facebook.com/docs/threads/get-started/")!,
                     steps: "Add the Threads use case in your Meta app, register the HTTPS redirect URI, and copy the Threads App ID and secret.",
                     keys: ["Threads App ID", "Threads App secret"], usedBySocialForge: true),
        PlatformKeys(platform: "linkedin",
                     portal: URL(string: "https://www.linkedin.com/developers/apps")!,
                     guide: URL(string: "https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api")!,
                     steps: "Create a LinkedIn app, enable Share on LinkedIn (personal profiles) or Community Management API (company pages), add the loopback redirect URI, and copy Client ID and secret.",
                     keys: ["Client ID", "Client secret"], usedBySocialForge: true),
        PlatformKeys(platform: "x",
                     portal: URL(string: "https://developer.x.com/en/portal/dashboard")!,
                     guide: URL(string: "https://docs.x.com/fundamentals/developer-apps")!,
                     steps: "Create a Native/Web app with OAuth 2.0 (PKCE) enabled, add the loopback redirect URI, and copy Client ID (and optional secret). Write access depends on your X API tier.",
                     keys: ["Client ID", "Client secret (optional)"], usedBySocialForge: true),
        PlatformKeys(platform: "tiktok",
                     portal: URL(string: "https://developers.tiktok.com/apps/")!,
                     guide: URL(string: "https://developers.tiktok.com/doc/content-posting-api-get-started/")!,
                     steps: "Create a TikTok app with Login Kit + Content Posting API and add the redirect URI. Unaudited apps upload to Creator Inbox drafts or private-only posts; export fallback is always available.",
                     keys: ["Client key", "Client secret"], usedBySocialForge: true),
        PlatformKeys(platform: "youtube",
                     portal: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!,
                     guide: URL(string: "https://developers.google.com/youtube/v3/getting-started")!,
                     steps: "Enable YouTube Data API v3 in Google Cloud, create an OAuth 2.0 Desktop/Web client ID with the loopback redirect URI, and copy Client ID and secret. Unverified projects restrict uploads to private.",
                     keys: ["OAuth client ID", "Client secret"], usedBySocialForge: true),
    ]

    public static func forPlatform(_ platform: String) -> PlatformKeys? { all.first { $0.platform == platform } }
}

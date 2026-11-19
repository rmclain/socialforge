import Foundation

// Updates from the newest GitHub release of the app's own repository, the same
// way ForgeDeck updates. The check is one unauthenticated request to
// api.github.com; nothing about this Mac or its data is sent. An update is
// installed only when its signature is valid and from the same team as the
// running app.

public struct AppRelease: Sendable, Equatable {
    public var version: String
    public var tag: String
    public var name: String
    public var notes: String
    public var pageURL: URL
    public var publishedAt: Date?
    /// The zip of the app, from the release's assets.
    public var downloadURL: URL
    public var size: Int
}

public enum UpdateCheck: Sendable, Equatable {
    case upToDate(latest: String)
    case available(AppRelease)
    /// A release exists but has no app zip, or the repository has no releases yet.
    case noDownload(String)
    case failed(String)
}

public enum AppVersion {
    /// Compares dotted versions numerically. "v0.10" is newer than "0.9". Missing parts count as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ text: String) -> [Int] {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        // "1.2.0-beta" compares as 1.2.0.
        let core = t.split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

public struct UpdateChecker: Sendable {
    /// owner/name of the repository that publishes releases.
    public let repository: String
    let session: URLSession
    let apiBase: URL

    public init(repository: String, session: URLSession = .shared, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.repository = repository
        self.session = session
        self.apiBase = apiBase
    }

    public static func isValidRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && !p.hasPrefix("-") && !p.hasPrefix(".") && p.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    public func check(currentVersion: String) async -> UpdateCheck {
        guard Self.isValidRepository(repository) else { return .failed("No update source is set.") }
        var request = URLRequest(url: apiBase.appending(path: "repos/\(repository)/releases/latest"))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SocialForge-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            return .failed("Could not reach GitHub: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .noDownload("No release has been published yet.") }
        guard status == 200 else {
            return .failed(status == 403 ? "GitHub is limiting requests. Try again in an hour." : "GitHub answered \(status).")
        }
        guard let release = Self.parse(data) else { return .noDownload("The latest release has no SocialForge zip.") }
        return AppVersion.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate(latest: release.version)
    }

    public static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !(json["draft"] as? Bool ?? false), !(json["prerelease"] as? Bool ?? false),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let zip = assets.first { a in
            let name = (a["name"] as? String ?? "").lowercased()
            return name.hasPrefix("socialforge") && name.hasSuffix(".zip")
        }
        guard let zip, let link = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)), isTrustedDownload(link) else { return nil }
        let published = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let version = AppVersion.parts(tag).map(String.init).joined(separator: ".")
        return AppRelease(version: version, tag: tag, name: json["name"] as? String ?? tag, notes: json["body"] as? String ?? "",
                          pageURL: page, publishedAt: published, downloadURL: link, size: zip["size"] as? Int ?? 0)
    }

    /// Downloads come from GitHub over https, and their redirects stay on GitHub's own download hosts.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}

/// Downloads, unpacks, and checks an update. Swapping the app and relaunching is left to the app.
public struct UpdateInstaller: Sendable {
    public init() {}

    public enum Failure: Error, CustomStringConvertible, Equatable, LocalizedError {
        case download(String), unpack, noApp, signature(String), team(expected: String, found: String)
        public var description: String {
            switch self {
            case .download(let why): "The download failed: \(why)"
            case .unpack: "The zip could not be opened."
            case .noApp: "The zip has no SocialForge.app inside."
            case .signature(let why): "The new app's signature is not valid, so it was not installed. \(why)"
            case .team(let expected, let found): "The new app is signed by \(found), not \(expected), so it was not installed."
            }
        }
        public var errorDescription: String? { description }
    }

    /// Follows redirects only to GitHub's download hosts. No credentials are ever attached.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url.map(UpdateChecker.isTrustedDownload) == true ? request : nil
        }
    }

    public func download(_ release: AppRelease, into folder: URL) async throws -> URL {
        guard UpdateChecker.isTrustedDownload(release.downloadURL) else { throw Failure.download("not a GitHub address") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        let (temporary, response) = try await session.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.download("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appending(path: "SocialForge-\(release.version).zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: temporary, to: zip)
        return zip
    }

    /// Unzips with ditto and returns the app inside.
    public func unpack(_ zip: URL, into folder: URL) async throws -> URL {
        let target = folder.appending(path: "unpacked")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, target.path]).status == 0 else { throw Failure.unpack }
        let walker = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == "SocialForge.app" { return url }
            if url.pathExtension == "app" { walker?.skipDescendants() }
        }
        throw Failure.noApp
    }

    /// The team identifier in an app's signature, or nil when it is unsigned or ad hoc.
    public func teamIdentifier(of app: URL) async -> String? {
        guard let r = try? await Self.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]) else { return nil }
        return Self.parseTeam(r.output)
    }

    static func parseTeam(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    /// The signature must be valid, and from the same team as the running app.
    public func verify(_ app: URL, sameTeamAs current: URL) async throws {
        let r = try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard r.status == 0 else { throw Failure.signature(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // An unsigned copy cannot tell a genuine update from any other signed app, so it does not install one.
        guard let expected = await teamIdentifier(of: current) else {
            throw Failure.signature("This copy of SocialForge is not signed by a team, so updates are installed by hand.")
        }
        let found = await teamIdentifier(of: app)
        guard found == expected else { throw Failure.team(expected: expected, found: found ?? "no team") }
    }

    /// Runs a tool off the main thread and returns its exit status and combined output.
    static func run(_ tool: String, _ args: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}

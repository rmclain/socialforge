import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file found by a scan, before it is copied into the library.
public struct ScannedFile: Sendable, Equatable {
    public let url: URL
    public let kind: Kind
    public enum Kind: String, Sendable { case image, video, audio }
}

public struct SkippedFile: Sendable, Equatable {
    public let url: URL
    public let reason: String
}

public struct ScanResult: Sendable {
    public var files: [ScannedFile] = []
    public var skipped: [SkippedFile] = []
}

/// Formats SocialForge imports. Documented in docs/ARCHITECTURE.md.
public enum MediaFormats {
    public static let images: [UTType] = [.jpeg, .png, .heic, .heif, .webP, .tiff, .gif, .bmp]
    public static let videos: [UTType] = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video]
    public static let audio: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff] + [UTType(filenameExtension: "flac"), UTType(filenameExtension: "caf")].compactMap { $0 }

    public static func kind(of url: URL) -> ScannedFile.Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if images.contains(where: { type.conforms(to: $0) }) { return .image }
        if videos.contains(where: { type.conforms(to: $0) }) { return .video }
        if audio.contains(where: { type.conforms(to: $0) }) { return .audio }
        return nil
    }
}

public enum MediaScanner {
    /// Walks folders recursively and sorts files into importable and skipped.
    /// Hidden files and packages are skipped. Never reads or changes file contents.
    public static func scan(_ urls: [URL]) -> ScanResult {
        var result = ScanResult()
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                result.skipped.append(SkippedFile(url: url, reason: "Not found"))
                continue
            }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let file as URL in walker {
                    if (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true { found.append(file) }
                }
                for file in found.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    classify(file, into: &result)
                }
            } else {
                classify(url, into: &result)
            }
        }
        return result
    }

    private static func classify(_ url: URL, into result: inout ScanResult) {
        if let kind = MediaFormats.kind(of: url) {
            result.files.append(ScannedFile(url: url, kind: kind))
        } else if url.pathExtension.lowercased() != "csv" && url.pathExtension.lowercased() != "json" {
            let ext = url.pathExtension.isEmpty ? "no extension" : ".\(url.pathExtension)"
            result.skipped.append(SkippedFile(url: url, reason: "Unsupported file type (\(ext))"))
        }
    }
}

public enum ContentHash {
    /// SHA-256 of the file, streamed in 1 MB chunks so large videos do not fill memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ImageInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let hasAlpha: Bool
    public let format: String
}

public enum ImageProbe {
    /// Size and format without decoding the pixels.
    public static func info(_ url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5 to 8 rotate the image a quarter turn.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = CGImageSourceGetType(src).map { UTType($0 as String) } ?? nil
        return ImageInfo(width: w, height: h, hasAlpha: alpha, format: formatName(type))
    }

    public static func formatName(_ type: UTType?) -> String {
        guard let type else { return "unknown" }
        if type.conforms(to: .jpeg) { return "jpeg" }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "heic" }
        if type.conforms(to: .webP) { return "webp" }
        if type.conforms(to: .tiff) { return "tiff" }
        if type.conforms(to: .gif) { return "gif" }
        if type.conforms(to: .bmp) { return "bmp" }
        return type.preferredFilenameExtension ?? "unknown"
    }

    /// A downsampled thumbnail, decoded at the size it is shown.
    public static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Copies files into managed storage, one folder per content hash, so the
/// library never depends on the original staying where it was, and the
/// original is never written to.
public struct ManagedStorage: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var originals: URL { root.appending(path: "Originals", directoryHint: .isDirectory) }
    public var variants: URL { root.appending(path: "Variants", directoryHint: .isDirectory) }
    public var thumbnails: URL { root.appending(path: "Thumbnails", directoryHint: .isDirectory) }
    public var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    /// Copies `file` to Originals/<hash>/<name>. Copying again is a no-op.
    public func importCopy(of file: URL, hash: String) throws -> URL {
        let dir = originals.appending(path: hash, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: file.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            // Write to a temporary name, then move, so a crash never leaves half a file.
            let tmp = dir.appending(path: ".\(UUID().uuidString).part")
            try FileManager.default.copyItem(at: file, to: tmp)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }
}

public struct ImportOutcome: Sendable {
    public struct Imported: Sendable {
        public let source: URL
        public let stored: URL
        public let hash: String
        public let bytes: Int
        public let kind: ScannedFile.Kind
        public let info: ImageInfo?
        /// Length and size of a video or audio file.
        public var av: AVMediaInfo? = nil
    }
    public var imported: [Imported] = []
    /// Files whose hash is already in the library or earlier in this import.
    public var duplicates: [(source: URL, hash: String)] = []
    public var failed: [SkippedFile] = []
}

public enum MediaImporter {
    /// Hashes and copies files with bounded concurrency, off the main actor.
    /// `known` holds hashes already in the library. Cancelling stops between files;
    /// files already copied stay valid.
    public static func run(_ files: [ScannedFile], storage: ManagedStorage, known: Set<String>,
                           concurrency: Int = 4,
                           progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> ImportOutcome {
        var outcome = ImportOutcome()
        var results = [(ScannedFile, Result<ImportOutcome.Imported?, Error>, String?)?](repeating: nil, count: files.count)
        var done = 0
        await withTaskGroup(of: (Int, ScannedFile, Result<ImportOutcome.Imported?, Error>, String?).self) { group in
            var next = 0
            func add() {
                guard next < files.count, !Task.isCancelled else { return }
                let index = next
                let file = files[index]
                next += 1
                group.addTask {
                    do {
                        let hash = try ContentHash.sha256(of: file.url)
                        if known.contains(hash) { return (index, file, .success(nil), hash) }
                        let stored = try storage.importCopy(of: file.url, hash: hash)
                        let bytes = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        let info = file.kind == .image ? ImageProbe.info(stored) : nil
                        if file.kind == .image && info == nil {
                            return (index, file, .failure(CocoaError(.fileReadCorruptFile)), hash)
                        }
                        var av: AVMediaInfo?
                        if file.kind != .image {
                            av = await AVProbe.info(stored)
                            if av == nil { return (index, file, .failure(CocoaError(.fileReadUnknown)), hash) }
                        }
                        return (index, file, .success(.init(source: file.url, stored: stored, hash: hash, bytes: bytes, kind: file.kind, info: info, av: av)), hash)
                    } catch {
                        return (index, file, .failure(error), nil)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { add() }
            while let (index, file, result, hash) = await group.next() {
                done += 1
                progress(done, files.count)
                results[index] = (file, result, hash)
                add()
            }
        }
        // Decide duplicates in scan order, so the first file of identical ones is the one kept.
        var seen = known
        for case let (file, result, hash)? in results {
            switch result {
            case .success(let item?):
                if seen.contains(item.hash) {
                    outcome.duplicates.append((file.url, item.hash))
                } else {
                    seen.insert(item.hash)
                    outcome.imported.append(item)
                }
            case .success(nil):
                outcome.duplicates.append((file.url, hash ?? ""))
            case .failure(let error):
                let code = (error as? CocoaError)?.code
                let reason = code == .fileReadCorruptFile ? "Not a readable image"
                    : code == .fileReadUnknown ? "Not a playable \(file.kind == .audio ? "audio" : "video") file" : error.localizedDescription
                outcome.failed.append(SkippedFile(url: file.url, reason: reason))
            }
        }
        outcome.imported.sort { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }
        return outcome
    }
}

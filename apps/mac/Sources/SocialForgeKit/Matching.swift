import Foundation

/// Which CSV columns hold which post fields. `nil` means "not mapped".
public struct ColumnMapping: Sendable, Equatable, Codable {
    public var file: String?
    public var sku: String?
    public var assetID: String?
    public var url: String?
    public var title: String?
    public var description: String?
    public var altText: String?

    public init(file: String? = nil, sku: String? = nil, assetID: String? = nil, url: String? = nil,
                title: String? = nil, description: String? = nil, altText: String? = nil) {
        self.file = file; self.sku = sku; self.assetID = assetID; self.url = url
        self.title = title; self.description = description; self.altText = altText
    }

    /// Guesses the mapping from common header names. People can change it.
    public static func guess(from header: [String]) -> ColumnMapping {
        func find(_ names: [String]) -> String? {
            header.first { h in names.contains(Self.normalize(h)) }
        }
        return ColumnMapping(
            file: find(["filename", "file", "image", "imagefile", "asset", "assetfilename", "photo"]),
            sku: find(["sku", "productid", "itemid", "handle"]),
            assetID: find(["assetid", "mediaid", "id"]),
            url: find(["url", "link", "destinationurl", "producturl", "destination"]),
            title: find(["title", "name", "productname", "pintitle", "headline"]),
            description: find(["description", "desc", "caption", "pindescription", "body"]),
            altText: find(["alttext", "alt", "altdescription"])
        )
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// How to pair media with CSV rows.
public enum MatchStrategy: String, Sendable, CaseIterable, Codable {
    /// Filename (case and extension ignored), then SKU contained in the filename.
    case filename
    /// The asset id column equals the media id.
    case assetID
    /// Row N goes with media N in the given order. Only used when the person confirms the order.
    case rowOrder
}

public struct MatchCandidate: Sendable, Hashable {
    public let id: String
    public let filename: String
    public init(id: String, filename: String) { self.id = id; self.filename = filename }
}

public struct MatchedRow: Sendable, Equatable {
    public let mediaID: String
    public let rowIndex: Int
    public let url: String
    public let title: String
    public let description: String
    public let altText: String
}

public struct MatchReport: Sendable, Equatable {
    public var matched: [MatchedRow] = []
    /// Media with no row.
    public var unmatchedMedia: [String] = []
    /// Row indexes with no media.
    public var unmatchedRows: [Int] = []
    /// Media that more than one row could belong to. Left unmatched on purpose.
    public var ambiguous: [String: [Int]] = [:]
    /// Problems in matched rows, such as an invalid URL. Keyed by media id.
    public var rowWarnings: [String: [String]] = [:]

    public var summary: String {
        var parts = ["\(matched.count) matched"]
        if !unmatchedMedia.isEmpty { parts.append("\(unmatchedMedia.count) images without a row") }
        if !unmatchedRows.isEmpty { parts.append("\(unmatchedRows.count) rows without an image") }
        if !ambiguous.isEmpty { parts.append("\(ambiguous.count) ambiguous") }
        return parts.joined(separator: " · ")
    }
}

public enum MetadataMatcher {
    public static func match(media: [MatchCandidate], table: CSVTable, mapping: ColumnMapping,
                             strategy: MatchStrategy) -> MatchReport {
        var report = MatchReport()
        var rowsForMedia: [String: [Int]] = [:]

        switch strategy {
        case .rowOrder:
            for (i, m) in media.enumerated() where i < table.rows.count {
                rowsForMedia[m.id] = [i]
            }
        case .assetID:
            for (r, row) in table.rows.enumerated() {
                let key = table.value(row, mapping.assetID)
                guard !key.isEmpty else { continue }
                for m in media where m.id.caseInsensitiveCompare(key) == .orderedSame {
                    rowsForMedia[m.id, default: []].append(r)
                }
            }
        case .filename:
            let stems = Dictionary(grouping: media, by: { stem($0.filename) })
            for (r, row) in table.rows.enumerated() {
                let fileKey = stem(table.value(row, mapping.file))
                if !fileKey.isEmpty, let hits = stems[fileKey] {
                    for m in hits { rowsForMedia[m.id, default: []].append(r) }
                    continue
                }
                let sku = normalizedToken(table.value(row, mapping.sku))
                guard sku.count >= 3 else { continue }
                for m in media where tokenized(m.filename).contains(sku) {
                    rowsForMedia[m.id, default: []].append(r)
                }
            }
        }

        // A row that two images claim is ambiguous for both.
        var mediaForRow: [Int: [String]] = [:]
        for (m, rows) in rowsForMedia { for r in rows { mediaForRow[r, default: []].append(m) } }

        var usedRows = Set<Int>()
        for m in media {
            let rows = rowsForMedia[m.id] ?? []
            if rows.isEmpty {
                report.unmatchedMedia.append(m.id)
            } else if rows.count > 1 || (mediaForRow[rows[0]]?.count ?? 0) > 1 {
                report.ambiguous[m.id] = rows.sorted()
            } else {
                let r = rows[0]
                usedRows.insert(r)
                let row = table.rows[r]
                let url = table.value(row, mapping.url)
                report.matched.append(MatchedRow(
                    mediaID: m.id, rowIndex: r, url: url,
                    title: table.value(row, mapping.title),
                    description: table.value(row, mapping.description),
                    altText: table.value(row, mapping.altText)))
                if !url.isEmpty, !isWebURL(url) {
                    report.rowWarnings[m.id, default: []].append("Row \(r + 2): “\(url)” is not an http or https link.")
                }
            }
        }
        let ambiguousRows = Set(report.ambiguous.values.flatMap { $0 })
        report.unmatchedRows = table.rows.indices.filter { !usedRows.contains($0) && !ambiguousRows.contains($0) }
        return report
    }

    /// "Mug_Fog.JPG" -> "mug_fog". Folder parts are dropped.
    public static func stem(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let noExt = (base as NSString).deletingPathExtension
        return noExt.lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func normalizedToken(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The filename with separators removed, for SKU containment.
    static func tokenized(_ filename: String) -> String {
        normalizedToken(stem(filename))
    }

    public static func isWebURL(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else { return false }
        return scheme == "https" || scheme == "http"
    }
}

import Foundation
import Testing
@testable import SocialForgeKit

@Suite("Sample CSV for a folder of images with links")
struct SampleCSVTests {
    @Test func everyColumnIsRecognized() throws {
        let table = try CSVTable.parse(SampleCSV.text)
        #expect(table.rows.count == 3)
        let m = ColumnMapping.guess(from: table.header)
        #expect(m.file == "filename")
        #expect(m.url == "url")
        #expect(m.title == "title")
        #expect(m.description == "description")
        #expect(m.altText == "alt_text")
    }

    @Test func rowsMatchImagesByFilenameWithAnyExtension() throws {
        let table = try CSVTable.parse(SampleCSV.text)
        let media = [MatchCandidate(id: "a", filename: "Walnut-Cutting-Board.JPEG"),
                     MatchCandidate(id: "b", filename: "linen-apron.png"),
                     MatchCandidate(id: "c", filename: "ceramic-mug.png")]
        let report = MetadataMatcher.match(media: media, table: table, mapping: .guess(from: table.header), strategy: .filename)
        #expect(report.matched.count == 3)
        #expect(report.rowWarnings.isEmpty)
        #expect(report.matched.first { $0.mediaID == "a" }?.url == "https://example.com/products/walnut-cutting-board")
    }

    @Test func theRepositoryCopyMatches() throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../docs/samples/\(SampleCSV.filename)").standardized
        #expect(try String(contentsOf: repo, encoding: .utf8) == SampleCSV.text, "Copy SampleCSV.text to docs/samples/media-links.csv")
    }
}

import Foundation

/// RFC 4180 CSV: quoted fields may hold commas, quotes ("") and newlines.
/// Accepts LF and CRLF line ends and a UTF-8 byte-order mark.
public struct CSVTable: Sendable, Equatable {
    public var header: [String]
    public var rows: [[String]]

    public init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    public enum ParseError: Error, Equatable {
        case empty
        case unterminatedQuote(line: Int)
    }

    public static func parse(_ text: String) throws(ParseError) -> CSVTable {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        var fieldStartedQuoted = false
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    if c == "\n" { line += 1 }
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty && !fieldStartedQuoted:
                    inQuotes = true
                    fieldStartedQuoted = true
                case ",":
                    record.append(field)
                    field = ""
                    fieldStartedQuoted = false
                case "\r":
                    break
                case "\n":
                    record.append(field)
                    records.append(record)
                    record = []
                    field = ""
                    fieldStartedQuoted = false
                    line += 1
                default:
                    field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if inQuotes { throw .unterminatedQuote(line: line) }
        if !field.isEmpty || !record.isEmpty || fieldStartedQuoted {
            record.append(field)
            records.append(record)
        }
        // Drop blank lines.
        records.removeAll { $0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = records.first else { throw .empty }
        let width = header.count
        let rows = records.dropFirst().map { row -> [String] in
            row.count >= width ? row : row + Array(repeating: "", count: width - row.count)
        }
        return CSVTable(header: header.map { $0.trimmingCharacters(in: .whitespaces) }, rows: Array(rows))
    }

    /// The value in `column` for `row`, or "" when the column is missing.
    public func value(_ row: [String], _ column: String?) -> String {
        guard let column, let index = header.firstIndex(of: column), index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

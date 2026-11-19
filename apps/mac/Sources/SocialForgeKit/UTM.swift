import Foundation

/// Campaign tags on outgoing links.
public enum UTM {
    /// Characters left as they are inside a query value. Everything else, including & = + # ?, is percent-encoded.
    static let valueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Adds utm_source, utm_medium, utm_campaign, and (when given) utm_content.
    /// Keeps the other query items and the fragment, drops any utm_* already
    /// there, and skips empty values. Returns the input unchanged unless it is an http(s) URL.
    public static func apply(to url: String, source: String, medium: String, campaign: String, content: String? = nil) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", comps.host?.isEmpty == false else { return url }

        var items = (comps.percentEncodedQueryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") }
        for (name, value) in [("utm_source", source), ("utm_medium", medium), ("utm_campaign", campaign), ("utm_content", content ?? "")] {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            items.append(URLQueryItem(name: name, value: v.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? v))
        }
        comps.percentEncodedQueryItems = items.isEmpty ? nil : items
        return comps.string ?? url
    }
}

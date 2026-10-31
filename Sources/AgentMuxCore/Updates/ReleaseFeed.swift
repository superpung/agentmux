import Foundation

/// A version as AgentMux tags its releases: "v0.3.0" or "0.3.0". Pre-release
/// tags ("0.4.0-beta.1") are not versions here, so they are never offered.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.hasPrefix("v") ? trimmed.dropFirst() : Substring(trimmed)
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1 ... 4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0 ..< max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// One release from the repository's release feed.
public struct ReleaseEntry: Equatable, Sendable {
    public var version: ReleaseVersion
    public var url: URL
    /// The lead phrases of the release's changelog items ("Launch page").
    public var highlights: [String]
}

/// The repository's Atom feed of releases (github.com, not its API, whose
/// unauthenticated limit is shared by everyone behind the same address).
public enum ReleaseFeed {
    public static let url = URL(string: "https://github.com/superpung/agentmux/releases.atom")!

    /// The highest version in the feed.
    public static func latest(in data: Data) -> ReleaseEntry? {
        entries(in: data).max { $0.version < $1.version }
    }

    public static func entries(in data: Data) -> [ReleaseEntry] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries.compactMap { raw in
            guard let version = ReleaseVersion(raw.title), let url = URL(string: raw.link) else { return nil }
            return ReleaseEntry(version: version, url: url, highlights: highlights(html: raw.content))
        }
    }

    /// The bold lead of each changelog item: the notes render
    /// `- **Launch page.** Every past…` as `<li><strong>Launch page.</strong>`.
    public static func highlights(html: String, limit: Int = 3) -> [String] {
        let pattern = /<li>\s*<strong>([^<]+)<\/strong>/
        return html.matches(of: pattern).prefix(limit).map { match in
            var lead = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if lead.hasSuffix(".") || lead.hasSuffix(":") { lead.removeLast() }
            return unescaped(lead)
        }
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private final class FeedReader: NSObject, XMLParserDelegate {
    struct Raw { var title = ""; var link = ""; var content = "" }

    var entries: [Raw] = []
    private var current: Raw?
    private var field: String?

    func parser(_: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName _: String?,
                attributes: [String: String]) {
        switch name {
        case "entry": current = Raw()
        case "title", "content": field = current == nil ? nil : name
        case "link":
            if current != nil, attributes["rel"] ?? "alternate" == "alternate" { current?.link = attributes["href"] ?? "" }
        default: break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        switch field {
        case "title": current?.title += string
        case "content": current?.content += string
        default: break
        }
    }

    func parser(_: XMLParser, didEndElement name: String, namespaceURI _: String?, qualifiedName _: String?) {
        switch name {
        case "entry":
            if let current { entries.append(current) }
            current = nil
        case "title", "content": field = nil
        default: break
        }
    }
}

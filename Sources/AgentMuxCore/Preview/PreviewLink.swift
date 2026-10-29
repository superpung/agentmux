import Foundation

/// Where a link in a previewed file leads. A path resolves against the
/// previewed file's folder, in the same container; only web pages and mail
/// addresses leave the app, and no other scheme is followed.
public enum PreviewLink: Sendable, Equatable {
    /// An http(s) page or a mail address, for the Mac's default app.
    case web(URL)
    /// A place in the previewed file itself; empty for its top.
    case anchor(String)
    /// A file in the container, and the place in it to show, if any.
    case file(String, anchor: String?)
    /// A folder in the container (the link ends in `/`).
    case folder(String)
    /// Another scheme, a data URI, or nothing at all.
    case unsupported

    /// Resolves a link's target (`href`, possibly percent-encoded) in the
    /// file at `document`.
    public static func resolve(_ href: String, from document: String) -> PreviewLink {
        let link = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .unsupported }
        var rest = Substring(link)
        if let scheme = scheme(of: link) {
            switch scheme {
            case "http", "https", "mailto":
                return URL(string: link, encodingInvalidCharacters: true).map(PreviewLink.web) ?? .unsupported
            case "file":
                rest = rest.dropFirst("file:".count)
                if rest.hasPrefix("//") {
                    rest = rest.dropFirst(2)
                    let host = rest.prefix { $0 != "/" }
                    guard host.isEmpty || host == "localhost" else { return .unsupported }
                    rest = rest.dropFirst(host.count)
                }
            default:
                return .unsupported
            }
        }
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = decode(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let query = rest.firstIndex(of: "?") { rest = rest[..<query] }
        let raw = decode(rest)
        if raw.isEmpty { return .anchor(fragment ?? "") }

        let base = raw.hasPrefix("/") ? raw : (document as NSString).deletingLastPathComponent + "/" + raw
        let path = normalize(base)
        let last = raw.split(separator: "/").last
        if raw.hasSuffix("/") || last == "." || last == ".." { return .folder(path) }
        if path == normalize(document) { return .anchor(fragment ?? "") }
        return .file(path, anchor: fragment?.isEmpty == false ? fragment : nil)
    }

    /// GitHub's anchor for a heading's text: lower case, spaces as hyphens,
    /// punctuation and symbols dropped (letters of any script stay).
    public static func slug(_ text: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation:
                slug.append(scalar)
            default:
                if scalar == " " { slug.append("-") } else if scalar == "-" { slug.append(scalar) }
            }
        }
        return String(slug)
    }

    /// The lines a GitHub line link names (`L12`, `L12-L20`), first line 1.
    public static func lines(_ anchor: String) -> ClosedRange<Int>? {
        guard let match = anchor.wholeMatch(of: #/[Ll]([0-9]{1,9})(?:-[Ll]?([0-9]{1,9}))?/#),
              let first = Int(match.1), first > 0 else { return nil }
        let last = match.2.flatMap { Int($0) } ?? first
        return min(first, last)...max(first, last)
    }

    /// The scheme a link starts with (lower case), if it has one.
    static func scheme(of link: String) -> String? {
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let scheme = link[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    /// An absolute path with `.`, `..` and repeated slashes resolved.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func decode(_ text: Substring) -> String {
        String(text).removingPercentEncoding ?? String(text)
    }
}

/// Unique heading anchors for one document, the way GitHub numbers repeats:
/// `usage`, `usage-1`, `usage-2`.
public struct HeadingSlugger: Sendable {
    private var counts: [String: Int] = [:]

    public init() {}

    public mutating func slug(_ text: String) -> String {
        let base = PreviewLink.slug(text)
        var slug = base
        while counts[slug] != nil {
            counts[base, default: 0] += 1
            slug = "\(base)-\(counts[base] ?? 0)"
        }
        counts[slug] = 0
        return slug
    }
}

/// Back and forward lists for a view that shows one item at a time.
public struct BrowseHistory<Item: Equatable & Sendable>: Sendable {
    public private(set) var back: [Item] = []
    public private(set) var forward: [Item] = []
    private let limit: Int
    /// The last move was a `leave` that put an item on the back list.
    private var justLeft = false

    public init(limit: Int = 100) {
        self.limit = limit
    }

    /// Moving on from `current` to another item: Back returns to it, and
    /// what was ahead is dropped.
    public mutating func leave(_ current: Item?) {
        forward.removeAll()
        justLeft = current != nil
        guard let current else { return }
        back.append(current)
        if back.count > limit { back.removeFirst(back.count - limit) }
    }

    public mutating func goBack(from current: Item?) -> Item? {
        justLeft = false
        guard let item = back.popLast() else { return nil }
        if let current { forward.append(current) }
        return item
    }

    public mutating func goForward(from current: Item?) -> Item? {
        justLeft = false
        guard let item = forward.popLast() else { return nil }
        if let current { back.append(current) }
        return item
    }

    /// Takes back the last move, if it was a `leave`, for a step that led
    /// nowhere: the item left (nil if none), to show again with no way
    /// forward to the dead end.
    public mutating func retract() -> Item? {
        guard justLeft else { return nil }
        justLeft = false
        return back.popLast()
    }
}

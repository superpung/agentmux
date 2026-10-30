import Foundation

/// Markdown made ready for a preview's parser (Foundation's).
public enum MarkdownSource {
    /// `[![alt](image)](link)`, a badge, as `<a href="link"><img src="image"
    /// alt="alt"></a>`: Foundation's parser drops an image inside a link,
    /// while the renderer reads the HTML. Code spans and fenced code blocks
    /// are left as written.
    public static func unnestingLinkedImages(_ source: String) -> String {
        guard source.contains("[![") else { return source }
        var fence: (char: Character, length: Int)?
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if let open = fence, first == open.char, run >= open.length,
                   trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                    fence = nil
                    lines.append(String(line))
                    continue
                }
                if fence == nil, run >= 3, !(first == "`" && trimmed.dropFirst(run).contains("`")) {
                    fence = (first, run)
                    lines.append(String(line))
                    continue
                }
            }
            lines.append(fence == nil ? outsideCodeSpans(String(line), rewrite) : String(line))
        }
        return lines.joined(separator: "\n")
    }

    private static var linkedImage: Regex<(Substring, Substring, Substring, Substring)> {
        #/\[!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/#
    }

    private static func rewrite(_ text: Substring) -> String {
        String(text.replacing(linkedImage) { match in
            "<a href=\"\(escape(match.3))\"><img src=\"\(escape(match.2))\" alt=\"\(escape(match.1))\"></a>"
        })
    }

    /// Applies `transform` to the parts of `line` outside backtick code spans.
    private static func outsideCodeSpans(_ line: String, _ transform: (Substring) -> String) -> String {
        guard line.contains("`") else { return transform(line[...]) }
        var out = ""
        var rest = line[...]
        while let tick = rest.firstIndex(of: "`") {
            out += transform(rest[..<tick])
            let run = rest[tick...].prefix { $0 == "`" }
            let after = rest[run.endIndex...]
            // The span ends at the next run of exactly as many backticks.
            var search = after.startIndex
            var close: Range<Substring.Index>?
            while let next = after[search...].firstIndex(of: "`") {
                let candidate = after[next...].prefix { $0 == "`" }
                if candidate.count == run.count { close = candidate.startIndex..<candidate.endIndex; break }
                search = candidate.endIndex
            }
            guard let close else {
                out += run + transform(after)
                return out
            }
            out += rest[tick..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return out + transform(rest)
    }

    static func escape(_ text: some StringProtocol) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The pictures of an HTML page shown in a preview, which loads nothing
/// itself: each `<img>` gets its picture as a `data:` URI.
public enum HTMLImages {
    private static var image: Regex<Substring> { #/<img\b[^>]*>/#.ignoresCase() }
    private static var source: Regex<(Substring, Substring?, Substring?, Substring?)> {
        #/\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#.ignoresCase()
    }
    private static var sourceSet: Regex<Substring> { #/\s+srcset\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)/#.ignoresCase() }

    /// The `src` of each `<img>`, in order, once each, `data:` URIs left out.
    public static func sources(in html: String) -> [String] {
        var seen = Set<String>()
        return html.matches(of: image).compactMap { tag -> String? in
            guard let src = sourceValue(tag.output[...]), !src.lowercased().hasPrefix("data:"), seen.insert(src).inserted
            else { return nil }
            return src
        }
    }

    /// `html` with each `<img>` whose source is in `images` showing it as a
    /// `data:` URI (and its `srcset`, which a page would prefer, dropped).
    public static func inlining(_ images: [String: Data], in html: String) -> String {
        guard !images.isEmpty else { return html }
        return html.replacing(image) { match -> String in
            let tag = String(match.output)
            guard let src = sourceValue(tag[...]), let data = images[src] else { return tag }
            let uri = "data:\(ImageMIME.of(data));base64,\(data.base64EncodedString())"
            return tag.replacing(sourceSet, with: "").replacing(source, maxReplacements: 1) { _ in "src=\"\(uri)\"" }
        }
    }

    private static func sourceValue(_ tag: Substring) -> String? {
        guard let match = tag.firstMatch(of: source) else { return nil }
        let value = String(match.1 ?? match.2 ?? match.3 ?? "")
        return value.isEmpty ? nil : value.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The media type of image bytes, by their signature.
public enum ImageMIME {
    public static func of(_ data: Data) -> String {
        let head = [UInt8](data.prefix(32))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF8".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("BM".utf8)) { return "image/bmp" }
        if starts([0, 0, 1, 0]) { return "image/x-icon" }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = String(decoding: head.dropFirst(8).prefix(4), as: UTF8.self)
            return brand.hasPrefix("avi") ? "image/avif" : "image/heic"
        }
        let text = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        if text.contains("<svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

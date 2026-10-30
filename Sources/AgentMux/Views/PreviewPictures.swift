import AgentMuxCore
import AppKit
import SwiftUI

// MARK: - Pictures in previews
//
// A rendered Markdown file (or notebook) shows its pictures: the renderer
// puts a placeholder (an icon and the alt text) where each one goes, marked
// with `.previewImage`; the text view then fetches them all at once (the
// container's files in one read, web images over the network) and swaps
// each placeholder for its picture, keeping the part on screen in place. An
// HTML page gets its pictures inlined as `data:` URIs, so it still loads
// nothing itself.

extension NSAttributedString.Key {
    /// A placeholder for a picture still to fetch (a `PreviewImageRef`).
    static let previewImage = NSAttributedString.Key("AgentMuxPreviewImage")
}

/// A picture to fetch: its source as written, and the size the document
/// asks for (`<img width height>`), if any.
final class PreviewImageRef: NSObject, @unchecked Sendable {
    let source: String
    let width: CGFloat?
    let height: CGFloat?

    init(source: String, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.source = source
        self.width = width
        self.height = height
    }
}

/// A picture in preview text: its own size (or the size the document asks
/// for), at most `maxWidth` wide, and never wider than the line it sits on,
/// so it shrinks with a narrow pane, a quote or a table cell. A click on it
/// is a click on its link. An attachment rather than a cell, so the renderer
/// can make one off the main thread.
final class PreviewImageAttachment: NSTextAttachment {
    static let maxWidth: CGFloat = 640
    private var size = NSSize.zero

    /// `image` at the size the document asks for, if it does.
    static func make(_ image: NSImage, width: CGFloat? = nil, height: CGFloat? = nil) -> PreviewImageAttachment? {
        var size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        switch (width, height) {
        case let (w?, h?): size = NSSize(width: w, height: h)
        case let (w?, nil): size = NSSize(width: w, height: size.height * w / size.width)
        case let (nil, h?): size = NSSize(width: size.width * h / size.height, height: h)
        case (nil, nil): break
        }
        if size.width > maxWidth { size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width) }
        let attachment = PreviewImageAttachment()
        attachment.image = image
        attachment.size = size
        return attachment
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let room = max(24, lineFrag.width - position.x - (textContainer?.lineFragmentPadding ?? 0) * 2)
        let scale = min(1, room / size.width)
        return CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }
}

/// Fetches the pictures a preview refers to, keyed by source as written,
/// handing each batch over as it arrives.
struct PreviewImages {
    let fetch: @MainActor (_ sources: [String], _ deliver: @MainActor ([String: Data]) -> Void) async -> Void

    /// Everything, once all has arrived.
    @MainActor func all(_ sources: [String]) async -> [String: Data] {
        var out: [String: Data] = [:]
        await fetch(sources) { out.merge($0) { first, _ in first } }
        return out
    }

    /// For the file at `document` in `target`: relative and absolute paths
    /// are files in the container, read in one session (read-only, up to
    /// `RemoteFileService.imageByteCap` each); http(s) sources are fetched
    /// from the web, each delivered as it arrives. Anything else is left out.
    static func remote(document: String, host: HostConfig, target: TargetConfig) -> PreviewImages {
        PreviewImages { sources, deliver in
            var files: [String: [String]] = [:]
            var web: [String: URL] = [:]
            for source in sources {
                switch PreviewLink.resolve(source, from: document) {
                case let .file(path, _): files[path, default: []].append(source)
                case let .web(url) where ["http", "https"].contains(url.scheme?.lowercased() ?? ""): web[source] = url
                default: break
                }
            }
            let byPath = files
            await withTaskGroup(of: [String: Data].self) { group in
                group.addTask {
                    var out: [String: Data] = [:]
                    for (path, data) in await RemoteFileService.readImages(Array(byPath.keys), host: host, target: target) {
                        for source in byPath[path] ?? [] { out[source] = data }
                    }
                    return out
                }
                for (source, url) in web.prefix(RemoteFileService.imageBatchCount) {
                    group.addTask { await WebImages.download(url).map { [source: $0] } ?? [:] }
                }
                for await batch in group where !batch.isEmpty {
                    deliver(batch)
                }
            }
        }
    }
}

private struct PreviewImagesKey: EnvironmentKey {
    static var defaultValue: PreviewImages? { nil }
}

extension EnvironmentValues {
    var previewImages: PreviewImages? {
        get { self[PreviewImagesKey.self] }
        set { self[PreviewImagesKey.self] = newValue }
    }
}

/// Web images for a preview: no cookies or cache kept, through the system's
/// proxy settings, each at most `RemoteFileService.imageByteCap`.
enum WebImages {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func download(_ url: URL) async -> Data? {
        let cap = RemoteFileService.imageByteCap
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(cap) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}

extension PreviewTextView {
    /// The sources of the pictures still to fetch, once each.
    var pendingImageSources: [String] {
        guard let storage = textStorage else { return [] }
        var sources: [String] = []
        storage.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let ref = value as? PreviewImageRef, !sources.contains(ref.source) { sources.append(ref.source) }
        }
        return sources
    }

    /// Swaps each placeholder whose picture arrived for the picture, keeping
    /// what is at the top of the view where it is. A picture that can't be
    /// decoded keeps its placeholder.
    func placeImages(_ fetched: [String: Data]) {
        guard let storage = textStorage else { return }
        let places = Self.places(for: fetched, in: storage)
        guard !places.isEmpty else { return }
        keepingTop(edits: places.map { ($0.range, 1) }) {
            Self.apply(places, to: storage)
        }
    }

    /// `text` with the pictures in `fetched` already in place, for a newer
    /// version of a text whose pictures arrived before.
    static func withImages(_ fetched: [String: Data], in text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        apply(places(for: fetched, in: copy), to: copy)
        return copy
    }

    private static func places(for fetched: [String: Data], in text: NSAttributedString) -> [(range: NSRange, attachment: NSTextAttachment)] {
        var decoded: [String: NSImage] = [:]
        var places: [(range: NSRange, attachment: NSTextAttachment)] = []
        text.enumerateAttribute(.previewImage, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let ref = value as? PreviewImageRef, let data = fetched[ref.source] else { return }
            if decoded[ref.source] == nil { decoded[ref.source] = NSImage(data: data) }
            guard let image = decoded[ref.source],
                  let attachment = PreviewImageAttachment.make(image, width: ref.width, height: ref.height) else { return }
            places.append((range, attachment))
        }
        return places
    }

    private static func apply(_ places: [(range: NSRange, attachment: NSTextAttachment)], to text: NSMutableAttributedString) {
        text.beginEditing()
        for place in places.reversed() {
            // The placeholder's paragraph style, font and link carry over.
            var attributes = text.attributes(at: place.range.location, effectiveRange: nil)
            attributes[.previewImage] = nil
            attributes[.attachment] = place.attachment
            text.replaceCharacters(in: place.range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
        text.endEditing()
    }

    /// Runs `body`, which replaces `edits` (each range by text of a new
    /// length), and scrolls back so the line that was at the top stays there.
    private func keepingTop(edits: [(range: NSRange, length: Int)], _ body: () -> Void) {
        guard let storage = textStorage, let layoutManager, let textContainer,
              let clip = enclosingScrollView?.contentView, clip.bounds.minY > 0, storage.length > 0 else {
            body()
            return
        }
        let y = clip.bounds.minY - textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: textContainer)
        var char = layoutManager.characterIndexForGlyph(at: glyph)
        let offset = y - layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        body()
        for edit in edits where edit.range.location < char {
            char = NSMaxRange(edit.range) <= char ? char - edit.range.length + edit.length : edit.range.location
        }
        char = min(max(0, char), storage.length - 1)
        // Lay out a screenful below as well, so the view is tall enough to
        // scroll there (as `scrollTo` does).
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, char + 20_000)))
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: char), effectiveRange: nil)
        let top = NSPoint(x: clip.bounds.minX, y: line.minY + offset + textContainerOrigin.y)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: top, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// An HTML page with its pictures: shown at once, then again with them
/// inlined as `data:` URIs once they arrive.
struct WebPreviewWithImages: View {
    let html: String
    @Environment(\.previewImages) private var images
    @State private var inlined: (html: String, page: String)?

    var body: some View {
        WebPreview(html: inlined.flatMap { $0.html == html ? $0.page : nil } ?? html)
            .task(id: html) {
                let sources = HTMLImages.sources(in: html)
                guard let images, !sources.isEmpty else { return }
                let fetched = await images.all(sources)
                guard !Task.isCancelled, !fetched.isEmpty else { return }
                inlined = (html, HTMLImages.inlining(fetched, in: html))
            }
    }
}

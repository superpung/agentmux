import AgentMuxCore
import AppKit
import AVKit
import QuickLookUI
import SwiftUI
import WebKit

// MARK: - Local copies

/// A previewed remote file copied to the Mac, for viewers that read a file
/// (Quick Look, the player). Each copy has its own folder under the temporary
/// directory, removed when the preview goes; leftovers of an earlier run go on
/// first use.
@MainActor
final class PreviewFile {
    let url: URL

    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentMuxPreview", isDirectory: true)
    private static var cleared = false

    init?(_ data: Data, name: String) {
        if !Self.cleared {
            Self.cleared = true
            try? FileManager.default.removeItem(at: Self.folder)
        }
        let directory = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent(name.isEmpty ? "preview" : name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return nil
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// A document shown by Quick Look, as in Finder: Office and iWork files.
/// A PowerPoint deck goes without its speaker notes pages, which the slides
/// don't show and on which macOS's previewer can stall for good.
struct QuickLookPreview: NSViewRepresentable {
    let data: Data
    let name: String

    private static let decks: Set<String> = ["pptx", "pptm", "ppsx", "potx"]

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        // Closed once, when SwiftUI removes it. Left to close with its window
        // as well, closing the Files window closed it first, and the second
        // close failed Quick Look's assertion and aborted the app.
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        context.coordinator.file?.remove()
        let isDeck = Self.decks.contains((name as NSString).pathExtension.lowercased())
        let copy = isDeck ? PresentationPackage.withoutSpeakerNotes(data) ?? data : data
        context.coordinator.file = PreviewFile(copy, name: name)
        view.previewItem = context.coordinator.file?.url as NSURL?
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.file?.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var data: Data?
        var file: PreviewFile?
    }
}

/// Audio or video in the system player.
struct MediaPreview: NSViewRepresentable {
    let data: Data
    let name: String

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.player?.pause()
        context.coordinator.file?.remove()
        context.coordinator.file = PreviewFile(data, name: name)
        view.player = context.coordinator.file.map { AVPlayer(url: $0.url) }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.file?.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var data: Data?
        var file: PreviewFile?
    }
}

// MARK: - Documents as text

/// Documents as searchable text for a preview text view. Safe off the main
/// thread.
enum DocumentText {
    /// A Word, OpenDocument or RTF document as AppKit reads it, tables
    /// included. Text and rules left black, and white fills, take the
    /// appearance's colors, so the text reads in dark mode too.
    static func rich(_ data: Data, type: NSAttributedString.DocumentType) -> NSAttributedString {
        guard let text = try? NSMutableAttributedString(data: data, options: [.documentType: type], documentAttributes: nil),
              text.length > 0 else { return note("No text") }
        let all = NSRange(location: 0, length: text.length)
        var plain: [NSRange] = []
        text.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            if (value as? NSColor).map(isInk) ?? true { plain.append(range) }
        }
        for range in plain { text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        var fills: [NSRange] = []
        text.enumerateAttribute(.backgroundColor, in: all) { value, range, _ in
            if let color = value as? NSColor, isPaper(color) { fills.append(range) }
        }
        for range in fills { text.removeAttribute(.backgroundColor, range: range) }
        var blocks = Set<ObjectIdentifier>()
        text.enumerateAttribute(.paragraphStyle, in: all) { value, _, _ in
            for block in (value as? NSParagraphStyle)?.textBlocks ?? [] where blocks.insert(ObjectIdentifier(block)).inserted {
                for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] where block.borderColor(for: edge).map(isInk) ?? false {
                    block.setBorderColor(.tertiaryLabelColor, for: edge)
                }
                if let fill = block.backgroundColor, isPaper(fill) { block.backgroundColor = nil }
            }
        }
        return text
    }

    /// Near-black and grey: the color of plain text and rules.
    private static func isInk(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.saturationComponent < 0.2 && rgb.brightnessComponent < 0.35
    }

    private static func isPaper(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.saturationComponent < 0.1 && rgb.brightnessComponent > 0.92
    }

    /// An Excel workbook's sheets, each a titled table.
    static func spreadsheet(_ data: Data) -> NSAttributedString {
        guard let book = Spreadsheet(xlsx: data), !book.sheets.isEmpty else { return note("No sheets") }
        let out = NSMutableAttributedString()
        for (index, sheet) in book.sheets.enumerated() {
            let title = NSMutableParagraphStyle()
            title.paragraphSpacingBefore = index == 0 ? 0 : 20
            title.paragraphSpacing = 6
            out.append(NSAttributedString(string: sheet.name + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: title,
                .previewAnchor: PreviewLink.slug(sheet.name),
            ]))
            if sheet.rows.isEmpty {
                out.append(note("Empty sheet"))
            } else {
                out.append(DelimitedTextRenderer.render(rows: sheet.rows))
            }
            if sheet.moreRows > 0 {
                out.append(NSAttributedString(string: "\n"))
                out.append(note("\(sheet.moreRows.formatted()) more rows"))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    /// A PowerPoint deck's text, slide by slide: number, title, body by
    /// outline level, and notes.
    static func presentation(_ data: Data) -> NSAttributedString {
        guard let deck = Presentation(pptx: data), !deck.slides.isEmpty else { return note("No slides") }
        let out = NSMutableAttributedString()
        func line(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                  indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 4, anchor: String? = nil) {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineSpacing = 2
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
            ]
            if let anchor { attributes[.previewAnchor] = anchor }
            out.append(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: attributes))
        }
        for (index, slide) in deck.slides.enumerated() {
            line("\(index + 1)", size: 11, weight: .semibold, color: .secondaryLabelColor,
                 before: index == 0 ? 0 : 22, after: 2, anchor: "slide-\(index + 1)")
            if let title = slide.title { line(title, size: 17, weight: .semibold, after: 8) }
            for paragraph in slide.paragraphs {
                line(paragraph.text, size: 13, indent: CGFloat(paragraph.level) * 18)
            }
            if !slide.notes.isEmpty {
                line("Notes", size: 11, weight: .semibold, color: .secondaryLabelColor, before: 8, after: 2)
                for note in slide.notes { line(note, size: 12, color: .secondaryLabelColor) }
            }
        }
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// An archive's entries as a table: size, date, path.
    static func archive(_ entries: [ArchiveEntry]) -> NSAttributedString {
        guard !entries.isEmpty else { return note("Empty archive") }
        let rows = [["Size", "Modified", "Name"]] + entries.map { entry in
            [entry.name.hasSuffix("/") ? "" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file),
             entry.modified, entry.name]
        }
        return DelimitedTextRenderer.render(rows: rows)
    }

    /// A binary file's first bytes as `hexdump -C` prints them.
    static func hex(_ data: Data) -> NSAttributedString {
        NSAttributedString(string: HexDump.format(data), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// A notebook as Markdown, rendered; the JSON as it is if it doesn't read.
    static func notebook(_ json: String) -> NSAttributedString {
        guard let markdown = Notebook.markdown(json) else {
            return NSAttributedString(string: json, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor,
            ])
        }
        return MarkdownRenderer.render(markdown)
    }

    private static func note(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}

// MARK: - Web pages

/// HTML (or an SVG in a page) in a web view that runs no script and loads
/// nothing beyond the page: a content security policy blocks every other
/// request. A link goes to the window; a `#place` in the page scrolls there.
struct WebPreview: NSViewRepresentable {
    let html: String
    /// A transparent page (an SVG); otherwise white, as a browser shows it.
    var transparent = false
    @Environment(\.previewLinks) private var links

    /// Relative links resolve against the previewed path under this scheme,
    /// which nothing serves.
    private static let scheme = "agentmux-preview"
    private static let policy = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' data:; img-src data:; font-src data:">
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if transparent { web.setValue(false, forKey: "drawsBackground") }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.links = links
        let path = links?.path ?? "/"
        guard context.coordinator.html != html || context.coordinator.path != path else { return }
        context.coordinator.html = html
        context.coordinator.path = path
        context.coordinator.programmaticLoad = true
        var base = URLComponents()
        base.scheme = Self.scheme
        base.host = "file"
        base.path = path
        web.loadHTMLString(Self.policy + html, baseURL: base.url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        var path: String?
        var programmaticLoad = false
        var links: PreviewLinks?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if programmaticLoad {
                programmaticLoad = false
                decisionHandler(.allow)
                return
            }
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            var href = url.absoluteString
            if url.scheme == WebPreview.scheme {
                // A place in this page: let the page scroll there.
                if url.path == path, url.fragment != nil {
                    decisionHandler(.allow)
                    return
                }
                href = url.path(percentEncoded: true) + (url.fragment(percentEncoded: true).map { "#" + $0 } ?? "")
            }
            decisionHandler(.cancel)
            PreviewLinks.follow(PreviewLink.resolve(href, from: links?.path ?? "/"), with: links)
        }
    }
}

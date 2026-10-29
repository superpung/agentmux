import AgentMuxCore
import AppKit
import Foundation

/// Renders Markdown into an attributed string for a preview text view, so a
/// rendered file scrolls like any text and can be searched with the find bar.
/// Parsing is Foundation's (CommonMark plus GitHub tables, strikethrough and
/// autolinks). Quotes, code blocks and tables become NSTextBlocks (a left
/// rule, a tinted box, an NSTextTable), lists become indents. Raw HTML keeps
/// its text, links, anchors and images without the other tags, and an image
/// shows as its alt text, linked to the image file: a preview reads no file
/// other than the one it shows. Headings carry GitHub's anchors, so `#name`
/// links find them. Safe off the main thread.
enum MarkdownRenderer {
    static func render(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor])
        }
        var builder = Builder()
        let leaves = Leaf.split(parsed)
        for (index, leaf) in leaves.enumerated() {
            builder.add(leaf, next: index + 1 < leaves.count ? leaves[index + 1] : nil)
        }
        return builder.finish()
    }

    // MARK: Style

    enum Style {
        static let bodySize: CGFloat = 13
        static var body: NSFont { .systemFont(ofSize: bodySize) }
        static var code: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
        static let headingSizes: [CGFloat] = [22, 18, 15, 13, 13, 12]
        static let indent: CGFloat = 22
        static let paragraphGap: CGFloat = 10
        static let wash = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
        }

        static func heading(_ level: Int) -> NSFont {
            let size = headingSizes[min(max(level, 1), headingSizes.count) - 1]
            return .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
        }

        static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
            guard bold || italic else { return font }
            var traits = font.fontDescriptor.symbolicTraits
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
    }

    // MARK: Leaves

    /// One leaf block (paragraph, heading, code block, table cell, rule or
    /// raw HTML) with its runs and the containers around it, outermost first.
    struct Leaf {
        var kind: PresentationIntent.Kind?
        var identity: Int
        var containers: [PresentationIntent.IntentType]
        var runs: [Run]

        struct Run {
            var text: String
            var inline: InlinePresentationIntent
            var link: URL?
            var image: URL?
        }

        static func split(_ parsed: AttributedString) -> [Leaf] {
            var leaves: [Leaf] = []
            for run in parsed.runs {
                let components = run.presentationIntent?.components ?? []
                let identity = components.first?.identity ?? -1
                let item = Run(text: String(parsed[run.range].characters),
                               inline: run.inlinePresentationIntent ?? [],
                               link: run.link, image: run.imageURL)
                if leaves.last?.identity == identity {
                    leaves[leaves.count - 1].runs.append(item)
                } else {
                    leaves.append(Leaf(kind: components.first?.kind, identity: identity,
                                       containers: Array(components.dropFirst().reversed()), runs: [item]))
                }
            }
            return leaves
        }

        /// The outermost list this leaf sits in.
        var outerList: Int? { containers.first { $0.kind.isList }?.identity }
    }

    // MARK: Builder

    private struct Builder {
        let out = NSMutableAttributedString()
        /// Quote and code blocks by intent identity, so a block's paragraphs
        /// share them (with the indent around them, if any).
        var blocks: [Int: [NSTextBlock]] = [:]
        var markedItems: Set<Int> = []
        var table: TableState?
        var slugger = HeadingSlugger()

        struct TableState {
            let identity: Int
            let table: NSTextTable
            let alignments: [NSTextAlignment]
            let outer: [NSTextBlock]
            var rowIdentity = -1
            var row = -1
            var nextColumn = 0
        }

        mutating func add(_ leaf: Leaf, next: Leaf?) {
            var outer: [NSTextBlock] = []
            var indent: CGFloat = 0
            var listDepth = 0
            var ordered = false
            var item: (identity: Int, ordinal: Int, ordered: Bool)?
            var tableIntent: (identity: Int, columns: [PresentationIntent.TableColumn])?
            var row: (identity: Int, header: Bool)?
            var quoted = false
            for container in leaf.containers {
                switch container.kind {
                case .blockQuote:
                    outer += blocks(container.identity, indent: indent, Self.quoteBlock)
                    indent = 0
                    quoted = true
                case .unorderedList, .orderedList:
                    listDepth += 1
                    indent += Style.indent
                    if case .orderedList = container.kind { ordered = true } else { ordered = false }
                case let .listItem(ordinal):
                    item = (container.identity, ordinal, ordered)
                case let .table(columns):
                    tableIntent = (container.identity, columns)
                case .tableHeaderRow:
                    row = (container.identity, true)
                case .tableRow:
                    row = (container.identity, false)
                default:
                    break
                }
            }

            if let current = table, tableIntent?.identity != current.identity {
                closeRow()
                table = nil
            }

            let inList = listDepth > 0
            let lastInList = inList && next?.outerList != leaf.outerList
            var marker: String?
            if let item, !markedItems.contains(item.identity) {
                markedItems.insert(item.identity)
                marker = item.ordered ? "\(item.ordinal)." : ["•", "◦", "▪"][min(listDepth, 3) - 1]
            }

            switch leaf.kind {
            case let .header(level):
                let style = paragraph(indent: indent, marker: nil)
                style.paragraphSpacingBefore = out.length == 0 ? 0 : (level <= 2 ? 18 : 14)
                style.paragraphSpacing = 8
                var blocks = outer
                if level <= 2 { blocks.append(Self.ruledBlock()) }
                style.textBlocks = blocks
                let color: NSColor = level >= 6 ? .secondaryLabelColor : .labelColor
                let title = NSMutableAttributedString(attributedString: inline(leaf.runs, font: Style.heading(level), color: color))
                let slug = slugger.slug(leaf.runs.filter { !$0.inline.contains(.inlineHTML) }.map(\.text).joined())
                // The heading's own anchor, around any HTML anchor inside it.
                var unnamed: [NSRange] = []
                title.enumerateAttribute(.previewAnchor, in: NSRange(location: 0, length: title.length)) { value, range, _ in
                    if value == nil { unnamed.append(range) }
                }
                for range in unnamed { title.addAttribute(.previewAnchor, value: slug, range: range) }
                append(title, style)

            case .codeBlock:
                var text = leaf.runs.map(\.text).joined()
                if text.hasSuffix("\n") { text.removeLast() }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 1
                style.textBlocks = outer + blocks(leaf.identity, indent: indent, Self.codeBlock)
                append(NSAttributedString(string: text, attributes: [.font: Style.code, .foregroundColor: NSColor.labelColor]), style)

            case .thematicBreak:
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = Style.paragraphGap
                style.textBlocks = outer + Self.indented(indent, Self.ruleBlock())
                append(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)]), style)

            case let .tableCell(column):
                guard let tableIntent, let row else { break }
                cell(leaf, column: column, row: row, table: tableIntent, outer: outer, indent: indent)

            case .paragraph:
                var runs = leaf.runs
                var mark = marker
                if mark != nil, let first = runs.first?.text {
                    // GitHub task list items.
                    for (prefix, box) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where first.hasPrefix(prefix) {
                        runs[0].text.removeFirst(prefix.count)
                        mark = box
                    }
                }
                let style = paragraph(indent: indent, marker: mark)
                style.paragraphSpacing = inList && !lastInList ? 4 : (quoted ? 6 : Style.paragraphGap)
                style.textBlocks = outer
                let body = NSMutableAttributedString()
                if let mark {
                    body.append(NSAttributedString(string: mark + "\t", attributes: [
                        .font: Style.body, .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                body.append(inline(runs, font: Style.body, color: quoted ? .secondaryLabelColor : .labelColor))
                if Self.anchorsOnly(body) {
                    style.paragraphSpacing = 0
                    append(Self.pointHigh(body), style)
                } else {
                    append(body, style)
                }

            case nil:
                // Raw HTML: a paragraph a line.
                let text = Self.html(leaf.runs.map(\.text).joined(), font: Style.body, color: .labelColor)
                for line in Self.lines(of: text) {
                    let style = paragraph(indent: indent, marker: nil)
                    style.textBlocks = outer
                    if Self.anchorsOnly(line) {
                        append(Self.pointHigh(line), style)
                    } else {
                        style.paragraphSpacing = Style.paragraphGap
                        append(line, style)
                    }
                }

            default:
                append(inline(leaf.runs, font: Style.body, color: .labelColor), paragraph(indent: indent, marker: nil))
            }
        }

        mutating func finish() -> NSAttributedString {
            closeRow()
            if out.string.hasSuffix("\n") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            return out
        }

        // MARK: Tables

        private mutating func cell(_ leaf: Leaf, column: Int, row: (identity: Int, header: Bool),
                                   table intent: (identity: Int, columns: [PresentationIntent.TableColumn]),
                                   outer: [NSTextBlock], indent: CGFloat) {
            if table == nil {
                let t = Self.fullWidth(NSTextTable())
                t.numberOfColumns = max(1, intent.columns.count)
                t.collapsesBorders = true
                t.hidesEmptyCells = false
                t.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
                t.setWidth(Style.paragraphGap, type: .absoluteValueType, for: .margin, edge: .maxY)
                let alignments: [NSTextAlignment] = intent.columns.map {
                    switch $0.alignment {
                    case .center: .center
                    case .right: .right
                    default: .natural
                    }
                }
                table = TableState(identity: intent.identity, table: t, alignments: alignments, outer: outer)
            }
            if table?.rowIdentity != row.identity {
                closeRow()
                table?.rowIdentity = row.identity
                table?.row += 1
                table?.nextColumn = 0
            }
            guard let state = table, column < state.table.numberOfColumns else { return }
            // Empty cells have no runs; fill the gap so the row stays aligned.
            while (table?.nextColumn ?? column) < column { emptyCell(header: row.header) }
            let font = row.header ? Style.styled(Style.body, bold: true, italic: false) : Style.body
            append(inline(leaf.runs, font: font, color: .labelColor), cellStyle(column: column, header: row.header))
            table?.nextColumn = column + 1
        }

        private mutating func closeRow() {
            guard let state = table, state.row >= 0 else { return }
            while (table?.nextColumn ?? state.table.numberOfColumns) < state.table.numberOfColumns {
                emptyCell(header: state.row == 0)
            }
        }

        private mutating func emptyCell(header: Bool) {
            guard let column = table?.nextColumn else { return }
            append(NSAttributedString(string: "", attributes: [.font: Style.body]), cellStyle(column: column, header: header))
            table?.nextColumn = column + 1
        }

        private func cellStyle(column: Int, header: Bool) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            guard let state = table else { return style }
            let cell = NSTextTableBlock(table: state.table, startingRow: state.row, rowSpan: 1,
                                        startingColumn: column, columnSpan: 1)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setBorderColor(.separatorColor)
            cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
            if header { cell.backgroundColor = Style.wash }
            style.textBlocks = state.outer + [cell]
            style.alignment = column < state.alignments.count ? state.alignments[column] : .natural
            return style
        }

        // MARK: Pieces

        private mutating func blocks(_ identity: Int, indent: CGFloat, _ make: () -> NSTextBlock) -> [NSTextBlock] {
            if let existing = blocks[identity] { return existing }
            let made = Self.indented(indent, make(), gapBelow: true)
            blocks[identity] = made
            return made
        }

        /// A block moved right by a list's indent and, for quotes and code,
        /// spaced from what follows, both by a clear block around it: a
        /// block's own margin is painted with its background and border.
        /// Nested blocks' bottoms are measured from the same last line and do
        /// not add up, so the gap below counts the inner block's own bottom.
        private static func indented(_ indent: CGFloat, _ block: NSTextBlock, gapBelow: Bool = false) -> [NSTextBlock] {
            guard indent > 0 || gapBelow else { return [block] }
            let wrapper = fullWidth(NSTextBlock())
            wrapper.setWidth(indent, type: .absoluteValueType, for: .padding, edge: .minX)
            if gapBelow {
                let inner = block.width(for: .padding, edge: .maxY) + block.width(for: .border, edge: .maxY)
                wrapper.setWidth(inner + Style.paragraphGap, type: .absoluteValueType, for: .padding, edge: .maxY)
            }
            return [wrapper, block]
        }

        private func paragraph(indent: CGFloat, marker: String?) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.headIndent = indent
            if marker != nil {
                style.firstLineHeadIndent = max(0, indent - Style.indent + 4)
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            } else {
                style.firstLineHeadIndent = indent
            }
            return style
        }

        private func append(_ text: NSAttributedString, _ style: NSParagraphStyle) {
            let start = out.length
            out.append(text)
            out.append(NSAttributedString(string: "\n", attributes: [.font: Style.body]))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }

        private func inline(_ runs: [Leaf.Run], font base: NSFont, color: NSColor) -> NSAttributedString {
            let result = NSMutableAttributedString()
            var html = HTMLState()
            for run in runs {
                let i = run.inline
                var text = run.text
                if i.contains(.lineBreak) { text = "\u{2028}" }
                if i.contains(.inlineHTML) {
                    // One tag a run: links, anchors, images and <br> act, the rest drops.
                    if let (tag, _) = HTMLTag.prefix(of: text[...]),
                       let piece = html.apply(tag, font: base, color: color, lineBreak: "\u{2028}") {
                        result.append(piece)
                    }
                    continue
                }
                var font = i.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular) : base
                font = Style.styled(font, bold: i.contains(.stronglyEmphasized), italic: i.contains(.emphasized))
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if i.contains(.code) { attributes[.backgroundColor] = Style.wash }
                if i.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                let link: Any? = run.link ?? html.link
                if let link { attributes[.link] = link }
                if let image = run.image {
                    // A badge's link wins over its image.
                    let alt = text.isEmpty ? image.lastPathComponent : text
                    result.append(Self.image(alt, link: link ?? Self.imageLink(image.absoluteString), attributes: attributes))
                    continue
                }
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            return result
        }

        // MARK: Blocks

        /// A block as wide as the text: NSTextBlock's own default is no width,
        /// which wraps every character onto its own line.
        private static func fullWidth<Block: NSTextBlock>(_ block: Block) -> Block {
            block.setValue(100, type: .percentageValueType, for: .width)
            return block
        }

        private static func quoteBlock() -> NSTextBlock {
            let block = fullWidth(NSTextBlock())
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.tertiaryLabelColor, for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            return block
        }

        private static func codeBlock() -> NSTextBlock {
            let block = fullWidth(NSTextBlock())
            block.backgroundColor = Style.wash
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
            return block
        }

        /// The hairline under a level 1 or 2 heading.
        private static func ruledBlock() -> NSTextBlock {
            let block = fullWidth(NSTextBlock())
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(.separatorColor, for: .maxY)
            block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            return block
        }

        /// A thematic break (`---`).
        private static func ruleBlock() -> NSTextBlock {
            let block = fullWidth(NSTextBlock())
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(.separatorColor, for: .maxY)
            block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY)
            return block
        }

        /// An image as an icon and its alt text, leading to `link`.
        fileprivate static func image(_ alt: String, link: Any?, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attributes = attributes
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            let font = attributes[.font] as? NSFont ?? Style.body
            let piece = NSMutableAttributedString(attributedString: imageGlyph(font))
            piece.append(NSAttributedString(string: alt, attributes: attributes))
            if let link { piece.addAttribute(.link, value: link, range: NSRange(location: 0, length: piece.length)) }
            return piece
        }

        /// Where clicking an image leads: the image file or page, but not an
        /// image embedded in the document itself.
        fileprivate static func imageLink(_ source: String) -> String? {
            source.lowercased().hasPrefix("data:") ? nil : source
        }

        private static func imageGlyph(_ font: NSFont) -> NSAttributedString {
            // Tinted like the alt text in either appearance: a text
            // attachment draws a template image black.
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
            guard let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return NSAttributedString() }
            let attachment = NSTextAttachment()
            attachment.image = image
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.append(NSAttributedString(string: " ", attributes: [.font: font]))
            return glyph
        }

        // MARK: HTML

        /// Stands in for an HTML anchor in the text: a place with no width.
        fileprivate static let anchorMark: Character = "\u{200B}"

        /// A line with nothing to see but anchors (`<a name="top"></a>`).
        private static func anchorsOnly(_ line: NSAttributedString) -> Bool {
            line.string.contains(anchorMark) && line.string.allSatisfy { $0.isWhitespace || $0 == anchorMark }
        }

        /// `line` a point high: it stays, so links to its anchors still land.
        private static func pointHigh(_ line: NSAttributedString) -> NSAttributedString {
            let small = NSMutableAttributedString(attributedString: line)
            small.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: NSRange(location: 0, length: small.length))
            return small
        }

        /// Raw HTML as text: links, anchors, images and line breaks act, a
        /// block's end starts a new line, other tags drop.
        private static func html(_ source: String, font: NSFont, color: NSColor) -> NSAttributedString {
            let out = NSMutableAttributedString()
            var state = HTMLState()
            func text(_ piece: Substring) {
                guard !piece.isEmpty else { return }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if let link = state.link { attributes[.link] = link }
                out.append(NSAttributedString(string: decodeEntities(String(piece)), attributes: attributes))
            }
            var rest = source.replacing(#/<!--[\s\S]*?-->/#, with: "")[...]
            while let open = rest.firstIndex(of: "<") {
                text(rest[..<open])
                guard let (tag, end) = HTMLTag.prefix(of: rest[open...]) else {
                    text(rest[open...open])
                    rest = rest[rest.index(after: open)...]
                    continue
                }
                if let piece = state.apply(tag, font: font, color: color, lineBreak: "\n") { out.append(piece) }
                if tag.endsBlock { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
                rest = rest[end...]
            }
            text(rest)
            return out
        }

        /// The lines of `text` with the space around them trimmed, empty ones left out.
        private static func lines(of text: NSAttributedString) -> [NSAttributedString] {
            let string = text.string as NSString
            var lines: [NSAttributedString] = []
            var start = 0
            while start < string.length {
                var end = 0, contentsEnd = 0
                string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
                var range = NSRange(location: start, length: contentsEnd - start)
                while range.length > 0, Character(UnicodeScalar(string.character(at: range.location)) ?? " ").isWhitespace {
                    range.location += 1
                    range.length -= 1
                }
                while range.length > 0, Character(UnicodeScalar(string.character(at: NSMaxRange(range) - 1)) ?? " ").isWhitespace {
                    range.length -= 1
                }
                if range.length > 0 { lines.append(text.attributedSubstring(from: range)) }
                start = end
            }
            return lines
        }

        static func decodeEntities(_ text: String) -> String {
            guard text.contains("&") else { return text }
            return text.replacing(#/&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});/#) { match in
                let body = match.1
                if body.hasPrefix("#") {
                    let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                    let digits = body.dropFirst(hex ? 2 : 1)
                    if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                        return String(Character(scalar))
                    }
                    return String(match.0)
                }
                let named = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",
                             "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
                             "middot": "·", "times": "×", "rarr": "→", "larr": "←", "bull": "•"]
                return named[String(body)] ?? String(match.0)
            }
        }
    }

    /// One HTML tag, as far as a preview reads it.
    fileprivate struct HTMLTag {
        var name: String
        var closing: Bool
        var attributes: [String: String] = [:]

        /// Ends a line of block content.
        var endsBlock: Bool {
            switch name {
            case "hr": true
            case "p", "div", "li", "tr", "table", "ul", "ol", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6":
                closing
            default: false
            }
        }

        /// The tag `text` starts with, and where it ends.
        static func prefix(of text: Substring) -> (tag: HTMLTag, end: Substring.Index)? {
            guard let match = text.prefixMatch(of: #/<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s[^<>]*)?)/?>/#) else { return nil }
            var tag = HTMLTag(name: match.2.lowercased(), closing: !match.1.isEmpty)
            for attribute in match.3.matches(of: #/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/#) {
                let value = attribute.2 ?? attribute.3 ?? attribute.4 ?? ""
                tag.attributes[attribute.1.lowercased()] = Builder.decodeEntities(String(value))
            }
            return (tag, match.range.upperBound)
        }
    }

    /// The link open while walking HTML, and what each tag adds to the text.
    fileprivate struct HTMLState {
        var link: String?

        mutating func apply(_ tag: HTMLTag, font: NSFont, color: NSColor, lineBreak: String) -> NSAttributedString? {
            switch tag.name {
            case "a":
                if tag.closing {
                    link = nil
                    return nil
                }
                if let href = tag.attributes["href"] { link = href }
                guard let name = tag.attributes["name"] ?? tag.attributes["id"] else { return nil }
                return NSAttributedString(string: String(Builder.anchorMark), attributes: [.font: font, .previewAnchor: name])
            case "img":
                guard !tag.closing else { return nil }
                let source = tag.attributes["src"] ?? ""
                let alt = tag.attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? (source as NSString).lastPathComponent
                return Builder.image(alt, link: link ?? Builder.imageLink(source),
                                     attributes: [.font: font, .foregroundColor: color])
            case "br":
                return NSAttributedString(string: lineBreak, attributes: [.font: font])
            default:
                return nil
            }
        }
    }
}

private extension PresentationIntent.Kind {
    var isList: Bool {
        switch self {
        case .orderedList, .unorderedList: true
        default: false
        }
    }
}

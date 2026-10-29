import AppKit
import Foundation

/// Renders Markdown into an attributed string for a preview text view, so a
/// rendered file scrolls like any text and can be searched with the find bar.
/// Parsing is Foundation's (CommonMark plus GitHub tables, strikethrough and
/// autolinks). Quotes, code blocks and tables become NSTextBlocks (a left
/// rule, a tinted box, an NSTextTable), lists become indents. Raw HTML keeps
/// its text without the tags, and an image shows as its alt text: a preview
/// reads no file other than the one it shows. Safe off the main thread.
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
                append(inline(leaf.runs, font: Style.heading(level), color: color), style)

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
                append(body, style)

            case nil:
                // Raw HTML: its text, without the tags.
                let text = Self.stripTags(leaf.runs.map(\.text).joined())
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let style = paragraph(indent: indent, marker: nil)
                    style.paragraphSpacing = Style.paragraphGap
                    style.textBlocks = outer
                    append(NSAttributedString(string: trimmed, attributes: [.font: Style.body, .foregroundColor: NSColor.labelColor]), style)
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
            for run in runs {
                let i = run.inline
                var text = run.text
                if i.contains(.lineBreak) { text = "\u{2028}" }
                if i.contains(.inlineHTML) {
                    // Tags only; a <br> still breaks the line.
                    guard text.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    text = "\u{2028}"
                }
                var font = i.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular) : base
                font = Style.styled(font, bold: i.contains(.stronglyEmphasized), italic: i.contains(.emphasized))
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if i.contains(.code) { attributes[.backgroundColor] = Style.wash }
                if i.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                if let image = run.image {
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    if image.scheme == "http" || image.scheme == "https" { attributes[.link] = image }
                    if text.isEmpty { text = image.lastPathComponent }
                    result.append(Self.imageGlyph(font))
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

        private static func imageGlyph(_ font: NSFont) -> NSAttributedString {
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.9, weight: .regular)
            guard let image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return NSAttributedString() }
            let attachment = NSTextAttachment()
            attachment.image = image
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.append(NSAttributedString(string: " ", attributes: [.font: font]))
            return glyph
        }

        private static func stripTags(_ html: String) -> String {
            var text = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: char)
            }
            return text
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

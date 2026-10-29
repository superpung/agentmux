import Foundation

/// The cells of an Excel workbook (`.xlsx`), as text: shared and inline
/// strings, numbers as stored, booleans, and dates where the cell's number
/// format is a date or time.
public struct Spreadsheet: Sendable, Equatable {
    public struct Sheet: Sendable, Equatable {
        public var name: String
        /// Rows from the first, each as long as its last filled cell.
        public var rows: [[String]]
        /// Rows past the cap, not read.
        public var moreRows: Int
    }

    public var sheets: [Sheet]

    /// The rows read from each sheet, and the columns from each row.
    public static let rowCap = 10_000
    public static let columnCap = 200

    public init?(xlsx data: Data) {
        guard let zip = ZipArchive(data), let workbook = zip.file("xl/workbook.xml") else { return nil }
        let book = XMLElements(workbook)
        let flag: String? = book.first("workbookPr")?["date1904"]
        let date1904 = flag == "1" || flag == "true"
        let targets = Relationships(zip.file("xl/_rels/workbook.xml.rels"), base: "xl/")
        let strings = Self.sharedStrings(zip.file("xl/sharedStrings.xml"))
        let dateStyles = Self.dateStyles(zip.file("xl/styles.xml"))
        sheets = book.all("sheet").compactMap { sheet in
            guard let name = sheet["name"], let id = sheet.attribute(endingWith: ":id"),
                  let path = targets[id], let xml = zip.file(path) else { return nil }
            return Self.sheet(name, xml, strings: strings, dateStyles: dateStyles, date1904: date1904)
        }
    }

    private static func sheet(_ name: String, _ xml: Data, strings: [String], dateStyles: [Int: DateStyle],
                              date1904: Bool) -> Sheet {
        let reader = SheetReader(strings: strings, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return Sheet(name: name, rows: reader.rows, moreRows: reader.moreRows)
    }

    /// `xl/sharedStrings.xml`: each `<si>`'s text, phonetic hints left out.
    private static func sharedStrings(_ xml: Data?) -> [String] {
        guard let xml else { return [] }
        final class Reader: NSObject, XMLParserDelegate {
            var strings: [String] = []
            var current = ""
            var inText = false
            var phonetic = 0
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                switch localName(name) {
                case "si": current = ""
                case "rPh": phonetic += 1
                case "t": inText = phonetic == 0
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch localName(name) {
                case "si": strings.append(current)
                case "rPh": phonetic -= 1
                case "t": inText = false
                default: break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inText { current += string }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return reader.strings
    }

    enum DateStyle: Sendable { case date, time, dateTime }

    /// The cell styles (`s` index) whose number format shows a date or time.
    private static func dateStyles(_ xml: Data?) -> [Int: DateStyle] {
        guard let xml else { return [:] }
        let styles = XMLElements(xml)
        var formats: [Int: String] = [:]
        for format in styles.all("numFmt") {
            if let id = format["numFmtId"].flatMap(Int.init), let code = format["formatCode"] { formats[id] = code }
        }
        var result: [Int: DateStyle] = [:]
        for (index, xf) in styles.all("xf", inside: "cellXfs").enumerated() {
            guard let id = xf["numFmtId"].flatMap(Int.init) else { continue }
            if let style = builtInDateStyle(id) ?? formats[id].flatMap(dateStyle(of:)) { result[index] = style }
        }
        return result
    }

    private static func builtInDateStyle(_ id: Int) -> DateStyle? {
        switch id {
        case 14...17, 27...31, 34...36, 50...58: .date
        case 18...21, 32, 33, 45...47: .time
        case 22: .dateTime
        default: nil
        }
    }

    /// Whether a format code shows a date (`yyyy-mm-dd`), a time (`hh:mm`)
    /// or both, ignoring quoted text, `[...]` sections and escapes.
    static func dateStyle(of code: String) -> DateStyle? {
        var plain = ""
        var quoted = false, bracket = false, escaped = false
        for char in code.lowercased() {
            if escaped { escaped = false; continue }
            switch char {
            case "\"": quoted.toggle()
            case "\\": escaped = !quoted
            case "[" where !quoted: bracket = true
            case "]" where !quoted: bracket = false
            default: if !quoted && !bracket { plain.append(char) }
            }
        }
        let date = plain.contains("y") || plain.contains("d")
        let time = plain.contains("h") || plain.contains("s")
        switch (date, time) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        default: return nil
        }
    }

    /// An Excel serial day number as `yyyy-MM-dd`, `HH:mm:ss` or both.
    static func formatDate(_ serial: Double, _ style: DateStyle, date1904: Bool) -> String {
        let whole = serial.rounded(.down)
        var seconds = Int(((serial - whole) * 86400).rounded())
        var days = Int(whole) + (date1904 ? 1462 : 0)
        if seconds >= 86400 { seconds -= 86400; days += 1 }
        // Days from 1899-12-30 to a civil date (Howard Hinnant's algorithm).
        let z = days - 25569 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        switch style {
        case .date: return date
        case .time: return time
        case .dateTime: return date + " " + time
        }
    }

    /// Reads one worksheet's `<sheetData>`.
    private final class SheetReader: NSObject, XMLParserDelegate {
        let strings: [String]
        let dateStyles: [Int: DateStyle]
        let date1904: Bool
        var rows: [[String]] = []
        var moreRows = 0

        private var row: [String] = []
        private var rowIndex = -1
        private var column = -1
        private var type = ""
        private var style: Int?
        private var value = ""
        private var inValue = false

        init(strings: [String], dateStyles: [Int: DateStyle], date1904: Bool) {
            self.strings = strings
            self.dateStyles = dateStyles
            self.date1904 = date1904
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch localName(name) {
            case "row":
                let index = attributes["r"].flatMap(Int.init).map { $0 - 1 } ?? rowIndex + 1
                rowIndex = max(index, rowIndex + 1)
                row = []
                column = -1
            case "c":
                column = attributes["r"].flatMap(Self.column) ?? column + 1
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init)
                value = ""
            case "v", "t":
                inValue = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch localName(name) {
            case "v", "t":
                inValue = false
            case "c":
                guard column < Spreadsheet.columnCap else { return }
                let text = cellText()
                guard !text.isEmpty else { return }
                if row.count <= column { row += Array(repeating: "", count: column - row.count + 1) }
                row[column] = text
            case "row":
                guard !row.isEmpty else { return }
                guard rowIndex < Spreadsheet.rowCap else {
                    moreRows += 1
                    return
                }
                while rows.count < rowIndex { rows.append([]) }
                rows.append(row)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string }
        }

        private func cellText() -> String {
            switch type {
            case "s": return Int(value).flatMap { $0 < strings.count ? strings[$0] : nil } ?? ""
            case "b": return value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
            case "inlineStr", "str", "e": return value
            default:
                if let style, let dateStyle = dateStyles[style], let serial = Double(value) {
                    return Spreadsheet.formatDate(serial, dateStyle, date1904: date1904)
                }
                return value
            }
        }

        /// The column of a cell reference (`AB12` → 27).
        static func column(_ reference: String) -> Int? {
            var column = 0
            var letters = 0
            for scalar in reference.unicodeScalars {
                guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
                column = column * 26 + Int(scalar.value & 0x1F)
                letters += 1
            }
            return letters > 0 ? column - 1 : nil
        }
    }
}

/// The text of a PowerPoint deck (`.pptx`), slide by slide: each shape's
/// paragraphs with their outline level, the title apart, and the notes.
public struct Presentation: Sendable, Equatable {
    public struct Slide: Sendable, Equatable {
        public var title: String?
        /// Body paragraphs, with their outline level (0 at the top).
        public var paragraphs: [Paragraph]
        public var notes: [String]
    }

    public struct Paragraph: Sendable, Equatable {
        public var level: Int
        public var text: String
    }

    public var slides: [Slide]

    public init?(pptx data: Data) {
        guard let zip = ZipArchive(data), let deck = zip.file("ppt/presentation.xml") else { return nil }
        let targets = Relationships(zip.file("ppt/_rels/presentation.xml.rels"), base: "ppt/")
        slides = XMLElements(deck).all("sldId").compactMap { reference in
            guard let id = reference.attribute(endingWith: ":id"), let path = targets[id],
                  let xml = zip.file(path) else { return nil }
            let shapes = Self.shapes(xml)
            let titled = shapes.first { $0.placeholder == "title" || $0.placeholder == "ctrTitle" }
            let title = titled.map { $0.paragraphs.map(\.text).joined(separator: " ") }
            var body: [Paragraph] = []
            for shape in shapes where !shape.isTitle && shape.placeholder != "sldNum" && shape.placeholder != "dt" {
                body += shape.paragraphs
            }
            // The notes page the slide's relationships point to: its body text.
            let folder = (path as NSString).deletingLastPathComponent
            let slideTargets = Relationships(zip.file("\(folder)/_rels/\((path as NSString).lastPathComponent).rels"), base: folder + "/")
            let notes = slideTargets.first(ofType: "notesSlide").flatMap { zip.file($0) }.map { xml in
                Self.shapes(xml).filter { $0.placeholder == "body" }.flatMap { $0.paragraphs.map(\.text) }
            } ?? []
            return Slide(title: title?.isEmpty == false ? title : nil, paragraphs: body, notes: notes)
        }
    }

    struct Shape {
        var placeholder: String?
        var paragraphs: [Paragraph] = []
        var isTitle: Bool { placeholder == "title" || placeholder == "ctrTitle" }
    }

    /// The text shapes on a slide or notes page, in order, with empty
    /// paragraphs left out. A table's cells come as paragraphs too.
    static func shapes(_ xml: Data) -> [Shape] {
        final class Reader: NSObject, XMLParserDelegate {
            var shapes: [Shape] = []
            var shape: Shape?
            var depth = 0
            var paragraph: Paragraph?
            var inText = false
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                switch localName(name) {
                case "sp", "graphicFrame":
                    if depth == 0 { shape = Shape() }
                    depth += 1
                case "ph":
                    // A placeholder with no type is the body.
                    if shape?.placeholder == nil { shape?.placeholder = attributes["type"] ?? "body" }
                case "p":
                    paragraph = Paragraph(level: 0, text: "")
                case "pPr":
                    paragraph?.level = attributes["lvl"].flatMap(Int.init) ?? 0
                case "t":
                    inText = true
                case "br":
                    paragraph?.text += "\n"
                default:
                    break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch localName(name) {
                case "t":
                    inText = false
                case "p":
                    if let paragraph, !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        shape?.paragraphs.append(paragraph)
                    }
                    paragraph = nil
                case "sp", "graphicFrame":
                    depth -= 1
                    if depth == 0, let shape {
                        if !shape.paragraphs.isEmpty { shapes.append(shape) }
                        self.shape = nil
                    }
                default:
                    break
                }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inText { paragraph?.text += string }
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return reader.shapes
    }
}

/// A PowerPoint deck as Quick Look should get it.
public enum PresentationPackage {
    /// The deck without its speaker notes pages, which a slide preview never
    /// shows: macOS's own PowerPoint previewer never finishes some decks whose
    /// first slide has a notes page (seen with a PowerPoint for Mac deck on
    /// macOS 15.3; the same deck without them renders at once). Nil when the
    /// deck has none, or does not read as a ZIP.
    public static func withoutSpeakerNotes(_ data: Data) -> Data? {
        guard let zip = ZipArchive(data), zip.orderedNames.contains(where: isNotesPage) else { return nil }
        var writer = ZipWriter()
        for name in zip.orderedNames where !isNotesPage(name) {
            guard var contents = zip.file(name) else { return nil }
            if name.hasSuffix(".rels") || name == "[Content_Types].xml" {
                var xml = String(decoding: contents, as: UTF8.self)
                xml.replace(#/<Relationship\b[^>]*Type="[^"]*/notesSlide"[^>]*/>/#, with: "")
                xml.replace(#/<Override\b[^>]*PartName="/ppt/notesSlides/[^"]*"[^>]*/>/#, with: "")
                contents = Data(xml.utf8)
            }
            writer.add(name, contents)
        }
        return writer.finish()
    }

    private static func isNotesPage(_ name: String) -> Bool {
        name.hasPrefix("ppt/notesSlides/")
    }
}

// MARK: - XML helpers

/// The part of an element name after its namespace prefix.
private func localName(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}

/// An OOXML part's relationships (`_rels/*.rels`): target paths by id,
/// resolved inside the archive.
private struct Relationships {
    private var targets: [String: String] = [:]
    private var types: [(type: String, target: String)] = []

    init(_ xml: Data?, base: String) {
        guard let xml else { return }
        for relation in XMLElements(xml).all("Relationship") {
            guard let id = relation["Id"], let target = relation["Target"], relation["TargetMode"] != "External" else { continue }
            let path = PreviewLink.normalize(target.hasPrefix("/") ? target : base + target).dropFirst()
            targets[id] = String(path)
            types.append((relation["Type"] ?? "", String(path)))
        }
    }

    subscript(id: String) -> String? { targets[id] }

    /// The target of the first relationship whose type ends in `/name`.
    func first(ofType name: String) -> String? {
        types.first { $0.type.hasSuffix("/" + name) }?.target
    }
}

/// Every element of a small XML document with its attributes, for parts
/// read whole (workbook, styles, relationships).
private struct XMLElements {
    struct Element {
        let name: Substring
        let parents: [Substring]
        let attributes: [String: String]
        subscript(key: String) -> String? { attributes[key] }
        func attribute(endingWith suffix: String) -> String? {
            attributes.first { $0.key.hasSuffix(suffix) }?.value
        }
    }

    private(set) var elements: [Element] = []

    init(_ xml: Data) {
        final class Reader: NSObject, XMLParserDelegate {
            var elements: [Element] = []
            var stack: [Substring] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                elements.append(Element(name: localName(name), parents: stack, attributes: attributes))
                stack.append(localName(name))
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                stack.removeLast()
            }
        }
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        elements = reader.elements
    }

    func all(_ name: String, inside parent: String? = nil) -> [Element] {
        elements.filter { element in
            guard element.name == name else { return false }
            guard let parent else { return true }
            return element.parents.contains { $0 == parent }
        }
    }

    func first(_ name: String) -> Element? {
        elements.first { $0.name == name }
    }
}

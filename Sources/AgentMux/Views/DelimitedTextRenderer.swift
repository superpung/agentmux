import AppKit
import Foundation

/// Lays a CSV / TSV file out as aligned columns for a preview text view: the
/// first row as the header, each column on a tab stop as wide as its widest
/// cell, lines that never wrap. Quoted fields may hold separators, doubled
/// quotes and line breaks. Safe off the main thread.
enum DelimitedTextRenderer {
    static func render(_ text: String, separator: Character) -> NSAttributedString {
        let rows = parse(text, separator: separator)
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let gap: CGFloat = 16

        var widths: [CGFloat] = []
        for (index, row) in rows.enumerated() {
            let rowFont = index == 0 ? bold : font
            let advance = ("0" as NSString).size(withAttributes: [.font: rowFont]).width
            for (column, cell) in row.enumerated() {
                // A monospaced font sets ASCII at one fixed advance.
                let width = cell.utf8.count == cell.unicodeScalars.count
                    ? CGFloat(cell.utf8.count) * advance
                    : (cell as NSString).size(withAttributes: [.font: rowFont]).width
                if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
            }
        }
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for width in widths.dropLast() {
            x += ceil(width) + gap
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }

        let style = NSMutableParagraphStyle()
        style.tabStops = stops
        style.lineBreakMode = .byClipping
        style.paragraphSpacing = 3
        let headerStyle = style.mutableCopy() as! NSMutableParagraphStyle
        headerStyle.paragraphSpacing = 8

        let out = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let header = index == 0
            out.append(NSAttributedString(string: row.joined(separator: "\t") + (index < rows.count - 1 ? "\n" : ""), attributes: [
                .font: header ? bold : font,
                .foregroundColor: header ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: header ? headerStyle : style,
            ]))
        }
        return out
    }

    /// Rows of fields. A line break or tab inside a field becomes a space, so
    /// each row stays one line.
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
            atFieldStart = true
        }

        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char.isNewline || char == "\t" ? " " : char)
                }
            } else if char == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else if char == separator {
                endField()
            } else if char.isNewline {
                endField()
                if row != [""] { rows.append(row) }
                row = []
            } else {
                field.append(char == "\t" ? " " : char)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }
}

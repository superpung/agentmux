import Foundation

/// A Jupyter notebook (nbformat 4) as one Markdown document: Markdown cells
/// as they are, code cells as fenced code, and each code cell's outputs in a
/// quote under it (text as plain code, images inline as data URIs, errors
/// without terminal colors). Images pasted into a Markdown cell
/// (`attachment:name`) become data URIs too.
public enum Notebook {
    public static func markdown(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let cells = object["cells"] as? [[String: Any]] else { return nil }
        let metadata = object["metadata"] as? [String: Any]
        let language = (metadata?["language_info"] as? [String: Any])?["name"] as? String
            ?? (metadata?["kernelspec"] as? [String: Any])?["language"] as? String
            ?? ""
        var parts: [String] = []
        for cell in cells {
            let source = text(cell["source"])
            switch cell["cell_type"] as? String {
            case "markdown":
                parts.append(withAttachments(source, cell["attachments"] as? [String: Any]))
            case "code":
                parts.append(fenced(source, language: language))
                let outputs = (cell["outputs"] as? [[String: Any]] ?? []).compactMap(output)
                if !outputs.isEmpty {
                    parts.append(outputs.joined(separator: "\n\n").split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                }
            default:
                parts.append(fenced(source, language: ""))
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func output(_ output: [String: Any]) -> String? {
        switch output["output_type"] as? String {
        case "stream":
            return fenced(text(output["text"]), language: "")
        case "error":
            let traceback = (output["traceback"] as? [String])?.joined(separator: "\n")
            let summary = [output["ename"] as? String, output["evalue"] as? String].compactMap { $0 }.joined(separator: ": ")
            return fenced(stripANSI(traceback ?? summary), language: "")
        case "execute_result", "display_data":
            guard let data = output["data"] as? [String: Any] else { return nil }
            if let uri = imageURI(data) { return "![output](\(uri))" }
            if let markdown = data["text/markdown"] { return text(markdown) }
            if let plain = data["text/plain"] { return fenced(text(plain), language: "") }
            return nil
        default:
            return nil
        }
    }

    /// The first image in a MIME bundle as a data URI. nbformat keeps
    /// bitmaps as base64 and SVG as text.
    private static func imageURI(_ bundle: [String: Any]) -> String? {
        for type in ["image/png", "image/jpeg", "image/gif", "image/svg+xml"] {
            guard let image = bundle[type] else { continue }
            let base64 = type == "image/svg+xml"
                ? Data(text(image).utf8).base64EncodedString()
                : text(image).filter { !$0.isWhitespace }
            return "data:\(type);base64,\(base64)"
        }
        return nil
    }

    /// A Markdown cell with its pasted images (`attachment:name`) as data URIs.
    private static func withAttachments(_ source: String, _ attachments: [String: Any]?) -> String {
        guard let attachments, source.contains("attachment:") else { return source }
        var out = source
        for (name, bundle) in attachments {
            guard let bundle = bundle as? [String: Any], let uri = imageURI(bundle) else { continue }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            for form in Set([name, encoded]) {
                out = out.replacingOccurrences(of: "attachment:\(form)", with: uri)
            }
        }
        return out
    }

    /// nbformat stores text as a string or a list of lines.
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let lines = value as? [String] { return lines.joined() }
        return ""
    }

    /// `code` in a fence longer than any run of backticks inside it.
    static func fenced(_ code: String, language: String) -> String {
        var longest = 0, run = 0
        for char in code {
            run = char == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = code.hasSuffix("\n") ? String(code.dropLast()) : code
        return fence + language + "\n" + body + "\n" + fence
    }

    static func stripANSI(_ text: String) -> String {
        text.replacing(#/\x1B\[[0-9;?]*[A-Za-z]/#, with: "")
    }
}

/// Bytes as a hex dump: offset, sixteen bytes in two groups, and the
/// printable ASCII beside them, as `hexdump -C` prints it.
public enum HexDump {
    public static func format(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 16 * 78 + 78)
        let bytes = [UInt8](data)
        var line = 0
        while line < bytes.count {
            for shift in stride(from: 28, through: 0, by: -4) {
                out.append(hex[(line >> shift) & 0xF])
            }
            out += [0x20, 0x20]
            for i in 0..<16 {
                if i == 8 { out.append(0x20) }
                if line + i < bytes.count {
                    let byte = bytes[line + i]
                    out += [hex[Int(byte >> 4)], hex[Int(byte & 0xF)], 0x20]
                } else {
                    out += [0x20, 0x20, 0x20]
                }
            }
            out += [0x20, 0x7C]
            for i in line..<min(line + 16, bytes.count) {
                let byte = bytes[i]
                out.append((0x20...0x7E).contains(byte) ? byte : 0x2E)
            }
            out += [0x7C, 0x0A]
            line += 16
        }
        if out.last == 0x0A { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }
}

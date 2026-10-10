import Foundation

/// A reply to one command: the lines between `%begin` and `%end`/`%error`.
public struct ControlReply: Sendable, Equatable {
    public var number: Int
    /// tmux sets flag 1 on replies to commands this client sent; the reply
    /// to the attach command on the command line has flag 0.
    public var fromThisClient: Bool
    public var success: Bool
    public var lines: [Data]

    public var textLines: [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }
}

public enum ControlEvent: Sendable, Equatable {
    case reply(ControlReply)
    /// Pane output, already unescaped to the bytes the pane wrote.
    case output(paneID: String, data: Data)
    /// Any other `%name arguments` line.
    case notification(name: String, arguments: String)
    case exit(reason: String?)
}

/// Incremental parser for tmux control mode (`tmux -C`) output.
///
/// Works on bytes: pane output is arbitrary bytes with control characters
/// and backslashes escaped as `\ooo`, so it is unescaped before anyone
/// treats it as text. Partial lines are kept until their newline arrives.
public struct ControlParser: Sendable {
    private struct Block {
        var header: Data
        var number: Int
        var fromThisClient: Bool
        var lines: [Data]
    }

    private var pending = Data()
    private var block: Block?
    /// Lines longer than this are a protocol error rather than a reason to
    /// buffer without bound.
    public static let maxLineBytes = 16 << 20

    public init() {}

    public enum ParseError: Error, Equatable {
        case lineTooLong
    }

    public mutating func feed(_ data: Data) throws -> [ControlEvent] {
        pending.append(data)
        var events: [ControlEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex ..< newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending.removeSubrange(pending.startIndex ... newline)
            if let event = parse(Data(line)) {
                events.append(event)
            }
        }
        if pending.count > Self.maxLineBytes {
            throw ParseError.lineTooLong
        }
        return events
    }

    private mutating func parse(_ line: Data) -> ControlEvent? {
        if var open = block {
            // Only the exact closing line for this block ends it; reply
            // content (e.g. captured text) may itself start with "%end".
            let suffix = open.header
            if line == Data("%end ".utf8) + suffix || line == Data("%error ".utf8) + suffix {
                block = nil
                return .reply(ControlReply(
                    number: open.number,
                    fromThisClient: open.fromThisClient,
                    success: line.starts(with: Data("%end ".utf8)),
                    lines: open.lines
                ))
            }
            open.lines.append(line)
            block = open
            return nil
        }

        guard line.first == UInt8(ascii: "%") else { return nil }
        let (name, rest) = Self.splitWord(line.dropFirst())
        let nameText = String(decoding: name, as: UTF8.self)
        switch nameText {
        case "begin":
            let fields = rest.split(separator: UInt8(ascii: " "))
            guard fields.count >= 3, let number = Int(String(decoding: fields[1], as: UTF8.self)) else { return nil }
            let flags = Int(String(decoding: fields[2], as: UTF8.self)) ?? 0
            block = Block(header: Data(rest), number: number, fromThisClient: flags & 1 == 1, lines: [])
            return nil
        case "output":
            let (pane, data) = Self.splitWord(rest)
            return .output(paneID: String(decoding: pane, as: UTF8.self), data: Self.unescape(data))
        case "extended-output":
            // %extended-output %N <age> [more...] : <data>
            let (pane, afterPane) = Self.splitWord(rest)
            guard let colon = Self.range(of: Data(" : ".utf8), in: afterPane) else { return nil }
            return .output(paneID: String(decoding: pane, as: UTF8.self), data: Self.unescape(afterPane[colon.upperBound...]))
        case "exit":
            let reason = String(decoding: rest, as: UTF8.self)
            return .exit(reason: reason.isEmpty ? nil : reason)
        default:
            return .notification(name: nameText, arguments: String(decoding: rest, as: UTF8.self))
        }
    }

    /// `\ooo` -> byte; everything else passes through.
    public static func unescape<S: Collection>(_ bytes: S) -> Data where S.Element == UInt8 {
        let input = Array(bytes)
        var output = Data(capacity: input.count)
        var index = 0
        while index < input.count {
            if input[index] == UInt8(ascii: "\\"), index + 3 < input.count,
               input[(index + 1) ... (index + 3)].allSatisfy({ (0x30 ... 0x37).contains($0) })
            {
                let value = input[(index + 1) ... (index + 3)].reduce(0) { $0 * 8 + Int($1 - 0x30) }
                output.append(UInt8(truncatingIfNeeded: value))
                index += 4
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return output
    }

    private static func splitWord(_ bytes: Data.SubSequence) -> (Data.SubSequence, Data.SubSequence) {
        guard let space = bytes.firstIndex(of: UInt8(ascii: " ")) else {
            return (bytes, bytes[bytes.endIndex...])
        }
        return (bytes[bytes.startIndex ..< space], bytes[bytes.index(after: space)...])
    }

    private static func range(of needle: Data, in haystack: Data.SubSequence) -> Range<Data.Index>? {
        haystack.firstRange(of: needle)
    }
}

/// Quoting for words inside a tmux command line sent over control mode.
/// tmux parses each line itself (not a shell): a double-quoted word with
/// `\`, `"`, `$` and control characters escaped is read back verbatim.
public enum TmuxQuote {
    public static func word(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "$": out += "\\$"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{1B}": out += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Pane, window and session ids are safe bare words only after checking.
    public static func id(_ value: String) -> String? {
        guard let first = value.first, "%@$".contains(first), value.count > 1,
              value.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "'\(value)'"
    }
}

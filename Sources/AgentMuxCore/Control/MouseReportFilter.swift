import Foundation

/// Strips terminal mouse-report sequences from an outgoing input stream.
///
/// A mirrored terminal only forwards mouse reports to the remote pane while a
/// live TUI (Claude Code / Codex) is in the foreground consuming them. When the
/// pane has dropped back to a bare shell — a terminated/killed agent, the brief
/// window during an account switch, or a plain shell pane — the local terminal
/// can still be stuck in mouse-reporting mode (a killed full-screen app never
/// sends the disable sequence). Every pointer move then produces a report that,
/// forwarded as keystrokes, the shell runs as `;`-separated commands
/// (`-bash: 35: command not found` …). This filter drops those reports while
/// letting every real keystroke — arrows included — through unchanged.
///
/// Two report encodings are removed:
/// - SGR (mode 1006): `ESC [ < Ps ; Ps ; Ps (M | m)`
/// - X10 / normal:     `ESC [ M` followed by exactly three payload bytes
///
/// No real key sequence begins `ESC [ <` or `ESC [ M`, so arrows (`ESC [ A`,
/// `ESC O A`), function keys (`ESC [ 1 ~`) and a bare Escape are never touched.
/// A report split across two `strip(_:)` calls is carried and completed on the
/// next call; the carry is bounded so a malformed run can never grow without end.
public final class MouseReportFilter: @unchecked Sendable {
    private let lock = NSLock()
    /// The incomplete start of a mouse report held for the next call. Only ever
    /// holds bytes known to begin a report (`ESC [ <…` or `ESC [ M…`).
    private var carry: [UInt8] = []

    /// A mouse report longer than this is treated as malformed and dropped
    /// rather than held forever. Real reports are well under 16 bytes.
    private static let maxCarry = 64

    private static let esc: UInt8 = 0x1B
    private static let bracket: UInt8 = 0x5B // [
    private static let less: UInt8 = 0x3C // <
    private static let upperM: UInt8 = 0x4D // M
    private static let lowerM: UInt8 = 0x6D // m

    public init() {}

    /// Forgets any carried partial report. Call when switching back to raw
    /// forwarding so a stale fragment is never prepended later.
    public func reset() {
        lock.withLock { carry.removeAll(keepingCapacity: true) }
    }

    /// Returns `data` with every complete mouse report removed.
    public func strip(_ data: Data) -> Data {
        lock.withLock {
            var input = carry
            input.append(contentsOf: data)
            carry.removeAll(keepingCapacity: true)
            let (kept, pending) = Self.scan(input)
            carry = pending
            return Data(kept)
        }
    }

    /// Splits `bytes` into the output to forward and any trailing incomplete
    /// mouse report to carry. Pure, so it is directly unit-testable.
    static func scan(_ bytes: [UInt8]) -> (kept: [UInt8], carry: [UInt8]) {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let n = bytes.count
        var i = 0
        while i < n {
            guard bytes[i] == esc else { out.append(bytes[i]); i += 1; continue }
            // ESC at the very end: a real Escape key — pass it, don't hold it.
            if i + 1 >= n { out.append(bytes[i]); i += 1; continue }
            guard bytes[i + 1] == bracket else { out.append(bytes[i]); i += 1; continue }
            // "ESC [" with nothing after yet: pass through; real keys emit whole.
            if i + 2 >= n { out.append(contentsOf: bytes[i ..< n]); i = n; break }
            let marker = bytes[i + 2]
            if marker == less {
                // SGR mouse: scan for the M/m terminator.
                var j = i + 3
                while j < n, bytes[j] != upperM, bytes[j] != lowerM { j += 1 }
                if j < n {
                    i = j + 1 // drop ESC [ < … M/m
                } else {
                    // Incomplete: carry it (bounded) for the next call.
                    let partial = Array(bytes[i ..< n])
                    return (out, partial.count <= maxCarry ? partial : [])
                }
            } else if marker == upperM {
                // X10 mouse: ESC [ M + exactly three payload bytes.
                if i + 5 < n {
                    i += 6 // drop all six bytes
                } else {
                    let partial = Array(bytes[i ..< n])
                    return (out, partial.count <= maxCarry ? partial : [])
                }
            } else {
                // ESC [ <other>: a real CSI key (arrow, function key, …).
                out.append(esc)
                out.append(bracket)
                i += 2
            }
        }
        return (out, [])
    }
}

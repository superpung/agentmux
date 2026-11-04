import Foundation

/// Append-only log of every remote command the app issues (ssh invocations and
/// tmux control-mode lines), so a later tmux/server crash can be correlated
/// precisely with what the app did, on which host/container/socket, and when.
/// One ISO8601-timestamped line per command. Best-effort and never throws into
/// callers. Path: ~/Library/Logs/AgentMux/remote-commands.log (override with
/// AGENTMUX_COMMAND_LOG). Disable with AGENTMUX_COMMAND_LOG=off; off under
/// tests.
///
/// Rotated by size: past `maxBytes` the file becomes remote-commands.1.log
/// (replacing the one before) and a new one starts, so the log keeps the
/// latest one to two files' worth (about a day of polling) and no more.
public enum CommandLog {
    public static let maxBytes: UInt64 = 50 * 1024 * 1024

    nonisolated(unsafe) private static var file: RotatingLogFile?
    private static let queue = DispatchQueue(label: "agentmux.commandlog")

    // Accessed only on `queue` (serial), so safe despite ISO8601DateFormatter
    // not being Sendable.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static let url: URL? = {
        let env = ProcessInfo.processInfo.environment["AGENTMUX_COMMAND_LOG"]
        if env == "off" { return nil }
        if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
        // Tests run real commands; they stay out of the user's log.
        if ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName) { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AgentMux", isDirectory: true)
        return dir.appendingPathComponent("remote-commands.log")
    }()

    /// `channel` = "ssh" | "ctrl"; `context` identifies the target (host /
    /// container / client tag); `command` is the exact text sent.
    public static func log(_ channel: String, _ context: String, _ command: String) {
        guard let url else { return }
        let now = Date()
        let text = command.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "")
        queue.async {
            let line = Data("\(timestamp.string(from: now)) [\(channel)] \(context) :: \(text)\n".utf8)
            if file == nil { file = RotatingLogFile(url: url, maxBytes: maxBytes) }
            file?.append(line)
        }
    }
}

/// A file appended to until it passes `maxBytes`, then moved to `<name>.1.<ext>`
/// (replacing an older one) and started afresh. Not thread-safe: the caller
/// serializes appends.
final class RotatingLogFile {
    let url: URL
    let maxBytes: UInt64
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(url: URL, maxBytes: UInt64) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Where the previous file goes: remote-commands.log -> remote-commands.1.log.
    var previousURL: URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)")
    }

    func append(_ data: Data) {
        if handle == nil { open() }
        // A file already past the limit (one written before rotation
        // existed, say) rotates before the first line too.
        if size > 0, size + UInt64(data.count) > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {}
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: url, to: previousURL)
        open()
    }
}

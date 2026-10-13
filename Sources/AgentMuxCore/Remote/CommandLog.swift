import Foundation

/// Append-only log of every remote command the app issues (ssh invocations and
/// tmux control-mode lines), so a later tmux/server crash can be correlated
/// precisely with what the app did, on which host/container/socket, and when.
/// One ISO8601-timestamped line per command. Best-effort and never throws into
/// callers. Path: ~/Library/Logs/AgentMux/remote-commands.log (override with
/// AGENTMUX_COMMAND_LOG). Disable with AGENTMUX_COMMAND_LOG=off.
public enum CommandLog {
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var opened = false
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
            if !opened {
                opened = true
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: line)
        }
    }
}

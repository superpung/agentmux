import Foundation

/// Create / destroy operations on a target's own tmux server. These change the
/// user's sessions, so they are only ever invoked from the dedicated Sessions
/// window, and every destroy is confirmed in the UI. IDs are validated to the
/// `$`/`@`/`%` forms before use; names are tmux-quoted. Read-only inventory
/// stays in `InventoryProbe`.
public enum TmuxAdmin {
    /// `tmux new-session -d -s <name>` — a detached session.
    public static func newSession(host: HostConfig, target: TargetConfig, name: String) async -> Result<Void, RemoteFailure> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(RemoteFailure(.remoteCommandFailed, detail: "empty session name")) }
        return await run(host, target, ["new-session", "-d", "-s", TmuxQuote.word(trimmed)])
    }

    /// `tmux new-window -t <session>` — a window in an existing session.
    public static func newWindow(host: HostConfig, target: TargetConfig, sessionID: String) async -> Result<Void, RemoteFailure> {
        guard let id = TmuxQuote.id(sessionID) else { return invalid(sessionID) }
        return await run(host, target, ["new-window", "-t", id])
    }

    public static func killSession(host: HostConfig, target: TargetConfig, sessionID: String) async -> Result<Void, RemoteFailure> {
        guard let id = TmuxQuote.id(sessionID) else { return invalid(sessionID) }
        return await run(host, target, ["kill-session", "-t", id])
    }

    public static func killWindow(host: HostConfig, target: TargetConfig, windowID: String) async -> Result<Void, RemoteFailure> {
        guard let id = TmuxQuote.id(windowID) else { return invalid(windowID) }
        return await run(host, target, ["kill-window", "-t", id])
    }

    public static func killPane(host: HostConfig, target: TargetConfig, paneID: String) async -> Result<Void, RemoteFailure> {
        guard let id = TmuxQuote.id(paneID) else { return invalid(paneID) }
        return await run(host, target, ["kill-pane", "-t", id])
    }

    private static func invalid(_ value: String) -> Result<Void, RemoteFailure> {
        .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid tmux id: \(value)"))
    }

    private static func run(_ host: HostConfig, _ target: TargetConfig, _ args: [String]) async -> Result<Void, RemoteFailure> {
        let tmux: TmuxInvocation
        do {
            tmux = try target.executionContext().tmux
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        // The tmux invocation (binary + socket flags) is shell-quoted; `args`
        // are already individually safe (quoted ids / tmux-quoted name).
        let command = ShellQuote.command(tmux.argv) + " " + args.joined(separator: " ")
        let result = await RemoteScript.run("\(command) 2>&1", host: host, target: target, timeoutSeconds: 15)
        return result.map { _ in () }
    }
}

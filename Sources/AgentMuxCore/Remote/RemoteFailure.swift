import Foundation

/// Why a remote query failed, in the layer where it failed. An empty tmux
/// server (`noTmuxServer`) is a legitimate state, not a connection problem.
public enum RemoteFailureKind: String, Sendable, Equatable, CaseIterable {
    case sshAuthRequired = "SSH_AUTH_REQUIRED"
    case sshHostKey = "SSH_HOST_KEY_MISMATCH"
    case hostUnreachable = "HOST_UNREACHABLE"
    case dockerUnavailable = "DOCKER_UNAVAILABLE"
    case dockerPermissionDenied = "DOCKER_PERMISSION_DENIED"
    case containerNotFound = "CONTAINER_NOT_FOUND"
    case containerNotRunning = "CONTAINER_NOT_RUNNING"
    case execUserInvalid = "EXEC_USER_INVALID"
    case tmuxNotFound = "TMUX_NOT_FOUND"
    case tmuxSocketUnavailable = "TMUX_SOCKET_UNAVAILABLE"
    case noTmuxServer = "NO_TMUX_SESSIONS"
    case commandTimeout = "COMMAND_TIMEOUT"
    case outputLimitExceeded = "OUTPUT_LIMIT_EXCEEDED"
    case protocolDesync = "PROTOCOL_DESYNC"
    case remoteCommandFailed = "REMOTE_COMMAND_FAILED"
}

public struct RemoteFailure: Error, Sendable, Equatable {
    public var kind: RemoteFailureKind
    /// First relevant line of diagnostic output, with control characters removed.
    public var detail: String

    public init(_ kind: RemoteFailureKind, detail: String = "") {
        self.kind = kind
        self.detail = RemoteFailure.sanitize(detail)
    }

    /// Classifies a failed ssh / docker run. Returns nil when the command
    /// itself succeeded.
    public static func classify(_ result: CommandResult) -> RemoteFailure? {
        if result.timedOut {
            return RemoteFailure(.commandTimeout)
        }
        if result.stdoutTruncated {
            return RemoteFailure(.outputLimitExceeded)
        }
        guard result.exitStatus != 0 else { return nil }
        let stderr = result.stderrText
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        let rules: [(RemoteFailureKind, [String])] = [
            (.sshHostKey, ["Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED"]),
            (.sshAuthRequired, ["Permission denied (", "Too many authentication failures"]),
            (.hostUnreachable, [
                "Could not resolve hostname", "Connection timed out", "Operation timed out",
                "Connection refused", "No route to host", "Network is unreachable",
                "Connection closed by", "kex_exchange_identification", "Connection reset",
            ]),
            (.dockerPermissionDenied, ["permission denied while trying to connect to the Docker daemon"]),
            (.dockerUnavailable, ["Cannot connect to the Docker daemon", "docker: command not found", "docker: not found"]),
            (.containerNotFound, ["No such container", "No such object"]),
            (.containerNotRunning, ["is not running", "is paused", "is restarting"]),
            (.execUserInvalid, ["unable to find user", "no matching entries in passwd file"]),
        ]
        for (kind, needles) in rules where needles.contains(where: stderr.contains) {
            return RemoteFailure(kind, detail: line)
        }
        return RemoteFailure(.remoteCommandFailed, detail: line)
    }

    /// Classifies the message tmux printed when the server could not be reached.
    public static func classifyTmuxServerError(_ message: String) -> RemoteFailure {
        if message.contains("no server running on") {
            return RemoteFailure(.noTmuxServer, detail: message)
        }
        if message.contains("error connecting to"), message.contains("No such file or directory") {
            return RemoteFailure(.noTmuxServer, detail: message)
        }
        if message.contains("Permission denied") {
            return RemoteFailure(.tmuxSocketUnavailable, detail: message)
        }
        return RemoteFailure(.remoteCommandFailed, detail: message)
    }

    static func sanitize(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        }))
        return String(cleaned.prefix(300))
    }
}

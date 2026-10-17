import Foundation

/// A per-account config directory on a container (CLAUDE_CONFIG_DIR / CODEX_HOME).
public struct AgentConfigDir: Identifiable, Sendable, Equatable, Hashable {
    public let kind: AgentKind
    public let path: String
    public var id: String { "\(kind.rawValue):\(path)" }
    public var label: String { (path as NSString).lastPathComponent }

    public init(kind: AgentKind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// A resumable past session for one account. Metadata only — never any message
/// text (see the agent-data-privacy convention): id, project dir, last-active
/// time and a line count used as a size proxy.
public struct AgentSessionInfo: Identifiable, Sendable, Equatable, Hashable {
    public let kind: AgentKind
    public let configDir: String
    public let id: String
    public let cwd: String
    public let lastActiveEpoch: Int
    public let eventCount: Int

    public init(kind: AgentKind, configDir: String, id: String, cwd: String, lastActiveEpoch: Int, eventCount: Int) {
        self.kind = kind
        self.configDir = configDir
        self.id = id
        self.cwd = cwd
        self.lastActiveEpoch = lastActiveEpoch
        self.eventCount = eventCount
    }
}

/// Pure construction of the command typed into a fresh pane's interactive shell
/// to start or resume an agent. The account is selected by an env var; the
/// binary is found on the shell's PATH. Nothing here runs anything.
public enum AgentCommand {
    /// Returns nil for an unsupported kind or an unsafe resume id.
    public static func launch(kind: AgentKind, configDir: String, resumeID: String?) -> String? {
        if let resumeID, !isSafeToken(resumeID) { return nil }
        let dir = ShellQuote.word(configDir)
        switch kind {
        case .claudeCode:
            let resume = resumeID.map { " --resume \($0)" } ?? ""
            return "CLAUDE_CONFIG_DIR=\(dir) claude\(resume)"
        case .codex:
            let resume = resumeID.map { " resume \($0)" } ?? ""
            return "CODEX_HOME=\(dir) codex\(resume)"
        default:
            return nil
        }
    }

    /// A session id is typed into and run by an interactive shell, so it must
    /// carry no shell metacharacters. UUIDs and codex session names pass.
    public static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

/// Read-only discovery of accounts and their resumable sessions on a container.
public enum AgentSessionProbe {
    /// Lists config dirs that actually hold agent data (`.claude*/projects`,
    /// `.codex*/sessions`).
    public static func configDirs(host: HostConfig, target: TargetConfig) async -> Result<[AgentConfigDir], RemoteFailure> {
        let script = """
        H="$HOME"
        for d in "$H"/.claude "$H"/.claude-*; do [ -d "$d/projects" ] && echo "claude $d"; done
        for d in "$H"/.codex "$H"/.codex-*; do [ -d "$d/sessions" ] && echo "codex $d"; done
        """
        return (await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 15)).map(parseConfigDirs)
    }

    /// Lists the most recent sessions (by mtime) for one account.
    public static func sessions(host: HostConfig, target: TargetConfig, configDir: AgentConfigDir, limit: Int = 60) async -> Result<[AgentSessionInfo], RemoteFailure> {
        let cfg = ShellQuote.word(configDir.path)
        let script: String
        switch configDir.kind {
        case .claudeCode:
            // id|mtime|lines|cwd — cwd is grepped (a metadata field), never message text.
            script = """
            ls -t \(cfg)/projects/*/*.jsonl 2>/dev/null | head -\(limit) | while read -r f; do
              id=$(basename "$f" .jsonl)
              mt=$(stat -c %Y "$f" 2>/dev/null)
              n=$(wc -l < "$f" 2>/dev/null)
              cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"cwd":"//;s/"$//')
              echo "$id|$mt|$n|$cwd"
            done
            """
        case .codex:
            script = """
            find \(cfg)/sessions -name 'rollout-*.jsonl' -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -\(limit) | while read -r mt f; do
              meta=$(head -1 "$f" 2>/dev/null)
              id=$(printf '%s' "$meta" | jq -r '.payload.id // empty' 2>/dev/null)
              cwd=$(printf '%s' "$meta" | jq -r '.payload.cwd // empty' 2>/dev/null)
              n=$(wc -l < "$f" 2>/dev/null)
              echo "$id|${mt%.*}|$n|$cwd"
            done
            """
        default:
            return .success([])
        }
        return (await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 20))
            .map { parseSessions($0, kind: configDir.kind, configDir: configDir.path) }
    }

    // MARK: Pure parsing (unit-tested)

    public static func parseConfigDirs(_ text: String) -> [AgentConfigDir] {
        var result: [AgentConfigDir] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let kind: AgentKind = parts[0] == "claude" ? .claudeCode : parts[0] == "codex" ? .codex : .none
            guard kind != .none else { continue }
            let dir = AgentConfigDir(kind: kind, path: parts[1])
            if !result.contains(dir) { result.append(dir) }
        }
        return result
    }

    public static func parseSessions(_ text: String, kind: AgentKind, configDir: String) -> [AgentSessionInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, !f[0].isEmpty, AgentCommand.isSafeToken(f[0]) else { return nil }
            let cwd = f[3].isEmpty ? "~" : f[3]
            return AgentSessionInfo(
                kind: kind, configDir: configDir, id: f[0], cwd: cwd,
                lastActiveEpoch: Int(f[1]) ?? 0, eventCount: Int(f[2]) ?? 0
            )
        }
    }
}

/// One account's entry for a project directory and the real directory it
/// physically resolves to. Entries that share a `realPath` share their chat
/// sessions (via a symlink between the accounts' `projects/<cwd>` dirs), so an
/// agent in that project can be resumed under any of those accounts. Read-only
/// metadata only — never message text.
public struct ProjectLinkEntry: Sendable, Equatable {
    public let configDir: String
    public let projectDir: String
    public let realPath: String
    public let cwd: String
    public let sessionCount: Int
    public let lastActiveEpoch: Int

    public init(configDir: String, projectDir: String, realPath: String, cwd: String, sessionCount: Int, lastActiveEpoch: Int) {
        self.configDir = configDir
        self.projectDir = projectDir
        self.realPath = realPath
        self.cwd = cwd
        self.sessionCount = sessionCount
        self.lastActiveEpoch = lastActiveEpoch
    }
}

/// A set of accounts that share one real project directory, so their sessions
/// are interchangeable. `isShared` when more than one account links to it —
/// those are the accounts an agent in this project can be switched between.
public struct ProjectLinkGroup: Identifiable, Sendable, Equatable {
    public let realPath: String
    public let cwd: String
    public let accounts: [String]
    public let sessionCount: Int
    public let lastActiveEpoch: Int

    public var id: String { realPath }
    public var isShared: Bool { accounts.count > 1 }
    /// The real cwd when known, else the project dir basename.
    public var label: String { cwd.isEmpty ? (realPath as NSString).lastPathComponent : cwd }

    public init(realPath: String, cwd: String, accounts: [String], sessionCount: Int, lastActiveEpoch: Int) {
        self.realPath = realPath
        self.cwd = cwd
        self.accounts = accounts
        self.sessionCount = sessionCount
        self.lastActiveEpoch = lastActiveEpoch
    }
}

public extension AgentSessionProbe {
    /// Maps every Claude account's project dirs to the real directory they
    /// resolve to (`readlink -f`), so callers can see which accounts share a
    /// project's sessions. Read-only: dir structure, symlink targets and a
    /// session's `cwd`/count/mtime — never message text.
    static func projectLinks(host: HostConfig, target: TargetConfig) async -> Result<[ProjectLinkEntry], RemoteFailure> {
        let script = """
        for d in "$HOME"/.claude "$HOME"/.claude-*; do
          [ -d "$d/projects" ] || continue
          for p in "$d/projects"/*; do
            [ -e "$p" ] || continue
            name=$(basename "$p")
            rp=$(readlink -f "$p" 2>/dev/null)
            [ -n "$rp" ] || continue
            nf=$(ls -t "$rp"/*.jsonl 2>/dev/null | head -1)
            n=$(ls "$rp"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
            mt=0; [ -n "$nf" ] && mt=$(stat -c %Y "$nf" 2>/dev/null)
            cwd=""; [ -n "$nf" ] && cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$nf" 2>/dev/null | sed 's/.*"cwd":"//;s/"$//')
            echo "$d|$name|$rp|$cwd|$n|$mt"
          done
        done
        """
        return (await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 30)).map(parseProjectLinks)
    }

    static func parseProjectLinks(_ text: String) -> [ProjectLinkEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, !f[0].isEmpty, !f[2].isEmpty else { return nil }
            return ProjectLinkEntry(
                configDir: f[0], projectDir: f[1], realPath: f[2], cwd: f[3],
                sessionCount: Int(f[4]) ?? 0, lastActiveEpoch: Int(f[5]) ?? 0
            )
        }
    }

    /// Groups entries by the real directory they resolve to; shared groups
    /// (more than one account) first, then most-recently-active.
    static func linkGroups(from entries: [ProjectLinkEntry]) -> [ProjectLinkGroup] {
        var byReal: [String: [ProjectLinkEntry]] = [:]
        for entry in entries { byReal[entry.realPath, default: []].append(entry) }
        let groups = byReal.map { realPath, group -> ProjectLinkGroup in
            ProjectLinkGroup(
                realPath: realPath,
                cwd: group.first(where: { !$0.cwd.isEmpty })?.cwd ?? "",
                accounts: Array(Set(group.map(\.configDir))).sorted(),
                sessionCount: group.map(\.sessionCount).max() ?? 0,
                lastActiveEpoch: group.map(\.lastActiveEpoch).max() ?? 0
            )
        }
        return groups.sorted {
            $0.isShared == $1.isShared ? $0.lastActiveEpoch > $1.lastActiveEpoch : $0.isShared
        }
    }
}

/// Starts or resumes an agent by creating a tmux session/window and typing the
/// launch command into its interactive shell. Only ever invoked from the
/// Sessions window.
public enum AgentLauncher {
    /// Creates `name` at `cwd` and runs `command` in it.
    public static func launchInNewSession(host: HostConfig, target: TargetConfig, name: String, cwd: String, command: String) async -> Result<Void, RemoteFailure> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(RemoteFailure(.remoteCommandFailed, detail: "empty session name")) }
        return await run(host, target, [
            ["new-session", "-d", "-s", trimmed, "-c", cwd],
            ["send-keys", "-t", trimmed, "-l", command],
            ["send-keys", "-t", trimmed, "Enter"],
        ])
    }

    /// Opens a new window in `sessionID` at `cwd` and runs `command` in it.
    public static func launchInNewWindow(host: HostConfig, target: TargetConfig, sessionID: String, cwd: String, command: String) async -> Result<Void, RemoteFailure> {
        guard TmuxQuote.id(sessionID) != nil else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid tmux id: \(sessionID)"))
        }
        return await run(host, target, [
            ["new-window", "-t", sessionID, "-c", cwd],
            ["send-keys", "-t", sessionID, "-l", command],
            ["send-keys", "-t", sessionID, "Enter"],
        ])
    }

    /// Runs each tmux command (raw args, shell-quoted here) in order.
    private static func run(_ host: HostConfig, _ target: TargetConfig, _ commands: [[String]]) async -> Result<Void, RemoteFailure> {
        let tmux: TmuxInvocation
        do {
            tmux = try target.executionContext().tmux
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        let script = commands.map { ShellQuote.command(tmux.argv + $0) }.joined(separator: " && ")
        return (await RemoteScript.run("\(script) 2>&1", host: host, target: target, timeoutSeconds: 15)).map { _ in () }
    }
}

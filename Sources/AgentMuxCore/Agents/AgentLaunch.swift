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

/// A resumable past session for one account: id, project dir, last-active time,
/// a line count used as a size proxy, and `preview` — the last message's text,
/// truncated to one short line. The preview is the one place message text is
/// read, and only by the Launch page the user explicitly opens; the background
/// auto-refresh never reads it (it stays status-only per agent-data-privacy).
public struct AgentSessionInfo: Identifiable, Sendable, Equatable, Hashable {
    public let kind: AgentKind
    public let configDir: String
    public let id: String
    public let cwd: String
    public let lastActiveEpoch: Int
    public let eventCount: Int
    public let preview: String

    public init(kind: AgentKind, configDir: String, id: String, cwd: String, lastActiveEpoch: Int, eventCount: Int, preview: String = "") {
        self.kind = kind
        self.configDir = configDir
        self.id = id
        self.cwd = cwd
        self.lastActiveEpoch = lastActiveEpoch
        self.eventCount = eventCount
        self.preview = preview
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
              pv=$(tail -n 40 "$f" 2>/dev/null | jq -r '(.message.content // empty) | (if type=="string" then . elif type=="array" then (map(select(.type=="text").text // empty)|join(" ")) else empty end) | gsub("\\n";" ")' 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | tr -d '|' | cut -c1-200)
              echo "$id|$mt|$n|$cwd|$pv"
            done
            """
        case .codex:
            script = """
            find \(cfg)/sessions -name 'rollout-*.jsonl' -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -\(limit) | while read -r mt f; do
              meta=$(head -1 "$f" 2>/dev/null)
              id=$(printf '%s' "$meta" | jq -r '.payload.id // empty' 2>/dev/null)
              cwd=$(printf '%s' "$meta" | jq -r '.payload.cwd // empty' 2>/dev/null)
              n=$(wc -l < "$f" 2>/dev/null)
              pv=$(tail -n 60 "$f" 2>/dev/null | jq -r '([.. | (.text? // .output_text? // empty)] | map(select(type=="string" and . != "")) | last // "") | gsub("\\n";" ")' 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | tr -d '|' | cut -c1-200)
              echo "$id|${mt%.*}|$n|$cwd|$pv"
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
            let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty, AgentCommand.isSafeToken(f[0]) else { return nil }
            let cwd = f[3].isEmpty ? "~" : f[3]
            let preview = f.count >= 5 ? String(f[4].prefix(140)) : ""
            return AgentSessionInfo(
                kind: kind, configDir: configDir, id: f[0], cwd: cwd,
                lastActiveEpoch: Int(f[1]) ?? 0, eventCount: Int(f[2]) ?? 0, preview: preview
            )
        }
    }

    /// A Codex account dir and its non-secret account id, for switching accounts.
    public struct CodexAccount: Sendable, Equatable {
        public let path: String
        public let accountID: String
        public init(path: String, accountID: String) { self.path = path; self.accountID = accountID }
    }

    /// Codex account dirs (`~/.codex*` with a sessions dir) and each one's
    /// non-secret `tokens.account_id`. Never reads any token.
    public static func codexAccounts(host: HostConfig, target: TargetConfig) async -> Result<[CodexAccount], RemoteFailure> {
        let script = """
        command -v jq >/dev/null 2>&1 || exit 0
        for d in "$HOME"/.codex "$HOME"/.codex-*; do
          [ -d "$d/sessions" ] || continue
          id=$(jq -r '.tokens.account_id // empty' "$d/auth.json" 2>/dev/null)
          [ -n "$id" ] && printf '%s|%s\\n' "$d" "$id"
        done
        """
        return (await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 15)).map { text in
            text.split(whereSeparator: \.isNewline).compactMap { line in
                let p = line.split(separator: "|", maxSplits: 1).map(String.init)
                guard p.count == 2, !p[0].isEmpty, !p[1].isEmpty, AgentAccountSwitch.isSafeConfigDir(p[0]) else { return nil }
                return CodexAccount(path: p[0], accountID: p[1])
            }
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

/// Switches the Claude agent running in a tmux pane to a different account
/// (CLAUDE_CONFIG_DIR) while continuing the same conversation. Only valid when
/// the two accounts share the project's sessions (a symlinked `projects/<cwd>`),
/// which the caller verifies via `ProjectLinkGroup`. Destructive: it stops the
/// running Claude (SIGTERM, then SIGKILL as a fallback) and relaunches it in the
/// same pane with `--resume`, so any in-flight turn is lost (the transcript on
/// disk is not — it is what the new account resumes from).
public enum AgentAccountSwitch {
    /// Config dirs are container paths like `/root/.claude-2`; reject anything
    /// with shell-unsafe characters before it is typed into a pane.
    public static func isSafeConfigDir(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count < 256 && path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
    }

    /// `claudePID` is the detected Claude process for `paneID`; the script
    /// refuses to kill it unless it is still that pane's Claude, so a stale pid
    /// can never take down an unrelated process.
    public static func switchClaudeAccount(
        host: HostConfig, target: TargetConfig,
        paneID: String, claudePID: Int, cwd: String, newConfigDir: String
    ) async -> Result<String, RemoteFailure> {
        guard TmuxQuote.id(paneID) != nil else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid pane id"))
        }
        guard isSafeConfigDir(newConfigDir) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "unsafe config dir"))
        }
        guard claudePID > 1 else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid pid"))
        }
        let tmux: TmuxInvocation
        do { tmux = try target.executionContext().tmux }
        catch { return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)")) }
        let tm = ShellQuote.command(tmux.argv)
        let script = """
        pane=\(ShellQuote.word(paneID))
        pid=\(ShellQuote.word(String(claudePID)))
        newcfg=\(ShellQuote.word(newConfigDir))
        cwd=\(ShellQuote.word(cwd))
        # Refuse to touch a pid that is not this pane's Claude (guards a stale pid).
        tp=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
        cl=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$tp" in "$pane") ;; *) echo "ERR: process $pid is not in $pane any more (stale); refusing"; exit 1;; esac
        case "$cl" in *claude*) ;; *) echo "ERR: process $pid is not Claude any more (stale); refusing"; exit 1;; esac
        # Session id to resume: the process's own session record
        # (sessions/<pid>.json, kept current by Claude), else the --resume on
        # the cmdline, else the newest transcript in this account's project dir
        # for this cwd (wrong when agents share that dir, so the last resort).
        ccfg=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1)
        ccfg=${ccfg:-$HOME/.claude}
        enc=$(printf '%s' "$cwd" | sed 's#/#-#g')
        sid=""
        for cand in "$(jq -r '.sessionId // empty' "$ccfg/sessions/$pid.json" 2>/dev/null)" \\
                    "$(printf '%s' "$cl" | grep -oE -- '--resume [0-9a-fA-F-]{36}' | awk '{print $2}' | head -1)"; do
          case "$cand" in ""|*[!0-9a-fA-F-]*) continue ;; esac
          [ -f "$ccfg/projects/$enc/$cand.jsonl" ] && { sid=$cand; break; }
        done
        if [ -z "$sid" ]; then
          nf=$(ls -t "$ccfg/projects/$enc"/*.jsonl 2>/dev/null | head -1)
          [ -n "$nf" ] && sid=$(basename "$nf" .jsonl)
        fi
        case "$sid" in ""|*[!0-9a-fA-F-]*) echo "ERR: could not determine the session id to resume"; exit 1;; esac
        # Stop gracefully, then hard.
        kill -TERM "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i+1)); done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; sleep 0.3; fi
        sleep 0.4
        cmd="CLAUDE_CONFIG_DIR=$newcfg claude --resume $sid"
        # Discard any partial line at the shell prompt before typing, so a stray
        # byte that landed between the kill and now cannot prefix the command.
        \(tm) send-keys -t "$pane" C-u
        \(tm) send-keys -t "$pane" -l "$cmd" || { echo "ERR: could not type the relaunch command"; exit 1; }
        \(tm) send-keys -t "$pane" Enter
        echo "OK: $sid"
        """
        let result = await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 30)
        switch result {
        case let .success(output):
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            guard let status = lines.last(where: { $0.hasPrefix("OK:") || $0.hasPrefix("ERR:") }) else {
                return .failure(RemoteFailure(.remoteCommandFailed, detail: output.isEmpty ? "no output" : output))
            }
            if status.hasPrefix("OK:") {
                return .success(status.dropFirst(3).trimmingCharacters(in: .whitespaces))
            }
            return .failure(RemoteFailure(.remoteCommandFailed, detail: status.dropFirst(4).trimmingCharacters(in: .whitespaces)))
        case let .failure(failure):
            return .failure(failure)
        }
    }

    /// Switches a Codex agent to another account dir (CODEX_HOME), resuming the
    /// same session in place. Works because the per-account `sessions` dirs are
    /// linked to one canonical copy, so `codex resume <id>` finds the rollout
    /// under the new account. `codexPID` is the detected Codex process for the
    /// pane; a stale pid is refused. Destructive — the caller confirms first.
    public static func switchCodexAccount(
        host: HostConfig, target: TargetConfig,
        paneID: String, codexPID: Int, cwd: String, newConfigDir: String
    ) async -> Result<String, RemoteFailure> {
        guard TmuxQuote.id(paneID) != nil else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid pane id"))
        }
        guard isSafeConfigDir(newConfigDir) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "unsafe config dir"))
        }
        guard codexPID > 1 else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid pid"))
        }
        let tmux: TmuxInvocation
        do { tmux = try target.executionContext().tmux }
        catch { return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)")) }
        let tm = ShellQuote.command(tmux.argv)
        let script = """
        pane=\(ShellQuote.word(paneID))
        pid=\(ShellQuote.word(String(codexPID)))
        newcfg=\(ShellQuote.word(newConfigDir))
        cwd=\(ShellQuote.word(cwd))
        # Refuse to touch a pid that is not this pane's Codex (guards a stale pid).
        tp=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
        cl=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$tp" in "$pane") ;; *) echo "ERR: process $pid is not in $pane any more (stale); refusing"; exit 1;; esac
        case "$cl" in *codex*) ;; *) echo "ERR: process $pid is not Codex any more (stale); refusing"; exit 1;; esac
        ch=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
        ch=${ch:-$HOME/.codex}
        # Session id to resume: `resume <id>` on the cmdline, else the id of the
        # live rollout the shared app-server holds for this (CODEX_HOME, cwd),
        # else the newest rollout matching this cwd. Only metadata is read.
        sid=$(printf '%s' "$cl" | grep -oE 'resume [A-Za-z0-9._-]+' | awk '{print $2}' | head -1)
        if [ -z "$sid" ] && command -v jq >/dev/null 2>&1; then
          for q in $(ps -eo pid=,comm= 2>/dev/null | awk '$2=="codex"{print $1}'); do
            case "$(tr '\\0' ' ' < "/proc/$q/cmdline" 2>/dev/null)" in *app-server*) ;; *) continue ;; esac
            qch=$(tr '\\0' '\\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1); qch=${qch:-$HOME/.codex}
            [ "$qch" = "$ch" ] || continue
            for rf in $(ls -l "/proc/$q/fd" 2>/dev/null | grep -oE '/[^ ]*/sessions/[0-9]+/[0-9]+/[0-9]+/rollout-[^ ]*\\.jsonl' | sort -u); do
              [ -f "$rf" ] || continue
              [ "$(head -n 1 "$rf" | jq -r '.payload.cwd // empty' 2>/dev/null)" = "$cwd" ] || continue
              sid=$(head -n 1 "$rf" | jq -r '.payload.id // empty' 2>/dev/null); [ -n "$sid" ] && break
            done
            [ -n "$sid" ] && break
          done
        fi
        if [ -z "$sid" ] && command -v jq >/dev/null 2>&1; then
          rf=$(find -L "$ch/sessions" -name 'rollout-*.jsonl' -printf '%T@ %p\\n' 2>/dev/null | sort -rn | while read -r _ f; do
            [ "$(head -n 1 "$f" | jq -r '.payload.cwd // empty' 2>/dev/null)" = "$cwd" ] && { echo "$f"; break; }
          done)
          [ -n "$rf" ] && sid=$(head -n 1 "$rf" | jq -r '.payload.id // empty' 2>/dev/null)
        fi
        case "$sid" in ""|*[!A-Za-z0-9._-]*) echo "ERR: could not determine the session id to resume"; exit 1;; esac
        # Stop gracefully, then hard.
        kill -TERM "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.25; i=$((i+1)); done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; sleep 0.3; fi
        sleep 0.4
        cmd="CODEX_HOME=$newcfg codex resume $sid"
        # Discard any partial line at the shell prompt before typing, so a stray
        # byte that landed between the kill and now cannot prefix the command.
        \(tm) send-keys -t "$pane" C-u
        \(tm) send-keys -t "$pane" -l "$cmd" || { echo "ERR: could not type the relaunch command"; exit 1; }
        \(tm) send-keys -t "$pane" Enter
        echo "OK: $sid"
        """
        let result = await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 30)
        switch result {
        case let .success(output):
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            guard let status = lines.last(where: { $0.hasPrefix("OK:") || $0.hasPrefix("ERR:") }) else {
                return .failure(RemoteFailure(.remoteCommandFailed, detail: output.isEmpty ? "no output" : output))
            }
            if status.hasPrefix("OK:") {
                return .success(status.dropFirst(3).trimmingCharacters(in: .whitespaces))
            }
            return .failure(RemoteFailure(.remoteCommandFailed, detail: status.dropFirst(4).trimmingCharacters(in: .whitespaces)))
        case let .failure(failure):
            return .failure(failure)
        }
    }
}

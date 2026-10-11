import Foundation

/// The read-only inventory script run inside a target, and its parser.
///
/// The script only runs `tmux list-*` / `display-message -p`, one `ps` and
/// reads under `/proc`; it writes no files. Output is line based. tmux
/// escapes newlines in names but may pass tabs through, so no character is
/// a safe field separator: every untrusted text field is fetched by its own
/// `list-*` call as `<id> <value>` and split on the first space.
public enum InventoryProbe {
    public static let maxProcessLines = 3000
    public static let maxAgentCandidates = 64

    /// `nonce` (ASCII letters and digits) marks the start and end of the
    /// output, so remote text can never fake the end of the probe.
    public static func script(tmux: TmuxInvocation, nonce: String) -> String {
        precondition(!nonce.isEmpty && nonce.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let binary = ShellQuote.word(tmux.executable ?? "tmux")
        let flags = ShellQuote.command(Array(tmux.argv.dropFirst()))
        return """
        T=\(binary)
        tm() { "$T" \(flags) "$@"; }
        echo "@@begin 1 \(nonce)"
        echo "@@uid $(id -u 2>/dev/null)"
        echo "@@os $(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n 1)"
        if ! command -v "$T" >/dev/null 2>&1; then echo "@@error tmux-not-found"; echo "@@end \(nonce)"; exit 0; fi
        echo "@@tmux $("$T" -V 2>&1 | head -n 1)"
        if ! server=$(tm display-message -p '#{pid} #{start_time} #{socket_path}' 2>&1); then
          echo "@@error tmux-server $(printf '%s' "$server" | head -n 1)"; echo "@@end \(nonce)"; exit 0
        fi
        echo "@@server $server"
        echo "@@section memberships"
        tm list-panes -a -F '#{session_id} #{window_id} #{pane_id} #{window_index} #{pane_index} #{pane_active} #{window_active}'
        echo "@@section panes"
        tm list-panes -a -F '#{pane_id} #{pane_pid} #{pane_dead} #{pane_width} #{pane_height}'
        echo "@@section session_name"
        tm list-sessions -F '#{session_id} #{session_name}'
        echo "@@section window_name"
        tm list-windows -a -F '#{window_id} #{window_name}'
        for field in pane_current_command pane_current_path pane_title; do
          echo "@@section $field"
          tm list-panes -a -F "#{pane_id} #{$field}"
        done
        command -v ps >/dev/null 2>&1 || echo "@@error ps-unavailable"
        procs=$( { tm list-panes -a -F 'P #{pane_id} #{pane_pid}'; ps -eo pid=,ppid=,stat=,comm= 2>/dev/null | sed 's/^ */S /'; } | awk '
          $1 == "P" { if (!($3 in pane)) pane[$3] = $2; next }
          $1 == "S" { parent[$2] = $3; stat[$2] = $4; c = $5; for (i = 6; i <= NF; i++) c = c " " $i; comm[$2] = c; order[++n] = $2; next }
          END {
            for (k = 1; k <= n; k++) {
              pid = order[k]; p = pid
              for (d = 0; d <= 6; d++) {
                if (p in pane) { print pane[p], d, pid, parent[pid], stat[pid], comm[pid]; break }
                if (!(p in parent)) break
                p = parent[p]
              }
            }
          }' | head -n \(maxProcessLines) )
        echo "@@section processes"
        printf '%s\\n' "$procs"
        echo "@@section agents"
        printf '%s\\n' "$procs" | awk '$5 !~ /^Z/ && $6 ~ /^(codex|claude|node|bun|deno)$/ { print $3 }' | head -n \(maxAgentCandidates) | while read -r pid; do
          echo "@@agent $pid"
          echo "exe $(readlink "/proc/$pid/exe" 2>/dev/null)"
          tr '\\0\\n' '\\n ' < "/proc/$pid/cmdline" 2>/dev/null | head -n 2 | cut -c1-160 | sed 's/^/arg /'
          tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(CODEX_HOME|CLAUDE_CONFIG_DIR|TMUX_PANE)=' | cut -c1-300 | sed 's/^/env /'
          echo "start $(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f20)"
          # Claude session log state — structural only (event type/subtype +
          # mtime age), never message content. Located by the --resume id
          # (the pane's own session file; the newest file in the dir is wrong
          # when agents share a project dir).
          if [ "$(cat /proc/$pid/comm 2>/dev/null)" = claude ] && command -v jq >/dev/null 2>&1; then
            res=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -oE -- '--resume [0-9a-f-]{36}' | head -1 | awk '{print $2}')
            ccfg=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1)
            ccfg=${ccfg:-$HOME/.claude}
            cenc=$(readlink "/proc/$pid/cwd" 2>/dev/null | sed 's#/#-#g')
            lf="$ccfg/projects/$cenc/$res.jsonl"
            if [ -n "$res" ] && [ -f "$lf" ]; then
              ev=$(tail -n 1 "$lf" 2>/dev/null | jq -r '(.type)+"/"+(.subtype // "")' 2>/dev/null)
              echo "log $ev $(( $(date +%s) - $(stat -c %Y "$lf" 2>/dev/null) ))"
            fi
          fi
          # Codex session log — structural only. The process keeps its rollout
          # JSONL open, so its fd gives the exact active file; the verdict is the
          # last task_started/task_complete (only those tokens are read, never
          # message content). Emitted per pane like the screen verdict.
          if [ "$(cat /proc/$pid/comm 2>/dev/null)" = codex ] && command -v jq >/dev/null 2>&1 && command -v tac >/dev/null 2>&1; then
            cpane=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
            crf=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -oE '/[^ ]*/sessions/[0-9]+/[0-9]+/[0-9]+/rollout-[^ ]*\\.jsonl' | head -1)
            if [ -n "$cpane" ] && [ -n "$crf" ]; then
              # Scan from the end for the last turn boundary (task_started =
              # working; task_complete / turn_aborted = idle). A fixed tail
              # window is unreliable: a long turn can have hundreds of events
              # after its task_started. grep -m1 stops jq at the first match.
              cev=$(tac "$crf" 2>/dev/null | jq -r 'select(.type=="event_msg") | .payload.type' 2>/dev/null | grep -m 1 -E '^(task_started|task_complete|turn_aborted)$')
              cage=$(( $(date +%s) - $(stat -c %Y "$crf" 2>/dev/null) ))
              case "$cev" in
                task_started) echo "@@logstate $cpane working $cage" ;;
                task_complete|turn_aborted) echo "@@logstate $cpane idle $cage" ;;
              esac
            fi
          fi
        done
        echo "@@section screens"
        # Background activity needs only a status, not the conversation. The
        # screen is read here on the server and reduced to working/idle/unknown;
        # no screen content leaves the container. (The full screen is sent only
        # when the user opens a terminal to view it.)
        printf '%s\\n' "$procs" | awk '$6 ~ /^(codex|claude|node|bun|deno)$/ { print $1 }' | sort -u | head -n \(maxAgentCandidates) | while read -r pane; do
          [ -n "$pane" ] || continue
          scr=$(tm capture-pane -p -t "$pane" 2>/dev/null | tail -n 24)
          if printf '%s' "$scr" | grep -qiE '…[[:space:]]*\\([0-9]+[[:space:]]*[hms]|esc to interrupt'; then st=working
          elif printf '%s' "$scr" | grep -qE '· Ready ·|^[[:space:]]*(❯|›)'; then st=idle
          else st=unknown; fi
          echo "@@screenstate $pane $st"
        done
        echo "@@end \(nonce)"

        """
    }

    /// Parses the output of `RemoteCommand.script` running `script(tmux:nonce:)`.
    public static func parse(_ output: String, nonce: String) throws -> InventorySnapshot {
        var snapshot = InventorySnapshot()
        var section: String?
        var begun = false
        var ended = false
        var currentAgent: Int?
        var sessionNames: [String: String] = [:]
        var windowNames: [String: String] = [:]
        var paneRows: [String: InventorySnapshot.Pane] = [:]
        var paneOrder: [String] = []
        var textFields: [String: [String: String]] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !begun {
                if let rest = line.dropPrefix("@@container ") {
                    snapshot.container = parseContainer(rest)
                } else if line == "@@begin 1 \(nonce)" {
                    begun = true
                } else if !line.isEmpty {
                    // Anything else before the marker (a login banner, a shell
                    // rc printing) means stdout is not ours to parse.
                    throw RemoteFailure(.protocolDesync, detail: "unexpected output before probe: \(line)")
                }
                continue
            }
            if line == "@@end \(nonce)" {
                ended = true
                break
            }
            if let rest = line.dropPrefix("@@uid ") {
                snapshot.uid = Int(rest)
            } else if let rest = line.dropPrefix("@@os ") {
                snapshot.osID = rest.isEmpty ? nil : rest
            } else if let rest = line.dropPrefix("@@tmux ") {
                snapshot.tmuxVersion = rest
            } else if let rest = line.dropPrefix("@@server ") {
                snapshot.server = parseServer(rest)
            } else if let rest = line.dropPrefix("@@error ") {
                if rest == "tmux-not-found" {
                    snapshot.failure = RemoteFailure(.tmuxNotFound)
                } else if let message = rest.dropPrefix("tmux-server ") {
                    snapshot.failure = RemoteFailure.classifyTmuxServerError(message)
                } else if rest == "ps-unavailable" {
                    snapshot.processTableAvailable = false
                }
            } else if let rest = line.dropPrefix("@@section ") {
                section = rest
                currentAgent = nil
            } else if let rest = line.dropPrefix("@@screenstate ") {
                let fields = rest.split(separator: " ")
                if fields.count == 2, isID(fields[0], "%") { snapshot.screenStates[String(fields[0])] = String(fields[1]) }
            } else if let rest = line.dropPrefix("@@logstate ") {
                let fields = rest.split(separator: " ")
                if fields.count >= 2, isID(fields[0], "%") { snapshot.logStates[String(fields[0])] = String(fields[1]) }
            } else if let rest = line.dropPrefix("@@agent ") {
                currentAgent = Int(rest)
                if let pid = currentAgent {
                    snapshot.agents[pid] = InventorySnapshot.AgentEvidence(
                        pid: pid, executable: "", arguments: [], environment: [:], startTicks: nil
                    )
                }
            } else if line.isEmpty {
                continue
            } else if section == "agents", let pid = currentAgent {
                parseAgentLine(line, into: &snapshot.agents[pid]!)
            } else {
                switch section {
                case "memberships":
                    if let row = parseMembership(line) { snapshot.memberships.append(row) }
                case "panes":
                    if let pane = parsePane(line), paneRows[pane.id] == nil {
                        paneRows[pane.id] = pane
                        paneOrder.append(pane.id)
                    }
                case "session_name":
                    if let (id, value) = splitIDValue(line, prefix: "$") { sessionNames[id] = value }
                case "window_name":
                    if let (id, value) = splitIDValue(line, prefix: "@") { windowNames[id] = value }
                case "pane_current_command", "pane_current_path", "pane_title":
                    if let (id, value) = splitIDValue(line, prefix: "%") { textFields[section!, default: [:]][id] = value }
                case "processes":
                    if let node = parseProcess(line) { snapshot.processes.append(node) }
                default:
                    break
                }
            }
        }

        guard begun else {
            throw RemoteFailure(.protocolDesync, detail: "probe did not start")
        }
        guard ended else {
            throw RemoteFailure(.protocolDesync, detail: "probe output ended early")
        }

        var seenSessions = Set<String>()
        var seenWindows = Set<String>()
        for row in snapshot.memberships {
            if seenSessions.insert(row.sessionID).inserted {
                snapshot.sessions.append(.init(id: row.sessionID, name: sessionNames[row.sessionID] ?? ""))
            }
            if seenWindows.insert(row.windowID).inserted {
                snapshot.windows.append(.init(id: row.windowID, name: windowNames[row.windowID] ?? ""))
            }
        }
        snapshot.panes = paneOrder.compactMap { id in
            guard var pane = paneRows[id] else { return nil }
            pane.currentCommand = textFields["pane_current_command"]?[id] ?? ""
            pane.currentPath = textFields["pane_current_path"]?[id] ?? ""
            pane.title = textFields["pane_title"]?[id] ?? ""
            return pane
        }
        return snapshot
    }

    // MARK: - Line parsers

    private static func parseContainer(_ text: String) -> InventorySnapshot.Container? {
        let fields = text.split(separator: " ")
        guard fields.count == 4, let pid = Int(fields[3]) else { return nil }
        return .init(id: String(fields[0]), status: String(fields[1]), startedAt: String(fields[2]), pid: pid)
    }

    private static func parseServer(_ text: String) -> InventorySnapshot.Server? {
        let fields = text.split(separator: " ", maxSplits: 2)
        guard fields.count == 3, let pid = Int(fields[0]), let start = Int(fields[1]) else { return nil }
        return .init(pid: pid, startTime: start, socketPath: String(fields[2]))
    }

    private static func parseMembership(_ line: String) -> InventorySnapshot.Membership? {
        let f = line.split(separator: " ")
        guard f.count == 7,
              isID(f[0], "$"), isID(f[1], "@"), isID(f[2], "%"),
              let windowIndex = Int(f[3]), let paneIndex = Int(f[4])
        else { return nil }
        return .init(
            sessionID: String(f[0]), windowID: String(f[1]), paneID: String(f[2]),
            windowIndex: windowIndex, paneIndex: paneIndex,
            paneActive: f[5] == "1", windowActive: f[6] == "1"
        )
    }

    private static func parsePane(_ line: String) -> InventorySnapshot.Pane? {
        let f = line.split(separator: " ")
        guard f.count == 5, isID(f[0], "%"),
              let pid = Int(f[1]), let width = Int(f[3]), let height = Int(f[4])
        else { return nil }
        return .init(
            id: String(f[0]), pid: pid, dead: f[2] == "1", width: width, height: height,
            currentCommand: "", currentPath: "", title: ""
        )
    }

    private static func parseProcess(_ line: String) -> InventorySnapshot.ProcessNode? {
        let f = line.split(separator: " ", maxSplits: 5)
        guard f.count == 6, isID(f[0], "%"),
              let depth = Int(f[1]), let pid = Int(f[2]), let ppid = Int(f[3])
        else { return nil }
        return .init(
            paneID: String(f[0]), depth: depth, pid: pid, ppid: ppid,
            state: String(f[4]), command: String(f[5])
        )
    }

    private static func parseAgentLine(_ line: String, into evidence: inout InventorySnapshot.AgentEvidence) {
        if let rest = line.dropPrefix("exe ") {
            evidence.executable = rest
        } else if line == "exe" {
            evidence.executable = ""
        } else if let rest = line.dropPrefix("arg ") {
            evidence.arguments.append(rest)
        } else if let rest = line.dropPrefix("env ") {
            if let equals = rest.firstIndex(of: "=") {
                evidence.environment[String(rest[..<equals])] = String(rest[rest.index(after: equals)...])
            }
        } else if let rest = line.dropPrefix("start ") {
            evidence.startTicks = Int(rest)
        } else if let rest = line.dropPrefix("log ") {
            let fields = rest.split(separator: " ")
            if let event = fields.first { evidence.logEvent = String(event) }
            if fields.count > 1 { evidence.logAgeSeconds = Int(fields[1]) }
        }
    }

    /// `<id> <value>`: the id is checked, the value is the rest of the line.
    private static func splitIDValue(_ line: String, prefix: Character) -> (String, String)? {
        guard let space = line.firstIndex(of: " ") else {
            return isID(Substring(line), prefix) ? (line, "") : nil
        }
        let id = line[..<space]
        guard isID(id, prefix) else { return nil }
        return (String(id), String(line[line.index(after: space)...]))
    }

    private static func isID(_ text: Substring, _ prefix: Character) -> Bool {
        text.first == prefix && text.count > 1 && text.dropFirst().allSatisfy(\.isASCII) && text.dropFirst().allSatisfy(\.isNumber)
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

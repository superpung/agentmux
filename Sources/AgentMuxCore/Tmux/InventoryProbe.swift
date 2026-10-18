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
        # Panes whose activity we already know from the session log; the screen
        # is not captured for these, which keeps tmux load (and any risk of a
        # tmux bug) low. A plain for-loop so logpanes survives each iteration.
        logpanes=" "
        # Precompute how many distinct Codex TUI panes share each (CODEX_HOME,
        # cwd). A TUI is a codex process bound to a tmux pane that is not the
        # shared app-server/daemon. When two or more share one home+cwd, a
        # single shared app-server holds all their rollouts with no per-pane
        # link, so a rollout found by fd cwd-match can't be tied to the right
        # pane; such panes are flagged ambiguous below and get no log/usage.
        codextui=$(for q in $(printf '%s\\n' "$procs" | awk '$6=="codex"{print $3}'); do
          case "$(tr '\\0' ' ' < "/proc/$q/cmdline" 2>/dev/null)" in *app-server*|*daemon*) continue ;; esac
          qpane=$(tr '\\0' '\\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
          [ -n "$qpane" ] || continue
          qcwd=$(readlink "/proc/$q/cwd" 2>/dev/null)
          qch=$(tr '\\0' '\\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
          echo "${qch:-$HOME/.codex}|$qcwd|$qpane"
        done | sort -u)
        # Rollouts held open by shared Codex app-servers, as "home|cwd|mtime|path".
        # Newer Codex keeps the live session's rollout in a shared app-server the
        # TUI does not hold, so a pane with no fd of its own still finds its
        # session here by (CODEX_HOME, cwd). Only session_meta.cwd is read.
        codexsrv=$(for q in $(printf '%s\\n' "$procs" | awk '$6=="codex"{print $3}'); do
          case "$(tr '\\0' ' ' < "/proc/$q/cmdline" 2>/dev/null)" in *app-server*) ;; *) continue ;; esac
          qch=$(tr '\\0' '\\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
          qch=${qch:-$HOME/.codex}
          ls -l "/proc/$q/fd" 2>/dev/null | grep -oE '/[^ ]*/sessions/[0-9]+/[0-9]+/[0-9]+/rollout-[^ ]*\\.jsonl' | sort -u | while read -r rf; do
            [ -f "$rf" ] || continue
            mc=$(head -n 1 "$rf" 2>/dev/null | jq -r '.payload.cwd // .cwd // empty' 2>/dev/null)
            [ -n "$mc" ] && echo "$qch|$mc|$(stat -c %Y "$rf" 2>/dev/null)|$rf"
          done
        done)
        for pid in $(printf '%s\\n' "$procs" | awk '$5 !~ /^Z/ && $6 ~ /^(codex|claude|node|bun|deno)$/ { print $3 }' | head -n \(maxAgentCandidates)); do
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
            # Resumed via the picker (no --resume id on the cmdline) or started
            # fresh: Claude does not keep the transcript fd open, so locate the
            # active one as the newest .jsonl in the pane's project dir.
            { [ -z "$res" ] || [ ! -f "$lf" ]; } && lf=$(ls -t "$ccfg/projects/$cenc/"*.jsonl 2>/dev/null | head -n 1)
            if [ -n "$lf" ] && [ -f "$lf" ]; then
              clpane=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
              # Follow Claude's continuation chain. When a resumed session is
              # compacted it writes {"type":"continued-in","continuedInSessionId":
              # "<next>"} right after its last real turn and moves new turns to
              # <next>, while the old file keeps only bookkeeping and the --resume
              # id on the cmdline stays stale. Read the file once (reversed) to get
              # the last real turn AND any continuation pointer (the awk stops at
              # the first turn from the end, so idle/non-continued files cost the
              # same as before), hopping to the live successor so active/usage/
              # model are not read from the stale file. Timestamps/ids only.
              rts=""; re=""; hop=0
              while [ -f "$lf" ] && [ "$hop" -lt 10 ]; do
                chain=$(tac "$lf" 2>/dev/null | jq -rc 'if .type=="continued-in" then "C "+(.continuedInSessionId // "") elif (.type=="assistant" or .type=="user") then "T "+(.timestamp // "") else empty end' 2>/dev/null | awk '/^C /{c=$2} /^T /{print "T "$2; print "C "c; exit}')
                rts=$(echo "$chain" | sed -n 's/^T //p')
                re=$(date -d "$rts" +%s 2>/dev/null)
                { [ -n "$re" ] && [ $(( $(date +%s) - re )) -lt 3600 ]; } && break
                nxt=$(echo "$chain" | sed -n 's/^C //p')
                [ -n "$nxt" ] || break
                nf="$ccfg/projects/$cenc/$nxt.jsonl"
                { [ -f "$nf" ] && [ "$nf" != "$lf" ]; } || break
                lf="$nf"; hop=$((hop+1))
              done
              lage=$(( $(date +%s) - $(stat -c %Y "$lf" 2>/dev/null) ))
              ev=$(tail -n 1 "$lf" 2>/dev/null | jq -r '(.type)+"/"+(.subtype // "")' 2>/dev/null)
              echo "log $ev $lage"
              # A definitive Claude log event means we need no screen fallback.
              case "$ev" in */turn_duration|assistant/*|user/*) [ -n "$clpane" ] && logpanes="$logpanes$clpane " ;; esac
              [ -n "$clpane" ] && [ -n "$re" ] && echo "@@active $clpane $(( $(date +%s) - re ))"
              # Context size = the last assistant turn's prompt (input + cached +
              # cache-creation tokens), from a bounded tail. Numbers only.
              cctx=$(tail -n 200 "$lf" 2>/dev/null | jq -r 'select(.type=="assistant") | ((.message.usage.input_tokens // 0)+(.message.usage.cache_read_input_tokens // 0)+(.message.usage.cache_creation_input_tokens // 0))' 2>/dev/null | grep -E '^[0-9]+$' | tail -n 1)
              [ -n "$clpane" ] && [ -n "$cctx" ] && [ "$cctx" -gt 0 ] && echo "@@usage $clpane $cctx - -"
              # Current model + reasoning effort = the last assistant turn's
              # fields (metadata only), emitted as "<model> <effort>".
              cmodel=$(tail -n 200 "$lf" 2>/dev/null | jq -r 'select(.type=="assistant") | (.message.model // "-")+" "+(.perTurnEffort // .effort // "-")' 2>/dev/null | grep -v '^- ' | tail -n 1)
              [ -n "$clpane" ] && [ -n "$cmodel" ] && echo "@@model $clpane $cmodel"
            fi
          fi
          # Codex session log — structural only. The process keeps its rollout
          # JSONL open, so its fd gives the exact active file. One bounded tail +
          # one jq pass extracts both the last turn boundary (task_started =
          # working; task_complete / turn_aborted = idle) and the last
          # token_count usage. A boundary older than the window yields no verdict
          # and falls back to the screen rule; reading only the last 500 lines
          # keeps the probe fast on multi-MB rollouts.
          if [ "$(cat /proc/$pid/comm 2>/dev/null)" = codex ] && command -v jq >/dev/null 2>&1; then
            cpane=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
            # Newer Codex runs a shared `codex app-server` daemon that holds the
            # rollout fds of several live sessions at once — including other
            # panes' — while the TUI itself holds none. Tie the rollout to this
            # pane by the session's own working dir (session_meta.cwd = the
            # process cwd) and, among matches, the most recently written file.
            # But cwd is not unique: when two Codex TUIs share a CODEX_HOME and
            # cwd, the shared daemon's rollouts can't be mapped back to a pane,
            # and "newest" would hand an idle pane its busy sibling's rollout.
            # So skip fd-based attribution when this (home,cwd) has >1 TUI; only
            # the resume-id path below (unambiguous) is kept, and activity then
            # comes from the per-pane title spinner / screen instead. Only the
            # cwd field is read, never content.
            pcwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
            pch=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
            nsib=$(printf '%s\\n' "$codextui" | awk -F'|' -v h="${pch:-$HOME/.codex}" -v c="$pcwd" '$1==h && $2==c{print $3}' | sort -u | wc -l)
            crf=""
            if [ "${nsib:-0}" -le 1 ]; then
              crf=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -oE '/[^ ]*/sessions/[0-9]+/[0-9]+/[0-9]+/rollout-[^ ]*\\.jsonl' | sort -u | while read -r rf; do
                [ -f "$rf" ] && [ -n "$pcwd" ] || continue
                mcwd=$(head -n 1 "$rf" 2>/dev/null | jq -r '.payload.cwd // .cwd // empty' 2>/dev/null)
                [ "$mcwd" = "$pcwd" ] && stat -c '%Y %n' "$rf" 2>/dev/null
              done | sort -rn | head -n 1 | cut -d' ' -f2-)
              # The TUI holds no rollout fd (newer Codex): find the live session
              # in a shared app-server by (CODEX_HOME, cwd). Unambiguous here
              # because nsib<=1 means only this pane uses that home+cwd.
              if [ -z "$crf" ]; then
                crf=$(printf '%s\\n' "$codexsrv" | awk -F'|' -v h="${pch:-$HOME/.codex}" -v c="$pcwd" '$1==h && $2==c {print $3" "$4}' | sort -rn | head -n 1 | cut -d' ' -f2-)
              fi
            fi
            # No matching rollout fd (e.g. the TUI process holds none): locate
            # the file by the `resume <id>` on its cmdline — accurate per pane,
            # which also avoids reading another session's data by mistake.
            if [ -z "$crf" ]; then
              crid=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -oE 'resume [0-9a-f-]{36}' | head -1 | awk '{print $2}')
              cch=$(tr '\\0' '\\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
              cch=${cch:-$HOME/.codex}
              [ -n "$crid" ] && crf=$(find "$cch/sessions" -name "rollout-*-$crid.jsonl" 2>/dev/null | head -1)
            fi
            if [ -n "$cpane" ] && [ -n "$crf" ]; then
              cage=$(( $(date +%s) - $(stat -c %Y "$crf" 2>/dev/null) ))
              # Last active = the last real turn event, not the file mtime (Codex
              # keeps appending thread_settings_applied while idle). Falls back
              # to mtime if none is found. Only timestamps are read.
              rts=$(tac "$crf" 2>/dev/null | jq -r 'select((.type=="event_msg" and (.payload.type=="task_started" or .payload.type=="task_complete" or .payload.type=="turn_aborted" or .payload.type=="agent_message" or .payload.type=="item_completed")) or .type=="response_item") | .timestamp // empty' 2>/dev/null | head -n 1)
              re=$(date -d "$rts" +%s 2>/dev/null)
              if [ -n "$re" ]; then echo "@@active $cpane $(( $(date +%s) - re ))"; else echo "@@active $cpane $cage"; fi
              recent=$(tail -n 500 "$crf" 2>/dev/null | jq -rc 'if .type=="event_msg" and (.payload.type=="task_started" or .payload.type=="task_complete" or .payload.type=="turn_aborted") then "T "+.payload.type elif .type=="event_msg" and .payload.type=="token_count" then "U \\(.payload.info.last_token_usage.input_tokens // 0) \\(.payload.info.model_context_window // 0) \\(.payload.rate_limits.primary.used_percent // "-")" else empty end' 2>/dev/null)
              cst=$(case "$(printf '%s\\n' "$recent" | grep '^T ' | tail -n 1)" in *task_started) echo working ;; *task_complete|*turn_aborted) echo idle ;; esac)
              [ -n "$cst" ] && { echo "@@logstate $cpane $cst $cage"; logpanes="$logpanes$cpane "; }
              uvals=$(printf '%s\\n' "$recent" | grep '^U ' | tail -n 1 | cut -d' ' -f2-)
              [ -n "$uvals" ] && echo "@@usage $cpane $uvals"
              # Model: session_meta first line is cheapest; fall back to the most
              # recent turn_context in a bounded tail for sessions whose model
              # changed mid-run. Metadata only.
              cmodel=$(head -n 1 "$crf" 2>/dev/null | jq -r '.payload.model? // .payload.base_instructions.provenance.model? // empty' 2>/dev/null)
              [ -z "$cmodel" ] && cmodel=$(tail -n 3000 "$crf" 2>/dev/null | jq -r 'select((.payload.type?)=="turn_context") | .payload.model? // empty' 2>/dev/null | grep -v '^$' | tail -n 1)
              # Effort = the configured reasoning effort for this CODEX_HOME.
              ceffort=$(grep -E '^[[:space:]]*model_reasoning_effort' "${pch:-$HOME/.codex}/config.toml" 2>/dev/null | head -n 1 | sed 's/.*=[[:space:]]*//; s/["[:space:]]//g')
              [ -n "$cmodel" ] && echo "@@model $cpane $cmodel ${ceffort:--}"
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
          # Skip panes whose activity the session log already settled — no need
          # to capture the screen for them.
          case "$logpanes" in *" $pane "*) continue ;; esac
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
            } else if let rest = line.dropPrefix("@@active ") {
                let f = rest.split(separator: " ")
                if f.count >= 2, isID(f[0], "%"), let seconds = Int(f[1]) {
                    snapshot.lastActiveSeconds[String(f[0])] = seconds
                }
            } else if let rest = line.dropPrefix("@@usage ") {
                let f = rest.split(separator: " ")
                if f.count >= 4, isID(f[0], "%") {
                    snapshot.usage[String(f[0])] = InventorySnapshot.AgentUsage(
                        contextTokens: Int(f[1]).flatMap { $0 > 0 ? $0 : nil },
                        contextWindow: Int(f[2]).flatMap { $0 > 0 ? $0 : nil },
                        rateLimitPercent: Double(f[3])
                    )
                }
            } else if let rest = line.dropPrefix("@@model ") {
                let f = rest.split(separator: " ")
                if f.count >= 2, isID(f[0], "%") {
                    snapshot.models[String(f[0])] = String(f[1])
                    if f.count >= 3, f[2] != "-" { snapshot.efforts[String(f[0])] = String(f[2]) }
                }
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

import Foundation

/// Types a short message into an agent's prompt and submits it, for the
/// auto-continue after an error. It holds off while anyone is typing in that
/// window and refuses when the pane has dropped back to a shell, where the
/// text would run as a command.
public enum AgentNudge {
    public enum Outcome: String, Sendable, Equatable {
        case sent
        /// A terminal showing this window had keyboard input within the quiet
        /// period. Control-mode clients (AgentMux's own mirrors) only set
        /// their activity on attach, so the app checks its mirrors itself.
        case busy
        /// The pane is gone or runs a shell now.
        case gone
        /// The agent's input line holds text the user has not sent, which
        /// the message would be appended to and submit with.
        case draft
    }

    public static let maxMessageLength = 500

    public static func send(_ message: String, host: HostConfig, target: TargetConfig, paneID: String,
                            quietSeconds: Int = 30) async -> Result<Outcome, RemoteFailure> {
        let tmux: TmuxInvocation
        do { tmux = try target.executionContext().tmux }
        catch { return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)")) }
        guard let script = script(message, paneID: paneID, quietSeconds: quietSeconds, tmux: tmux.argv) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid pane id or message"))
        }
        return await RemoteScript.run(script, host: host, target: target, timeoutSeconds: 20).flatMap(parse)
    }

    /// The shell script behind `send`, or nil for a bad pane id or message
    /// (empty, multi-line or too long).
    static func script(_ message: String, paneID: String, quietSeconds: Int, tmux argv: [String]) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TmuxQuote.id(paneID) != nil, paneID.hasPrefix("%"),
              !text.isEmpty, text.count <= maxMessageLength, !text.contains(where: \.isNewline) else { return nil }
        let tm = ShellQuote.command(argv)
        return """
        pane=\(ShellQuote.word(paneID))
        msg=\(ShellQuote.word(text))
        cmd=$(\(tm) display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || { echo "GONE"; exit 0; }
        case "$cmd" in ""|bash|zsh|sh|dash|ash|fish|tcsh|csh|ksh|-*) echo "GONE"; exit 0 ;; esac
        # Someone typed into this window recently, in a terminal attached to it.
        win=$(\(tm) display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
        now=$(date +%s)
        recent=$(\(tm) list-clients -F '#{client_activity} #{window_id}' 2>/dev/null | awk -v w="$win" -v n="$now" -v q=\(quietSeconds) '$2==w && n-$1<q' | head -n 1)
        [ -n "$recent" ] && { echo "BUSY"; exit 0; }
        # Unsent text in the input line (the last "❯" / "›" prompt line). Dim
        # text there is the agent's own placeholder or suggestion, not a draft,
        # so it is dropped with the escape codes. Claude pads its prompt with a
        # no-break space, which `tr` in the container's C locale does not count
        # as space. Only this verdict leaves.
        esc=$(printf '\\033')
        nbsp=$(printf '\\302\\240')
        draft=$(\(tm) capture-pane -e -p -t "$pane" 2>/dev/null | awk '/^(\\033\\[[0-9;:]*m)*[[:space:]]*(❯|›)/{l=$0} END{print l}' | sed -e "s/${esc}\\[2m[^${esc}]*//g" -e "s/${esc}\\[[0-9;:]*m//g" -e "s/${nbsp}//g" -e 's/❯//; s/›//' | tr -d '[:space:]')
        [ -n "$draft" ] && { echo "DRAFT"; exit 0; }
        \(tm) send-keys -t "$pane" -l -- "$msg" || { echo "ERR: could not type the message"; exit 1; }
        # A separate Enter, so the TUI takes the text as typed, not pasted.
        sleep 0.3
        \(tm) send-keys -t "$pane" Enter
        echo "SENT"
        """
    }

    static func parse(_ output: String) -> Result<Outcome, RemoteFailure> {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("SENT") { return .success(.sent) }
        if lines.contains("BUSY") { return .success(.busy) }
        if lines.contains("GONE") { return .success(.gone) }
        if lines.contains("DRAFT") { return .success(.draft) }
        let detail = lines.last(where: { $0.hasPrefix("ERR:") }).map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return .failure(RemoteFailure(.remoteCommandFailed, detail: detail ?? (output.isEmpty ? "no output" : output)))
    }
}

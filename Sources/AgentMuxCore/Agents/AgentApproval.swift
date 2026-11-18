import Foundation

/// Structural approval evidence only. Terminal text stays in the container.
public enum AgentApproval {
    public struct Agent: Sendable, Equatable {
        public var pid: Int
        public var startTicks: Int
        public init(pid: Int, startTicks: Int) { self.pid = pid; self.startTicks = startTicks }
    }

    public struct Request: Sendable, Equatable {
        public var agent: Agent
        public var fingerprint: String
        public var dialogID: String
        public init(agent: Agent, fingerprint: String, dialogID: String? = nil) {
            self.agent = agent; self.fingerprint = fingerprint; self.dialogID = dialogID ?? fingerprint
        }
    }

    public static func parse(_ text: String) -> (pane: String, request: Request)? {
        let f = text.split(separator: " ")
        guard f.count == 5, TmuxQuote.id(String(f[0])) != nil, f[0].hasPrefix("%"),
              let pid = Int(f[1]), pid > 0, let ticks = Int(f[2]), ticks > 0,
              f[3].count == 64, f[3].allSatisfy({ $0.isASCII && $0.isHexDigit }),
              f[4].count == 64, f[4].allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return (String(f[0]), Request(agent: Agent(pid: pid, startTicks: ticks), fingerprint: String(f[3]), dialogID: String(f[4])))
    }

    /// One Python process for all requested panes, alongside the normal probe.
    static func probeScript(tmux: [String], agents: [String: Agent]) -> String {
        let specs = agents.sorted { $0.key < $1.key }.map { ["pane": $0.key, "pid": String($0.value.pid), "ticks": String($0.value.startTicks)] }
        return "if command -v python3 >/dev/null 2>&1; then\n"
            + script(tmux: tmux, arguments: ["probe", json(specs)]) + "fi\n"
    }

    public static func approve(_ request: Request, host: HostConfig, target: TargetConfig,
                               pane: String, serverPID: Int, serverStart: Int) async -> Result<String, RemoteFailure> {
        guard TmuxQuote.id(pane) != nil, pane.hasPrefix("%"), request.agent.pid > 0,
              request.agent.startTicks > 0, serverPID > 0, serverStart > 0, request.fingerprint.count == 64,
              request.fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid approval identity"))
        }
        do {
            let tmux = try target.executionContext().tmux.argv
            let args = ["approve", pane, String(request.agent.pid), String(request.agent.startTicks),
                        request.fingerprint, String(serverPID), String(serverStart)]
            return await RemoteScript.run(script(tmux: tmux, arguments: args), host: host, target: target,
                                          timeoutSeconds: 12).flatMap(parseOutcome)
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "invalid approval target"))
        }
    }

    static func parseOutcome(_ output: String) -> Result<String, RemoteFailure> {
        // The common Docker runner prepends @@container metadata. Keep the
        // protocol verdict separate, just as AgentNudge.parse does.
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("@@container ") }
        guard lines.count == 1, let result = lines.first,
              ["APPROVED", "CHANGED", "UNAVAILABLE"].contains(result) else {
            return .failure(RemoteFailure(.protocolDesync, detail: "invalid approval response"))
        }
        return .success(result)
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    static func script(tmux: [String], arguments: [String]) -> String {
        "python3 - " + ([json(tmux)] + arguments).map(ShellQuote.word).joined(separator: " ")
            + " <<'__AGENTMUX_APPROVAL__'\n" + program + "\n__AGENTMUX_APPROVAL__\n"
    }

    static let program = #"""
import hashlib, json, os, re, subprocess, sys, time
from pathlib import Path

CLAUDE_EXPIRY = re.compile(
    r'(?:⚠\ufe0f?\s*)?Claude Code will automatically block this request in '
    r'(?P<remaining>[0-9]+:[0-5][0-9]), to avoid holding up an unattended session'
)

def claude_bash_frame(raw, lines, notice, width):
    # The native expiry notice sits after the closed command preview, just
    # before the question. Identify it there so lookalike command text still
    # participates in the fingerprint.
    expiry = CLAUDE_EXPIRY.fullmatch(lines[notice])
    if not expiry:
        return None
    headers = [i for i in range(1, notice) if lines[i] == 'Bash command' and raw[i-1] == '─' * width]
    if len(headers) != 1:
        return None
    start = headers[0]
    rules = [i for i in range(start+1, notice)
             if len(raw[i]) == width and re.fullmatch(r'[-─━┄┅┈┉╌╍]+', raw[i])]
    if len(rules) != 2 or not any(lines[rules[0]+1:rules[1]]):
        return None
    a, b = expiry.span('remaining')
    raw[notice] = lines[notice][:a] + '<time>' + lines[notice][b:]
    return start

def parse_screen(text, claude_width=0):
    # Require an active selection, a known approval question and its footer.
    # Ordinary conversation containing Yes/No is never an approval signal.
    raw = [re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', s).rstrip() for s in text.splitlines()]
    lines = [line.lstrip() for line in raw]
    footers = [i for i,s in enumerate(lines) if re.search(r'^esc to cancel(?:\s|$|[·•])', s, re.I)]
    if not footers:
        return None
    end = footers[-1]
    if any(s and not re.match(r'^[─━—-]{3}', s) for s in lines[end+1:]):
        return None
    questions = {'Do you want to proceed?', 'Would you like to run the following command?',
                 'Would you like to make the following edits?'}
    starts = [i for i,s in enumerate(lines[:end]) if s in questions]
    if not starts:
        return None
    question = starts[-1]
    options = []
    option_rows = []
    for index in range(question+1, end):
        s = lines[index]
        match = re.match(r'^(?P<cursor>[❯›>])?\s*(?:(?P<number>[1-9])\.\s+)?(?P<label>.+)$', s)
        if not match:
            continue
        label = match['label'].strip()
        if match['number'] or match['cursor'] or label in ('Yes', 'No'):
            options.append((label, bool(match['cursor']), match['number']))
            option_rows.append(index)
    if not 2 <= len(options) <= 4:
        return None
    # Numbered menus must be consecutive; mixed/partial menus are refused.
    numbers = [x[2] for x in options]
    if any(numbers) and numbers != [str(i+1) for i in range(len(options))]:
        return None
    yes = [i for i,(label,_,_) in enumerate(options) if label in ('Yes', 'Yes (y)', 'Yes, proceed', 'Yes, proceed (y)')]
    selected = [i for i,(_,cursor,_) in enumerate(options) if cursor]
    if len(yes) != 1 or len(selected) != 1 or not any(re.match(r'^No(?:\b|,)', x[0]) for x in options):
        return None
    # Claude can repaint outside the dialog and update its native expiry
    # timer during approval. Keep the command preview and options stable
    # across those redraws only when the dialog boundary is recognizable.
    start = 0
    notice = next((i for i in range(question-1, -1, -1) if lines[i]), -1)
    if claude_width >= 20 and notice >= 0 and lines[question] == 'Do you want to proceed?':
        if lines[notice] == "Auto mode can't check actions in this session, so this one needs your approval":
            rules = [i for i in range(notice) if raw[i] == '─' * claude_width]
            if len(rules) == 1 and any(lines[rules[0]+1:notice]):
                start = rules[0]+1
        else:
            start = claude_bash_frame(raw, lines, notice, claude_width) or 0
    # Preserve the actual action (including indentation), while treating the
    # same option with or without its selection marker as identical content.
    for index in option_rows:
        raw[index] = re.sub(r'^[❯›>]\s*', '', lines[index])
    normalized = '\n'.join(raw[start:end+1])
    return dict(token=hashlib.sha256(normalized.encode()).hexdigest(), yes=yes[0], selected=selected[0])

def process(pid, proc=Path('/proc')):
    try:
        p = proc/str(pid)
        f = (p/'stat').read_text().rsplit(')',1)[1].split()
        return dict(pid=int(pid), ppid=int(f[1]), pgrp=int(f[2]), foreground=int(f[5]),
                    ticks=int(f[19]), alive=f[0] not in ('Z','X'), name=(p/'comm').read_text().strip())
    except (OSError, ValueError, IndexError):
        return None

def belongs_to(pid, root):
    for _ in range(32):
        if pid == root:
            return True
        p = process(pid)
        if not p or p['ppid'] <= 1 or p['ppid'] == pid:
            return False
        pid = p['ppid']
    return False

def tm(argv, *args):
    return subprocess.check_output(argv+list(args), stderr=subprocess.DEVNULL, timeout=2).decode('utf-8','replace')

def inspect(argv, pane, pid, ticks, server=None, quiet=0):
    fields = tm(argv,'display-message','-p','-t',pane,'#{pid} #{start_time} #{pane_pid} #{window_id} #{pane_width}').split()
    if len(fields) != 5 or (server and fields[:2] != list(map(str,server))):
        return None
    p = process(pid)
    if not p or not p['alive'] or p['ticks'] != ticks or p['name'] not in ('claude','codex'):
        return None
    if p['pgrp'] != p['foreground'] or not belongs_to(pid,int(fields[2])):
        return None
    clients = tm(argv,'list-clients','-F','#{client_activity} #{window_id} #{client_control_mode}')
    activity = max([int(f[0]) for line in clients.splitlines() if len(f:=line.split())==3
                    and f[1]==fields[3] and f[2]=='0' and f[0].isdigit()]+[0])
    if quiet and activity and time.time()-activity < quiet:
        return None
    # Scrollback can grow during a cursor-only redraw (CSI 2J). Bind the
    # current viewport, so history churn does not change the active request.
    screen = tm(argv,'capture-pane','-p','-J','-t',pane)
    state = parse_screen(screen, int(fields[4]) if p['name'] == 'claude' else 0)
    if state:
        state['base'] = state['token']
        state['activity'] = activity
        state['token'] = hashlib.sha256((state['base']+':'+str(state['selected'])+':'+str(activity)).encode()).hexdigest()
    return state

def approve(argv, pane, pid, ticks, token, server):
    state = inspect(argv,pane,pid,ticks,server,quiet=5)
    if not state or state['token'] != token:
        return 'CHANGED'
    base, activity = state['base'], state['activity']
    # Move only toward the exact one-time Yes option; never choose a setting
    # that remembers permission. Recheck the screen and process after each key.
    for _ in range(4):
        if state['selected'] == state['yes']:
            # Final fresh check, even if the cursor was already on Yes.
            final = inspect(argv,pane,pid,ticks,server,quiet=5)
            if not final or final['base'] != base or final['activity'] != activity or final['selected'] != final['yes']:
                return 'CHANGED'
            tm(argv,'send-keys','-t',pane,'Enter')
            return 'APPROVED'
        step = 1 if state['yes'] > state['selected'] else -1
        destination = state['selected']+step
        tm(argv,'send-keys','-t',pane,'Down' if step > 0 else 'Up')
        deadline = time.monotonic()+0.8
        while True:
            state = inspect(argv,pane,pid,ticks,server,quiet=5)
            if state and (state['base'] != base or state['activity'] != activity):
                return 'CHANGED'
            if state and state['selected'] == destination:
                break
            if time.monotonic() >= deadline:
                return 'CHANGED'
            time.sleep(0.04)
    return 'CHANGED'

def main(args):
    argv = json.loads(args[0])
    mode = args[1]
    if mode == 'probe':
        for spec in json.loads(args[2]):
            try:
                state = inspect(argv,spec['pane'],int(spec['pid']),int(spec['ticks']))
                if state:
                    print('@@approval',spec['pane'],spec['pid'],spec['ticks'],state['token'],state['base'])
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
    elif mode == 'approve':
        try:
            print(approve(argv,args[2],int(args[3]),int(args[4]),args[5],(int(args[6]),int(args[7]))))
        except (OSError, ValueError, subprocess.SubprocessError):
            print('UNAVAILABLE')

if __name__ == '__main__':
    main(sys.argv[1:])
"""#
}

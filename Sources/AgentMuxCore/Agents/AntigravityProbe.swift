import Foundation

/// Reads the summary of the conversation a live agy process has open.
/// The probe sends no transcript content or credentials back to the app.
enum AntigravityProbe {
    struct Session: Decodable, Sendable, Equatable {
        let pane: String
        let start: Int
        let directory: String?
        let title: String?
        let age: Int?
        let state: String?
        let model: String?
        let effort: String?
        let version: String?
        let contextPercent: Double?
    }

    static func apply(_ sessions: [Int: Session], to snapshot: inout InventorySnapshot) {
        let detections = AgentDetector.detect(snapshot)
        for (pane, detection) in detections where detection.kind == .antigravity {
            guard let pid = detection.pid, let session = sessions[pid],
                  session.pane == pane, detection.startTicks == session.start else { continue }
            snapshot.conversationTitles[pane] = session.title
            snapshot.lastActiveSeconds[pane] = session.age
            snapshot.logStates[pane] = session.state
            snapshot.models[pane] = session.model
            snapshot.efforts[pane] = session.effort
            snapshot.agents[pid]?.antigravityDirectory = session.directory
            snapshot.agents[pid]?.antigravityVersion = session.version
            if let percent = session.contextPercent, (0...100).contains(percent) {
                snapshot.usage[pane] = InventorySnapshot.AgentUsage(contextPercent: percent)
            }
        }
    }

    static let reader = #"""
    import datetime, json, math, os, re, sqlite3, subprocess, sys, time
    from pathlib import Path

    candidates, *tmux = sys.argv[1:]
    uuid = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    footer = re.compile(
        r'\s*(?:\? for shortcuts|esc to cancel)\s{2,}(?:auto|default|plan|accept[ -]edits)\s+·\s+'
        r'(?P<model>[\w][\w .:+()/\-]{0,79}?)(?:\s+·\s+(?P<effort>minimal|low|medium|high|xhigh|max))?\s*',
        re.IGNORECASE,
    )

    def process_state(proc):
        fields = (proc/'stat').read_text().rsplit(')', 1)[1].split()
        if fields[0] in ('Z', 'X') or (proc/'comm').read_text().strip() != 'agy':
            return None
        return int(fields[19]), fields[2] == fields[5]

    def text(value, limit):
        if isinstance(value, str):
            return ' '.join(value.split())[:limit] or None
        return None

    def active_age(value):
        if not value:
            return None
        try:
            cleaned = re.sub(r'(\.\d{6})\d+', r'\1', value.replace('Z', '+00:00'))
            when = datetime.datetime.fromisoformat(cleaned)
            if when.tzinfo is None or when.year < 2000:
                return None
            seconds = time.time() - when.timestamp()
            return int(max(0, seconds)) if seconds > -300 else None
        except (TypeError, ValueError, OverflowError):
            return None

    def conversation_id(proc, config):
        ids = set()
        for fd in (proc/'fd').iterdir():
            try:
                path = Path(os.readlink(fd))
            except OSError:
                continue
            if path.parent == config/'presence' and path.suffix == '.lock' and uuid.fullmatch(path.stem):
                ids.add(path.stem)
        return next(iter(ids)) if len(ids) == 1 else None

    def summary(config, ident):
        database = config/'conversation_summaries.db'
        if not database.is_file():
            return None
        db = sqlite3.connect(database.as_uri()+'?mode=ro', uri=True, timeout=.2)
        try:
            return db.execute(
                'SELECT title, last_modified_time, status, not_fully_idle '
                'FROM conversation_summaries WHERE conversation_id = ?', (ident,),
            ).fetchone()
        finally:
            db.close()

    def sidecar(home, pane, pid, start, ident):
        path = home/'.agentmux'/'agy-status'/(ident+'.json')
        try:
            if path.stat().st_size > 16384:
                return None
            data = json.loads(path.read_text())
            if (not isinstance(data, dict) or data.get('pane') != pane
                    or data.get('pid') != pid or data.get('start') != start
                    or data.get('conversation') != ident):
                return None
            return data
        except (OSError, ValueError):
            return None

    def native_footer(pane):
        screen = subprocess.check_output(
            [*tmux, 'capture-pane', '-p', '-t', pane], text=True, errors='replace',
            stderr=subprocess.DEVNULL, timeout=1,
        )
        values = {(match['model'], match['effort'])
                  for line in screen.splitlines()[-28:]
                  if (match := footer.fullmatch(line))}
        return next(iter(values)) if len(values) == 1 else (None, None)

    def inspect(pane, pid):
        proc = Path('/proc')/str(pid)
        original = process_state(proc)
        if original is None:
            return
        start, foreground = original
        env = dict(field.split(b'=', 1) for field in (proc/'environ').read_bytes().split(b'\0') if b'=' in field)
        if env.get(b'TMUX_PANE') != pane.encode():
            return
        home = Path(os.fsdecode(env.get(b'HOME', b'')))
        if not home.is_absolute():
            return
        config = home/'.gemini'/'antigravity-cli'
        result = {'pane': pane, 'start': start}
        if config.is_dir():
            result['directory'] = str(config)
            ident = conversation_id(proc, config)
            if ident:
                try:
                    row = summary(config, ident)
                except (OSError, sqlite3.Error):
                    row = None
                if row:
                    title, modified, status, busy = row
                    result['title'] = text(title, 240)
                    result['age'] = active_age(modified)
                    if status == 'CASCADE_RUN_STATUS_IDLE' and busy == 0:
                        result['state'] = 'idle'
                    elif status == 'CASCADE_RUN_STATUS_RUNNING' and busy == 1:
                        result['state'] = 'working'
                if status := sidecar(home, pane, pid, start, ident):
                    result.update(model=text(status.get('model'), 80),
                                  effort=text(status.get('effort'), 24),
                                  version=text(status.get('version'), 40))
                    n = status.get('contextPercent')
                    if type(n) in (int, float) and math.isfinite(n) and 0 <= n <= 100:
                        result['contextPercent'] = n
        if foreground and not result.get('model'):
            try:
                result['model'], result['effort'] = native_footer(pane)
            except (OSError, subprocess.SubprocessError):
                pass
        if process_state(proc) == original:
            print('@@antigravity', pid, json.dumps(result, ensure_ascii=True, separators=(',', ':')))

    for line in candidates.splitlines():
        pane, pid = line.split()
        if re.fullmatch(r'%\d+', pane) and pid.isdecimal():
            try:
                inspect(pane, int(pid))
            except (OSError, ValueError, IndexError, sqlite3.Error):
                continue
    """#
}

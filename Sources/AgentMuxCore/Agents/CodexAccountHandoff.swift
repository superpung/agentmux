import Foundation

/// Account credentials follow CODEX_HOME; verified conversation state follows
/// the source runtime. Keep this program self-contained for remote execution.
enum CodexAccountHandoff {
    static func script(tmux: [String], paneID: String, pid: Int, cwd: String, target: String) -> String {
        let tmuxJSON = String(data: try! JSONEncoder().encode(tmux), encoding: .utf8)!
        let args = [tmuxJSON, paneID, String(pid), cwd, target].map(ShellQuote.word).joined(separator: " ")
        return "python3 - " + args + " <<'__AGENTMUX_CODEX_HANDOFF__'\n" + program + "\n__AGENTMUX_CODEX_HANDOFF__\n"
    }

    static let program = #"""
# Runs only for an explicitly requested account switch, never during polling.
import base64, contextlib, fcntl, hashlib, itertools, json, os, re, secrets, shlex, signal, socket, sqlite3, struct, subprocess, sys, time, uuid
from pathlib import Path

class HandoffError(Exception):
    pass

def thread_id(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        return None

def process(pid, proc=Path('/proc')):
    p = proc / str(pid)
    try:
        fields = (p / 'stat').read_text().rsplit(')', 1)[1].split()
        with (p / 'cmdline').open('rb') as f:
            args = [os.fsdecode(a) for a in f.read(16384).split(b'\0') if a]
        env = dict(v.split(b'=', 1) for v in (p / 'environ').read_bytes().split(b'\0') if b'=' in v)
        return dict(pid=int(pid), ppid=int(fields[1]), ticks=int(fields[19]), zombie=fields[0]=='Z',
                    args=args, home=os.fsdecode(env.get(b'CODEX_HOME', b'')) or str(Path.home()/'.codex'),
                    state=os.fsdecode(env.get(b'AGENTMUX_CODEX_SQLITE_HOME', b'')),
                    cwd=os.readlink(p/'cwd'), exe=os.readlink(p/'exe'))
    except (OSError, ValueError, IndexError):
        return None

def codex_processes(proc=Path('/proc')):
    result = []
    for p in itertools.islice(proc.iterdir(), 8192):
        if not p.name.isdigit():
            continue
        try:
            if (p/'comm').read_text().strip() != 'codex':
                continue
            info = process(p.name, proc)
            if info and not info['zombie']:
                result.append(info)
        except OSError:
            continue
    return result

def descends(pid, root, proc=Path('/proc')):
    for _ in range(32):
        if pid == root:
            return True
        p = process(pid, proc)
        if not p or p['ppid'] <= 1 or p['ppid'] == pid:
            return False
        pid = p['ppid']
    return False

def open_files(pid, proc=Path('/proc')):
    try:
        for f in (proc/str(pid)/'fd').iterdir():
            try:
                p = Path(os.readlink(f))
                if p.is_absolute() and p.is_file():
                    yield p.resolve()
            except OSError:
                continue
    except OSError:
        return

def metadata(path):
    try:
        with Path(path).open('rb') as f:
            record = json.loads(f.readline(1048576))
        p = record.get('payload', {})
        if record.get('type') == 'session_meta' and thread_id(p.get('id')):
            return dict(id=thread_id(p['id']), cwd=p.get('cwd'), source=p.get('source'))
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    raise HandoffError('Cannot verify the source conversation metadata.')

def resume_id(args):
    if 'resume' not in args:
        return None
    i = args.index('resume')
    return thread_id(args[i+1]) if i+1 < len(args) else None

def select_rollout(paths, cwd, expected=None):
    matches = {}
    for p in paths:
        if p.suffix != '.jsonl' or not p.name.startswith('rollout-'):
            continue
        m = metadata(p)
        if m['cwd'] == cwd and not isinstance(m['source'], dict):
            matches[str(p.resolve())] = m['id']
    if len(matches) != 1:
        raise HandoffError('Cannot identify one live conversation for this pane; no account was changed.')
    path, sid = next(iter(matches.items()))
    if expected and sid != expected:
        raise HandoffError('The running conversation differs from the launch ID; no account was changed.')
    return sid, path

def indexed_rollout(db, sid):
    try:
        with contextlib.closing(sqlite3.connect(Path(db).as_uri()+'?mode=ro', uri=True, timeout=2)) as c:
            c.execute('PRAGMA query_only=ON')
            row = c.execute('SELECT rollout_path FROM threads WHERE id=?', (sid,)).fetchone()
        if row and Path(row[0]).is_file():
            return str(Path(row[0]).resolve())
    except sqlite3.Error:
        pass
    raise HandoffError('Cannot verify the source conversation index; no account was changed.')

def command(home, state, executable, sid):
    # Credentials/config remain in the selected home. All SQLite state, including
    # paginated history, stays with the source. A fresh server bypasses stale caches.
    return ' '.join(['CODEX_HOME='+shlex.quote(home),
                     'AGENTMUX_CODEX_SQLITE_HOME='+shlex.quote(state),
                     shlex.quote(executable), '--no-daemon', '-c',
                     shlex.quote('sqlite_home='+json.dumps(state)), '-c',
                     'thread_unload_delay_secs=0', 'resume', shlex.quote(sid)])

def preflight(tmux, pane, pid, cwd, target):
    source = process(pid)
    if not source or not source['args'] or 'codex' not in Path(source['exe']).name:
        raise HandoffError('The Codex process is no longer available.')
    root = int(subprocess.check_output(tmux+['display-message','-p','-t',pane,'#{pane_pid}'], timeout=3))
    if not descends(pid, root):
        raise HandoffError('The Codex process is no longer in this pane.')
    if not Path(target).is_dir() or Path(target).resolve() == Path(source['home']).resolve():
        raise HandoffError('The target account directory is missing or already selected.')
    processes = codex_processes()
    children = [p for p in processes if p['pid'] != pid and descends(p['pid'], pid)]
    servers = [p for p in children if 'app-server' in p['args']]
    if not servers:
        servers = [p for p in processes if p['home']==source['home'] and 'app-server' in p['args']
                   and 'pid-update-loop' not in p['args']]
    owners = servers or [source]
    paths = {p for owner in owners for p in open_files(owner['pid'])}
    sid, rollout = select_rollout(paths, cwd, resume_id(source['args']))
    databases = {p for p in paths if re.fullmatch(r'state_[0-9]+\.sqlite', p.name)}
    if not databases:
        # Idle native servers close SQLite connections. Check the declared
        # state home against the exact live rollout rather than scanning disk.
        state=source['state'] or source['home']
        for i,arg in enumerate(source['args'][:-1]):
            if arg in ['-c','--config'] and source['args'][i+1].startswith('sqlite_home='):
                value=source['args'][i+1].split('=',1)[1]
                try:state=json.loads(value)
                except ValueError:state=value
        databases={p.resolve() for p in Path(state).glob('state_*.sqlite')
                   if re.fullmatch(r'state_[0-9]+\.sqlite',p.name)}
    if len(databases) != 1:
        raise HandoffError('Cannot identify one source state database; no account was changed.')
    db = next(iter(databases))
    if indexed_rollout(db, sid) != rollout:
        raise HandoffError('The source server and index disagree; no account was changed.')
    # A second TUI for this thread must not keep the old writer alive after exit.
    for p in processes:
        shared=(p['home'] in [source['home'],target] or p['state']==str(db.parent)
                or (Path(p['home'])/'sessions').resolve()==(Path(source['home'])/'sessions').resolve())
        if shared and p['pid'] != pid and 'app-server' not in p['args'] and resume_id(p['args']) == sid:
            raise HandoffError('This conversation is also open in another terminal; close that view before switching.')
        if p['home'] == target and p['pid'] != pid:
            for f in open_files(p['pid']):
                if f.name.startswith('rollout-') and f.suffix=='.jsonl' and metadata(f)['id']==sid:
                    raise HandoffError('The target account still has this conversation loaded; close that view before switching.')
    executable = owners[0]['exe']
    help_text = subprocess.check_output([executable,'resume','--help'], timeout=5, stderr=subprocess.DEVNULL).decode()
    if '--no-daemon' not in help_text:
        raise HandoffError('This Codex version cannot isolate account switching; update Codex first.')
    return dict(source=source, sid=sid, rollout=rollout, db=str(db), state=str(db.parent),
                target=target, executable=executable, root=root, owners=[p['pid'] for p in owners],
                managed=not bool(children) and bool(servers))

class SourceControl:
    """Metadata-only JSON-RPC over the daemon's local Unix WebSocket."""
    def __init__(self, plan):
        self.socket=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        self.serial=0
        self.archived_sid=None
        try:
            endpoint=Path(plan['source']['home'])/'app-server-control/app-server-control.sock'
            self.socket.connect(str(endpoint))
            key=base64.b64encode(secrets.token_bytes(16)).decode()
            request=('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                     'Connection: Upgrade\r\nSec-WebSocket-Key: '+key+
                     '\r\nSec-WebSocket-Version: 13\r\n\r\n')
            self.socket.sendall(request.encode())
            header=b''
            while not header.endswith(b'\r\n\r\n') and len(header)<8192:
                header+=self.read(1)
            accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            if not header.startswith(b'HTTP/1.1 101 ') or accept not in header:
                raise HandoffError('The source daemon does not support a verified account handoff.')
            self.call('initialize', {'clientInfo':{'name':'agentmux-account-handoff','version':'1.0'},
                                     'capabilities':{'experimentalApi':True}})
            result=self.call('thread/resume', {'threadId':plan['sid'], 'path':plan['rollout'],
                              'excludeTurns':True})
            t=result.get('thread',{})
            if t.get('id')!=plan['sid'] or not t.get('path') or str(Path(t['path']).resolve())!=plan['rollout']:
                raise HandoffError('The source daemon did not confirm the exact conversation.')
        except Exception:
            self.close()
            raise

    def read(self, length):
        data=b''
        while len(data)<length:
            if hasattr(self,'deadline'):
                self.socket.settimeout(max(.01,self.deadline-time.monotonic()))
            chunk=self.socket.recv(length-len(data))
            if not chunk:
                raise HandoffError('The source daemon closed the handoff connection.')
            data+=chunk
        return data

    def frame(self, payload, opcode=1):
        length=len(payload)
        prefix=bytes([128|opcode,128|length]) if length<126 else bytes([128|opcode,254])+struct.pack('!H',length)
        mask=secrets.token_bytes(4)
        self.socket.sendall(prefix+mask+bytes(v^mask[i%4] for i,v in enumerate(payload)))

    def message(self):
        data=b''
        while True:
            first,length=self.read(2)
            size=length&127
            if size==126:
                size=struct.unpack('!H',self.read(2))[0]
            elif size==127:
                size=struct.unpack('!Q',self.read(8))[0]
            if size+len(data)>1048576 or length&128:
                raise HandoffError('Invalid source daemon handoff response.')
            payload=self.read(size)
            opcode=first&15
            if opcode==9:
                self.frame(payload,10)
                continue
            if opcode==8:
                raise HandoffError('The source daemon closed the handoff connection.')
            if opcode not in [0,1]:
                raise HandoffError('Invalid source daemon handoff response.')
            data+=payload
            if first&128:
                return json.loads(data)

    def call(self, method, params, timeout=5):
        self.serial+=1
        self.deadline=time.monotonic()+timeout
        self.frame(json.dumps({'id':self.serial,'method':method,'params':params}).encode())
        end=self.deadline
        while time.monotonic()<end:
            response=self.message()
            if 'method' in response and 'id' in response:
                raise HandoffError('The source daemon requested input during the handoff.')
            if response.get('id')==self.serial:
                if 'error' in response:
                    raise HandoffError('The source daemon refused the conversation handoff.')
                return response.get('result',{})
        raise HandoffError('The source daemon did not acknowledge the conversation handoff.')

    def release(self, sid):
        self.call('thread/unsubscribe', {'threadId':sid})
        # A shared daemon's unload timer is server-wide; per-resume config does
        # not change it. Native archive/unarchive synchronously closes only this
        # thread, flushes its writer and restores its original visible state.
        self.archived_sid=sid
        self.call('thread/archive', {'threadId':sid}, timeout=20)
        self.call('thread/unarchive', {'threadId':sid}, timeout=10)
        self.archived_sid=None

    def close(self):
        try:
            if self.archived_sid:
                self.call('thread/unarchive', {'threadId':self.archived_sid}, timeout=10)
                self.archived_sid=None
        finally:
            try:
                self.frame(b'',8)
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.socket.close()

def same_process(source):
    now = process(source['pid'])
    return now and not now['zombie'] and now['ticks']==source['ticks']

def send(tmux, pane, text):
    def shell_ready():
        foreground=subprocess.check_output(tmux+['display-message','-p','-t',pane,'#{pane_current_command}'],timeout=3).decode().strip()
        return foreground in ['bash','zsh','fish','sh','dash','ksh','nu']
    # tmux may briefly report the exited foreground process until its next refresh.
    if not wait_until(shell_ready,3):
        raise HandoffError('The pane is not at a shell prompt; no launch command was typed.')
    subprocess.run(tmux+['send-keys','-t',pane,'C-u'], check=True, timeout=3)
    subprocess.run(tmux+['send-keys','-t',pane,'-l',text], check=True, timeout=3)
    subprocess.run(tmux+['send-keys','-t',pane,'Enter'], check=True, timeout=3)

def wait_until(predicate, seconds):
    end = time.monotonic()+seconds
    while time.monotonic()<end:
        if predicate():
            return True
        time.sleep(.2)
    return False

def writer_released(plan):
    return all(plan['rollout'] != str(f) for pid in plan['owners'] for f in open_files(pid))

def verified_processes(plan):
    candidates = [p for p in codex_processes() if p['home']==plan['target']
                  and resume_id(p['args'])==plan['sid'] and '--no-daemon' in p['args']
                  and p['state']==plan['state'] and descends(p['pid'], plan['root'])]
    if len(candidates)!=1:
        return []
    tui=candidates[0]
    servers=[p for p in codex_processes() if descends(p['pid'], tui['pid'])]
    files={f for p in servers for f in open_files(p['pid'])}
    if Path(plan['db']) not in files:
        return []
    try:
        current=indexed_rollout(plan['db'], plan['sid'])
        if Path(current) not in files or metadata(current)['id']!=plan['sid']:
            return []
    except HandoffError:
        return []
    return [tui]

def switch(plan, tmux, pane):
    source=plan['source']
    if not same_process(source):
        raise HandoffError('The source process changed before switching; nothing was stopped.')
    print('HANDOFF '+json.dumps({k:plan[k] for k in ['sid','rollout','state','target']}), flush=True)
    control=SourceControl(plan) if plan['managed'] else None
    try:
        try:
            if not same_process(source):
                raise HandoffError('The source process changed during handoff preparation.')
            os.kill(source['pid'], signal.SIGTERM)
            if not wait_until(lambda:not same_process(source), 5):
                raise HandoffError('Codex has not exited; the target account was not started.')
            if control:
                control.release(plan['sid'])
        finally:
            if control:
                control.close()
        if not wait_until(lambda:writer_released(plan), 12):
            raise HandoffError('The previous server still owns the conversation.')
        # Re-read after shutdown so the final flushed record, not a pre-exit
        # checkpoint, is the one the new account resumes through the shared DB.
        current=indexed_rollout(plan['db'], plan['sid'])
        if metadata(current)['id']!=plan['sid']:
            raise HandoffError('The source index changed unexpectedly.')
        send(tmux, pane, command(plan['target'],plan['state'],plan['executable'],plan['sid']))
        if not wait_until(lambda:bool(verified_processes(plan)), 20):
            raise HandoffError('Could not verify the target account opened the source conversation.')
    except Exception as error:
        # Never report a typed command as success. Restore the original account
        # only if no replacement TUI occupies the pane; never type into an agent.
        live=[p for p in codex_processes() if 'app-server' not in p['args'] and descends(p['pid'],plan['root'])]
        if not live:
            restore='CODEX_HOME='+shlex.quote(source['home'])+' '
            if source['state']:
                restore+='AGENTMUX_CODEX_SQLITE_HOME='+shlex.quote(source['state'])+' '
            restore+=shlex.join(source['args'])
            send(tmux,pane,restore)
            raise HandoffError(str(error)+' The original account was reopened.')
        raise HandoffError(str(error)+' Check the terminal; the switch was not confirmed.')
    print('OK: '+plan['sid'], flush=True)

def main(args):
    check = '--check' in args
    if check:
        args.remove('--check')
    tmux, pane, pid, cwd, target = json.loads(args[0]),args[1],int(args[2]),args[3],args[4]
    plan=preflight(tmux,pane,pid,cwd,target)
    if check:
        print(json.dumps({k:plan[k] for k in ['sid','rollout','state','target']}, sort_keys=True))
    else:
        directory=Path.home()/'.local/state/agentmux/account-switches'
        directory.mkdir(parents=True,exist_ok=True,mode=0o700)
        key=hashlib.sha256(json.dumps([tmux,pane]).encode()).hexdigest()
        with (directory/(key+'.lock')).open('a') as lock:
            try:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                raise HandoffError('An account switch is already in progress for this pane.')
            switch(plan,tmux,pane)

if __name__=='__main__':
    try:
        main(sys.argv[1:])
    except Exception as e:
        print('ERR: '+str(e), flush=True)
        print('ERR: '+str(e), file=sys.stderr, flush=True)
        sys.exit(1)
"""#
}

#!/usr/bin/env python3
"""Keep UUID resumes on one verified Codex runtime across linked accounts."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import tomllib
import uuid


class ResumeConflict(Exception):
    pass


ROLLOUT = re.compile(
    r"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-"
    r"([0-9a-f-]{36})(?:_([0-9a-f-]{36}))?\.jsonl"
)


def canonical_uuid(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        return None


def resume_uuid(args):
    # Remote sessions and explicit config overrides already choose a runtime.
    if len(args) < 2 or args[0] != "resume":
        return None
    for arg in args[2:]:
        if arg == "--":
            break
        if arg.startswith(("--remote", "--config", "-c", "--profile", "-p")):
            return None
    return canonical_uuid(args[1])


def state_directory(home):
    config = home / "config.toml"
    if not config.is_file():
        return home
    with config.open("rb") as source:
        configured = tomllib.load(source).get("sqlite_home")
    if configured is None:
        return home
    directory = Path(configured).expanduser()
    if not directory.is_absolute():
        raise ResumeConflict(f"Cannot verify a relative sqlite_home in {config}.")
    return directory.resolve()


def accounts_for(user_home, account, sessions):
    directories = set(user_home.glob(".codex*")) | {account}
    return sorted({p.resolve() for p in directories if (p / "sessions").resolve() == sessions})


def open_index(directory):
    databases = sorted(
        (p for p in directory.glob("state_*.sqlite") if re.fullmatch(r"state_\d+\.sqlite", p.name)),
        key=lambda p: int(p.stem.split("_")[1]),
        reverse=True,
    )
    if not databases:
        return None
    db = sqlite3.connect(databases[0].as_uri() + "?mode=ro", uri=True, timeout=0.5)
    db.execute("PRAGMA query_only=ON")
    return db


def indexed_rollout(directory, thread):
    database = open_index(directory)
    if database is None:
        return None
    with contextlib.closing(database) as db:
        row = db.execute("SELECT rollout_path, archived FROM threads WHERE id=?", (thread,)).fetchone()
    if row is None:
        return None
    if row[1]:
        raise ResumeConflict(f"{thread} is archived in {directory}. Check the account's state first.")
    if not row[0]:
        raise ResumeConflict(f"The thread index in {directory} has no rollout path.")
    path = Path(row[0])
    if not path.is_absolute():
        raise ResumeConflict(f"Cannot verify a relative rollout path in {directory}.")
    return logical_path(path)


def logical_path(path):
    path = path.resolve()
    return path.with_suffix("") if path.name.endswith(".jsonl.zst") else path


def stored_rollout(path):
    return path if path.is_file() else Path(str(path) + ".zst")


def metadata(path, thread):
    with path.open("rb") as file:
        raw = file.readline(4 * 1024 * 1024)
    record = json.loads(raw)
    payload = record["payload"]
    if not raw.endswith(b"\n") or record["type"] != "session_meta" or payload["id"] != thread:
        raise ResumeConflict(f"Rollout identity or metadata could not be verified in {path.name}.")
    return payload


def rollout_files(sessions, thread):
    # Rollouts live in sessions/YYYY/MM/DD. A glob at that depth does not
    # follow arbitrary directories nested below the documented layout.
    return {path for p in sessions.glob(f"*/*/*/rollout-*-{thread}*.jsonl*")
            if (match := ROLLOUT.fullmatch(p.name.removesuffix(".zst"))) and match[2] == thread
            and (path := logical_path(p)).is_relative_to(sessions)}


def valid_boundary(parent, thread, offset, ordinal):
    metadata(parent, thread)
    with parent.open("rb") as file:
        if offset > os.fstat(file.fileno()).st_size:
            return False
        width = min(offset, 4096)
        while True:
            file.seek(offset - width)
            data = file.read(width)
            if not data.endswith(b"\n"):
                return False
            boundary = data.rfind(b"\n", 0, -1)
            if boundary >= 0 or width == offset:
                previous = json.loads(data[boundary+1:])
                return previous.get("ordinal") == ordinal - 1
            if width >= 16 * 1024 * 1024:
                return False
            width = min(width * 2, offset)


def lineage(tip, paths, thread):
    """Return verified ancestors without guessing by recency or file size."""
    writers = {}
    for path in paths:
        match = ROLLOUT.fullmatch(path.name)
        if match and match[2] == thread:
            writers.setdefault(match[3] or thread, set()).add(path)
    visited = {tip}
    while True:
        base = metadata(tip, thread).get("history_base")
        if base is None:
            return visited
        offset = base["end_byte_offset"]
        ordinal = base["end_ordinal_exclusive"]
        if not isinstance(offset, int) or not isinstance(ordinal, int) or offset <= 0 or ordinal <= 0:
            raise ResumeConflict("Invalid Codex continuation boundary.")
        parents = {p for p in writers.get(base["thread_id"], ())
                   if valid_boundary(p, thread, offset, ordinal)}
        if len(parents) != 1 or parents & visited:
            raise ResumeConflict(f"Cannot verify one continuation parent for {tip.name}.")
        tip = parents.pop()
        visited.add(tip)


def choose_route(indexes, sessions, thread, current, pinned=None, known=()):
    available = rollout_files(sessions, thread)
    if not indexes:
        if len(available) > 1:
            raise ResumeConflict("Multiple rollout files exist and no account indexes this thread.")
        return None
    if any(not p.is_relative_to(sessions) for p in indexes.values()):
        raise ResumeConflict("The indexed rollout is outside the shared sessions directory.")
    indexed = set(indexes.values())
    available |= indexed
    active = indexes.get(pinned)
    # A verified pin can outlive an account's old index and the immutable
    # segments kept by a repair. A new path, or an older file that changed,
    # must participate in lineage verification again.
    contenders = available - set(known)
    contenders |= {active} if active else indexed
    if len(contenders) == 1:
        selected = next(iter(contenders))
    else:
        tips = [p for p in indexed & contenders if contenders <= lineage(p, available, thread)]
        if len(tips) != 1:
            raise ResumeConflict("Rollout files disagree. Verify the continuation before resuming.")
        selected = tips[0]
    if selected not in indexed:
        raise ResumeConflict("The selected rollout has no verified account index.")
    if selected.is_file():
        metadata(selected, thread)
    elif not stored_rollout(selected).is_file():
        raise ResumeConflict(f"The indexed rollout is missing: {selected.name}.")
    # Keep a stable runtime for repeat resumes. When no runtime was pinned,
    # prefer the user's own index, then use a verified matching account.
    for directory in [pinned, current, *sorted(indexes)]:
        if indexes.get(directory) == selected:
            return directory
    raise ResumeConflict("No verified runtime indexes the selected history.")


@contextlib.contextmanager
def lock(file, message):
    fd = os.open(file, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ResumeConflict(message) from None
        yield


def check_native_writers(accounts, thread):
    for account in accounts:
        file = account / "thread-writer-locks" / f"{thread}.lock"
        if not file.exists():
            continue
        try:
            with file.open("rb") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ResumeConflict(f"This thread still has a Codex writer in {account}. Close it before resuming.") from None
        except FileNotFoundError:
            # Native Codex cleans up its lock when the writer exits.
            continue


def fingerprint(path):
    value = stored_rollout(path).stat()
    return [value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns]


def write_pin(path, route, files):
    verified = {str(p): fingerprint(p) for p in files if stored_rollout(p).is_file()}
    data = json.dumps({"sqlite_home": str(route), "verified_rollouts": verified})
    atomic_write(path, (data + "\n").encode(), 0o600)


def registry(user_home, sessions, thread):
    state = user_home / ".local/state/agentmux/codex-resume"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    key = hashlib.sha256(os.fsencode(sessions) + b"\0" + thread.encode()).hexdigest()
    return state / (key + ".json"), state / (key + ".lock")


def launch_codex(binary, arguments, runtime):
    environment = dict(os.environ, AGENTMUX_CODEX_SQLITE_HOME=str(runtime))
    environment.pop("AGENTMUX_CODEX_HANDOFF", None)
    environment.pop("AGENTMUX_CODEX_REAL", None)
    command = [str(binary), "--no-daemon", "-c", "sqlite_home=" + json.dumps(str(runtime)),
               "-c", "thread_unload_delay_secs=0", *arguments]
    child = subprocess.Popen(command, env=environment)
    def forward(signum, _):
        if signum != signal.SIGINT and child.poll() is None:
            child.send_signal(signum)
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {s: signal.signal(s, forward) for s in signals}
    try:
        code = child.wait()
        return code if code >= 0 else 128 - code
    finally:
        for s, handler in previous.items():
            signal.signal(s, handler)


def atomic_write(path, body, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
        staging = Path(file.name)
        try:
            file.write(body)
            file.flush()
            os.fchmod(file.fileno(), mode)
            os.fsync(file.fileno())
            staging.replace(path)
        finally:
            staging.unlink(missing_ok=True)


def install(user_home):
    destination = user_home / ".local/lib/agentmux/bin/codex"
    destination.parent.mkdir(parents=True, exist_ok=True)
    binary = user_home / ".local/bin/codex"
    if not os.access(binary, os.X_OK):
        raise ResumeConflict(f"Cannot find Codex at {binary}.")
    # Bind to the interpreter that successfully loaded tomllib. Some Macs
    # also ship a different python3 first on a non-interactive shell's PATH.
    interpreter = shutil.which("python3") or sys.executable
    if subprocess.run([interpreter, "-c", "import tomllib"], capture_output=True).returncode:
        interpreter = sys.executable
    source = Path(__file__).read_bytes().partition(b"\n")[2]
    atomic_write(destination, b"#!" + os.fsencode(interpreter) + b"\n" + source, 0o755)
    marker = b"# >>> AgentMux Codex resume guard >>>"
    block = b'''
# >>> AgentMux Codex resume guard >>>
case "$PATH" in
    "$HOME/.local/lib/agentmux/bin:"*) ;;
    *) export PATH="$HOME/.local/lib/agentmux/bin:$PATH" ;;
esac
# <<< AgentMux Codex resume guard <<<
'''
    login = next((user_home / n for n in (".bash_profile", ".bash_login", ".profile")
                  if (user_home / n).is_file()), user_home / ".profile")
    dotdir = user_home
    if zsh := shutil.which("zsh"):
        result = subprocess.run([zsh, "-c", 'printf "%s\\n" "${ZDOTDIR:-$HOME}"'],
                                capture_output=True, text=True, timeout=6)
        lines = result.stdout.splitlines()
        if result.returncode == 0 and lines:
            candidate = Path(lines[-1]).expanduser()
            if candidate.is_dir() and candidate.resolve().is_relative_to(user_home.resolve()):
                dotdir = candidate
    profiles = {login, user_home / ".bashrc", dotdir / ".zprofile", dotdir / ".zshrc"}
    backups = user_home / ".local/state/agentmux/codex-resume-install"
    for profile in sorted({p.resolve() for p in profiles}):
        if profile.exists():
            body, mode = profile.read_bytes(), stat.S_IMODE(profile.stat().st_mode)
        else:
            body, mode = b"", 0o644
        if marker not in body:
            if profile.is_file():
                backups.mkdir(mode=0o700, parents=True, exist_ok=True)
                key = hashlib.sha256(os.fsencode(profile)).hexdigest()[:12]
                backup = backups / f"{key}-{profile.name}"
                if not backup.exists():
                    atomic_write(backup, body, 0o600)
            prefix = body if not body or body.endswith(b"\n") else body + b"\n"
            atomic_write(profile, prefix + block, mode)
    print(destination)
    return 0


def run(args, user_home):
    binary = Path(os.environ.get("AGENTMUX_CODEX_REAL", str(user_home / ".local/bin/codex")))
    if binary.resolve() == Path(__file__).resolve() or not os.access(binary, os.X_OK):
        raise ResumeConflict("Set AGENTMUX_CODEX_REAL to the installed Codex binary.")
    thread = resume_uuid(args)
    if thread is None:
        os.execv(binary, [str(binary), *args])
    account = Path(os.environ.get("CODEX_HOME", str(user_home / ".codex"))).expanduser().resolve()
    sessions = (account / "sessions").resolve()
    accounts = accounts_for(user_home, account, sessions)
    override = os.environ.get("AGENTMUX_CODEX_SQLITE_HOME")
    inherited = (Path(override).resolve()
                 if override and os.environ.get("AGENTMUX_CODEX_HANDOFF") == thread else None)
    if len(accounts) < 2 or not sessions.is_dir():
        if inherited:
            return launch_codex(binary, args, inherited)
        os.execv(binary, [str(binary), *args])
    config = state_directory(account)
    pin, lease = registry(user_home, sessions, thread)
    with lock(lease, "This thread is already open through AgentMux's resume guard."):
        check_native_writers(accounts, thread)
        saved = json.loads(pin.read_text()) if pin.is_file() else {}
        pinned = Path(saved["sqlite_home"]).resolve() if saved else None
        known = {Path(raw) for raw, stamp in saved.get("verified_rollouts", {}).items()
                 if stored_rollout(Path(raw)).is_file() and fingerprint(Path(raw)) == stamp}
        runtimes = {state_directory(h) for h in accounts}
        # Account handoff has just verified its explicit source runtime.
        if inherited and inherited.is_dir():
            runtimes.add(inherited)
        if pinned and pinned.is_dir():
            runtimes.add(pinned)
        indexes = {d: p for d in runtimes if (p := indexed_rollout(d, thread)) is not None}
        chosen = choose_route(indexes, sessions, thread, config, inherited or pinned, known)
        if inherited and chosen != inherited:
            raise ResumeConflict("The verified handoff runtime no longer indexes the selected history.")
        runtime = chosen or config
        before = {p: fingerprint(p) for p in rollout_files(sessions, thread)}
        if chosen:
            write_pin(pin, chosen, before)
        status = launch_codex(binary, args, runtime)
        # A native restore/revert can publish a new segment. This guarded run
        # held the write lease, so keep that exact index as the renewed pin.
        final = indexed_rollout(runtime, thread)
        if final and final.is_relative_to(sessions) and final.is_file():
            metadata(final, thread)
            stable = {p for p, stamp in before.items()
                      if stored_rollout(p).is_file() and fingerprint(p) == stamp}
            write_pin(pin, runtime, stable | {final})
        return status


if __name__ == "__main__":
    try:
        if Path(__file__).name != "codex" and sys.argv[1:] == ["--install"]:
            raise SystemExit(install(Path.home()))
        raise SystemExit(run(sys.argv[1:], Path.home()))
    except (ResumeConflict, sqlite3.Error, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Codex resume guard: {exc}", file=sys.stderr)
        raise SystemExit(2)

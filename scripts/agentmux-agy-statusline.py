#!/usr/bin/env python3
"""Record Antigravity's live status for AgentMux while its built-in line renders."""
import json
import math
import os
import re
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile


def agy_process():
    pid = os.getppid()
    for _ in range(8):
        proc = Path('/proc') / str(pid)
        fields = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
        if (proc / 'comm').read_text().strip() == 'agy':
            return pid, int(fields[19])
        pid = int(fields[1])
        if pid <= 1:
            break
    return None


def string(value, limit):
    return ' '.join(value.split())[:limit] if isinstance(value, str) else None


def write_status():
    pane = os.environ.get('TMUX_PANE', '')
    if not re.fullmatch(r'%\d+', pane):
        return
    data = json.load(sys.stdin)
    session = data.get('conversation_id') or data.get('session_id')
    if not isinstance(session, str) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', session):
        return
    identity = agy_process()
    if identity is None:
        return
    pid, start = identity
    model = data.get('model') or {}
    context = (data.get('context_window') or {}).get('used_percentage')
    record = {
        'pane': pane, 'pid': pid, 'start': start, 'conversation': session,
        'version': string(data.get('version'), 40),
        'model': string(model.get('display_name') or model.get('id'), 80),
        'effort': string(model.get('effort'), 24),
    }
    if type(context) in (int, float) and math.isfinite(context) and 0 <= context <= 100:
        record['contextPercent'] = context
    directory = Path.home() / '.agentmux' / 'agy-status'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with NamedTemporaryFile(mode='w', dir=directory, delete=False) as output:
        tmp = Path(output.name)
        try:
            json.dump(record, output, allow_nan=False)
            output.close()
            tmp.replace(directory / (session + '.json'))
        finally:
            tmp.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        write_status()
    except (OSError, ValueError, TypeError, IndexError, AttributeError):
        pass

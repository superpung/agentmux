"""Exercise the actual embedded reader with disposable progress/proc fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/AgentMuxCore/Tmux/InventoryProbe.swift'
READER = textwrap.dedent(SOURCE.read_text().split('static let progressReader = #"""', 1)[1].split('"""#', 1)[0])
THREAD = '01a1c040-4e34-7163-8476-46a0e0be10be'


class ProgressReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agentmux-reader-test-')
        self.base = Path(self.temp.name)
        self.home = self.base / 'home'
        self.records = self.home / '.agentmux/progress'
        self.proc = self.base / 'proc'
        self.records.mkdir(parents=True)
        self.proc.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def record(self, key, directory=None, **fields):
        directory = directory or self.records
        directory.mkdir(parents=True, exist_ok=True)
        p = directory / (key + '.json')
        p.write_text(json.dumps(dict(label=key, state='running', pane='%168', **fields)))
        return p

    def wrapper(self, directory, pid='123', command='agentmux-progress'):
        p = self.proc / pid
        p.mkdir()
        (p / 'comm').write_text('python3\n')
        (p / 'cmdline').write_bytes(b'python3\0/usr/local/bin/' + command.encode() + b'\0--id\0worker\0')
        (p / 'environ').write_bytes(b'AGENTMUX_PROGRESS_DIR=' + os.fsencode(directory) + b'\0CODEX_THREAD_ID=' + THREAD.encode() + b'\0SECRET=must-not-appear\0')
        return p

    def read(self):
        env = dict(os.environ, HOME=str(self.home))
        result = subprocess.run([sys.executable, '-c', READER, str(self.records), str(self.proc)],
                                env=env, text=True, capture_output=True, timeout=10, check=True)
        self.assertNotIn('must-not-appear', result.stdout)
        return {line.split(' ', 2)[1]: json.loads(line.split(' ', 2)[2])
                for line in result.stdout.splitlines() if line.startswith('@@progress ')}

    def test_recent_report_is_not_hidden_by_older_directory_entries(self):
        for index in range(300):
            self.record('job-%03d' % index)
        # Pick the filesystem's LAST entry, rather than assuming enumeration order.
        files = list(self.records.iterdir())
        for p in files:
            os.utime(p, (100, 100))
        latest = files[-1]
        os.utime(latest, (1000, 1000))
        records = self.read()
        self.assertIn(latest.stem, records)
        self.assertLessEqual(len(records), 256)

    def test_custom_directory_is_discovered_from_a_live_wrapper(self):
        custom = self.base / 'custom'
        self.record('worker', directory=custom, codex_thread_id=THREAD)
        self.wrapper(custom)
        self.assertIn('worker', self.read())

    def test_unrelated_process_cannot_register_a_directory(self):
        custom = self.base / 'unrelated'
        self.record('unrelated', directory=custom)
        self.wrapper(custom, command='other-tool')
        self.assertNotIn('unrelated', self.read())

    def test_registered_directory_is_read_after_wrapper_exits(self):
        custom = self.base / 'custom'
        self.record('finished', directory=custom)
        registry = self.home / '.agentmux/progress-sources'
        registry.mkdir()
        (registry / 'source.json').write_text(json.dumps({'directory': str(custom)}))
        self.assertIn('finished', self.read())

    def test_same_id_in_multiple_sources_uses_newest_report(self):
        custom = self.base / 'custom'
        old = self.record('worker', current=1, total=10)
        recent = self.record('worker', directory=custom, current=7, total=10)
        os.utime(old, (100, 100))
        os.utime(recent, (200, 200))
        self.wrapper(custom)
        self.assertEqual(self.read()['worker']['current'], 7)

    def test_reader_keeps_counts_details_and_omits_private_eta_history(self):
        self.record('worker', current=45, total=117,
                    details=[{'label': 'CPU', 'current': 25.17, 'total': 100}],
                    _eta_samples=[[1, 1]], _eta_key=['private'])
        row = self.read()['worker']
        self.assertEqual(row['current'], 45)
        self.assertEqual(row['details'][0]['current'], 25.17)
        self.assertNotIn('_eta_samples', row)
        self.assertNotIn('_eta_key', row)

    def test_bad_json_and_symlinks_do_not_hide_a_valid_record(self):
        self.record('good')
        (self.records / 'broken.json').write_text('{')
        outside = self.base / 'outside.json'
        outside.write_text('{"label":"outside"}')
        (self.records / 'link.json').symlink_to(outside)
        rows = self.read()
        self.assertIn('good', rows)
        self.assertNotIn('link', rows)

    def test_missing_default_directory_does_not_hide_custom_reports(self):
        self.records.rmdir()
        custom = self.base / 'custom'
        self.record('worker', directory=custom)
        self.wrapper(custom)
        self.assertIn('worker', self.read())


if __name__ == '__main__':
    unittest.main()

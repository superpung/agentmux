"""Regression tests for the progress protocol and real wrapper processes."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/agentmux-progress'


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agentmux-progress-test-')
        self.env = patch.dict(os.environ, AGENTMUX_PROGRESS_DIR=self.temp.name, TMUX_PANE='%test')
        self.env.start()
        self.m = types.SimpleNamespace(**runpy.run_path(str(SCRIPT), run_name='progress_test'))

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def read(self, key='job'):
        return json.loads((Path(self.temp.name) / (key+'.json')).read_text())

    def report(self, *args):
        self.m.mode_report(['--id', 'job', *args])
        return self.read()

    def test_counts_replace_old_percentage(self):
        self.report('--percent', '20', '--current', '2', '--total', '10')
        self.assertEqual(self.report('--current', '8')['percent'], 80)

    def test_new_phase_clears_progress_and_eta(self):
        self.report('--phase', 'train', '--current', '2', '--total', '10', '--eta', '60')
        st = self.report('--phase', 'evaluation', '--state', 'preparing')
        self.assertNotIn('current', st)
        self.assertNotIn('eta_seconds', st)

    def test_existing_job_start_is_explicit(self):
        self.assertNotIn('started_at', self.report('--state', 'preparing'))
        self.assertEqual(self.report('--started-at', '100')['started_at'], 100)

    def test_restart_removes_previous_run_fields(self):
        old = self.report('--started-at', '100', '--current', '5', '--total', '10', '--state', 'failed', '--exit-code', '7')
        st = self.report('--restart', '--state', 'running', '--started-at', '200')
        self.assertNotEqual(old['run_id'], st['run_id'])
        self.assertNotIn('exit_code', st)
        self.assertNotIn('finished_at', st)
        self.assertNotIn('current', st)

    def test_heartbeat_keeps_terminal_state_and_finish_time(self):
        self.report('--state', 'done', '--finished-at', '150')
        st = self.report('--heartbeat')
        self.assertEqual((st['state'], st['finished_at']), ('done', 150))

    def test_details_and_source_freshness(self):
        st = self.report('--details-json', '[{"id":"a","label":"A","current":3,"total":9}]', '--source-updated-at', '123')
        self.assertEqual(st['details'][0]['current'], 3)
        self.assertEqual(st['source_updated_at'], 123)

    def test_eta_uses_progress_samples_and_recalculates(self):
        with patch.object(self.m.time, 'time', return_value=100) as clock:
            r = self.m.Reporter('job', 'Job')
            r.update({'current':1, 'total':10}, force=True)
            self.assertNotIn('eta_seconds', r.state)
            clock.return_value = 110
            r.update({'current':2, 'total':10}, force=True)
            self.assertEqual(r.state['eta_seconds'], 80)
            clock.return_value = 120
            r.update({'current':6, 'total':10}, force=True)
            self.assertEqual(r.state['eta_seconds'], 16)
            clock.return_value = 130
            r.update({'current':0, 'total':2}, force=True)
            self.assertNotIn('eta_seconds', r.state)

    def test_old_eta_expires_and_finish_does_not_recreate_it(self):
        with patch.object(self.m.time, 'time', return_value=100) as clock:
            r = self.m.Reporter('job', 'Job')
            r.update({'current':2, 'total':10, 'eta_seconds':20}, force=True)
            clock.return_value = 200
            r.heartbeat()
            self.assertNotIn('eta_seconds', self.read())
            r.finish('done', 0)
            self.assertNotIn('eta_seconds', self.read())
            self.assertEqual(self.read()['finished_at'], 200)

    def test_chunk_boundaries_and_ansi(self):
        r = self.m.Reporter('job', 'Job')
        parser = self.m.OutputParser(r)
        parser.feed(b'\x1b[32mepoch 3/1')
        self.assertNotIn('current', r.state)
        parser.feed(b'0\x1b[0m\r')
        self.assertEqual((r.state['current'], r.state['total']), (3,10))

    def test_pipe_preserves_streams_and_exit_code(self):
        result = subprocess.run([sys.executable,str(SCRIPT),'--pipe','--id','job','--',sys.executable,'-c',
            'import sys;sys.stdout.write("out\\n");sys.stderr.write("err\\n");sys.exit(7)'],
            stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
        self.assertEqual((result.stdout,result.stderr,result.returncode),(b'out\n',b'err\n',7))
        self.assertEqual((self.read()['state'],self.read()['exit_code']),('failed',7))

    def test_quiet_command_has_heartbeats_without_fake_progress(self):
        proc = subprocess.Popen([sys.executable,str(SCRIPT),'--pipe','--id','job','--heartbeat-interval','0.1','--',
            sys.executable,'-c','import time;time.sleep(0.8)'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic()+3
            while not (Path(self.temp.name)/'job.json').exists() and time.monotonic()<deadline:
                time.sleep(0.02)
            first = self.read()['updated_at']
            time.sleep(0.35)
            st = self.read()
            self.assertGreater(st['updated_at'],first)
            self.assertNotIn('current',st)
            self.assertNotIn('progress_at',st)
            proc.communicate(timeout=3)
            self.assertEqual(self.read()['state'],'done')
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=3)

    def test_pty_progress_and_exit(self):
        result = subprocess.run([sys.executable,str(SCRIPT),'--id','job','--',sys.executable,'-c',
            'print("epoch 3/10")'],stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.read()['current'],3)

    def test_signal_reaches_wrapped_process(self):
        proc = subprocess.Popen([sys.executable,str(SCRIPT),'--pipe','--id','job','--',
            sys.executable,'-c','import time;time.sleep(30)'],stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic()+3
            while not (Path(self.temp.name)/'job.json').exists() and time.monotonic()<deadline:
                time.sleep(0.02)
            time.sleep(0.1)
            proc.terminate()
            proc.communicate(timeout=3)
            self.assertEqual(proc.returncode,143)
            self.assertEqual(self.read()['exit_code'],143)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.communicate(timeout=3)

    def test_explicit_finish_time_corrects_an_earlier_report(self):
        self.report('--state','done','--finished-at','150')
        self.assertEqual(self.report('--state','done','--finished-at','140')['finished_at'],140)


    def test_parser_failure_at_eof_preserves_command_exit(self):
        code = "import runpy,sys\nm=runpy.run_path(sys.argv[1],run_name='review')\ndef fail(*a,**k): raise ValueError('bad telemetry')\nm['OutputParser'].feed=fail\nsys.exit(m['mode_run']([sys.executable,'-c','print(123);raise SystemExit(7)'],'Job','job',pipe=True))"
        result = subprocess.run([sys.executable,'-c',code,str(SCRIPT)],stdin=subprocess.DEVNULL,
                                capture_output=True,timeout=5)
        self.assertEqual((result.stdout,result.returncode),(b'123\n',7))


    def test_failed_telemetry_does_not_fail_job(self):
        with tempfile.NamedTemporaryFile() as f:
            env = dict(os.environ,AGENTMUX_PROGRESS_DIR=f.name)
            result = subprocess.run([sys.executable,str(SCRIPT),'--pipe','--',sys.executable,'-c','print("ok")'],
                env=env,stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
            self.assertEqual((result.returncode,result.stdout),(0,b'ok\n'))


if __name__ == '__main__':
    unittest.main()

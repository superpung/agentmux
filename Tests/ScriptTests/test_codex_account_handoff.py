"""Regression tests for the exact embedded account-switch program."""
import contextlib
import io
import json
from pathlib import Path
import shlex
import sqlite3
import tempfile
import types
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/AgentMuxCore/Agents/CodexAccountHandoff.swift'
PROGRAM = SOURCE.read_text().split('static let program = #"""', 1)[1].split('"""#', 1)[0]
handoff = types.ModuleType('handoff')
exec(compile(PROGRAM, str(SOURCE), 'exec'), handoff.__dict__)
SID = '01a1c973-6fd1-7762-bd15-919f6b5e8c5b'
OTHER = '01a1c040-4e34-7163-8476-46a0e0be10be'


class CodexAccountHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agentmux-handoff-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.cwd = '/data/ra/ra-v2'

    def rollout(self, name, sid=SID):
        p = self.base / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({'type':'session_meta','payload':{'id':sid,'cwd':self.cwd}})+'\n')
        return p

    def db(self, home, path):
        home.mkdir(exist_ok=True)
        db=home/'state_5.sqlite'
        with contextlib.closing(sqlite3.connect(db)) as c:
            c.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)')
            c.execute('INSERT INTO threads VALUES (?,?)', (SID,str(path)))
            c.commit()
        return db

    def test_same_id_with_different_indexes_uses_verified_source_state(self):
        old=self.rollout('sessions/11/rollout-old.jsonl')
        new=self.rollout('sessions/15/rollout-new_writer.jsonl')
        source=self.db(self.base/'source',new)
        target=self.db(self.base/'target',old)
        sid,path=handoff.select_rollout([new], self.cwd, SID)
        self.assertEqual(handoff.indexed_rollout(source,sid),path)
        cmd=handoff.command(str(target.parent),str(source.parent),'/bin/codex',sid)
        self.assertIn('sqlite_home='+json.dumps(str(source.parent)),shlex.split(cmd))
        self.assertIn('--no-daemon',shlex.split(cmd))
        self.assertEqual(handoff.indexed_rollout(target,sid),str(old))

    def test_shared_session_symlink_does_not_choose_the_target_index(self):
        real=self.base/'sessions';real.mkdir()
        new=self.rollout('sessions/rollout-new.jsonl')
        linked=self.base/'linked';linked.symlink_to(real,target_is_directory=True)
        sid,path=handoff.select_rollout([new,linked/new.name],self.cwd,SID)
        self.assertEqual((sid,path),(SID,str(new.resolve())))

    def test_multiple_live_threads_in_one_cwd_are_not_guessed(self):
        a=self.rollout('rollout-a.jsonl');b=self.rollout('rollout-b.jsonl',OTHER)
        with self.assertRaises(handoff.HandoffError):
            handoff.select_rollout([a,b],self.cwd,SID)

    def test_spawned_agents_do_not_hide_the_parent_conversation(self):
        parent=self.rollout('rollout-parent.jsonl')
        child=self.rollout('rollout-child.jsonl',OTHER)
        record=json.loads(child.read_text())
        record['payload']['source']={'subagent':{'thread_spawn':{'parent_thread_id':SID}}}
        child.write_text(json.dumps(record)+'\n')
        self.assertEqual(handoff.select_rollout([parent,child],self.cwd,SID),(SID,str(parent)))

    def test_multiple_live_files_for_same_id_are_not_guessed(self):
        a=self.rollout('rollout-a.jsonl');b=self.rollout('rollout-b.jsonl')
        with self.assertRaises(handoff.HandoffError):
            handoff.select_rollout([a,b],self.cwd,SID)

    def test_stale_resume_command_and_missing_identity_fail_before_stopping(self):
        new=self.rollout('rollout-new.jsonl',OTHER)
        for paths in [[new],[]]:
            with self.assertRaises(handoff.HandoffError):
                handoff.select_rollout(paths,self.cwd,SID)

    def test_source_is_exact_live_file_even_if_another_file_is_newer(self):
        active=self.rollout('rollout-active.jsonl')
        self.rollout('rollout-unrelated.jsonl',OTHER)
        self.assertEqual(handoff.select_rollout([active],self.cwd,SID),(SID,str(active)))

    def test_state_home_survives_repeated_account_changes(self):
        state='/root/.codex'
        for target in ['/root/.codex-3','/root/.codex-2','/root/.codex']:
            cmd=shlex.split(handoff.command(target,state,'/bin/codex',SID))
            self.assertEqual(cmd[0],'CODEX_HOME='+target)
            self.assertEqual(cmd[1],'AGENTMUX_CODEX_SQLITE_HOME='+state)
            self.assertEqual(cmd[-2:],['resume',SID])
            self.assertIn('thread_unload_delay_secs=0',cmd)

    def test_command_preserves_paths_as_single_arguments(self):
        state='/tmp/state "quoted" $(must-not-run)'
        cmd=shlex.split(handoff.command('/tmp/account space',state,'/tmp/bin/codex',SID))
        self.assertEqual(cmd[0],'CODEX_HOME=/tmp/account space')
        self.assertIn('sqlite_home='+json.dumps(state),cmd)

    def test_unreadable_or_missing_source_index_does_not_create_a_database(self):
        db=self.base/'absent.sqlite'
        with self.assertRaises(handoff.HandoffError):
            handoff.indexed_rollout(db,SID)
        self.assertFalse(db.exists())

    def test_launch_is_never_typed_into_another_running_program(self):
        with patch.object(handoff.subprocess,'check_output',return_value=b'claude\n'), \
             patch.object(handoff.subprocess,'run') as run:
            with self.assertRaises(handoff.HandoffError):
                handoff.send(['tmux'],'%1','codex resume '+SID)
            run.assert_not_called()

    def test_pid_reuse_is_rejected_before_signal_or_input(self):
        plan={'source':{'pid':123,'ticks':55}}
        with patch.object(handoff,'process',return_value={'ticks':56,'zombie':False}), \
             patch.object(handoff.os,'kill') as kill, patch.object(handoff,'send') as send:
            with self.assertRaises(handoff.HandoffError):handoff.switch(plan,[], '%1')
            kill.assert_not_called();send.assert_not_called()

    def test_source_daemon_acknowledgement_precedes_stop(self):
        plan={'source':{'pid':123,'ticks':55},'managed':True,'sid':SID,'rollout':'p','state':'s','target':'t'}
        with patch.object(handoff,'same_process',return_value=True), \
             patch.object(handoff,'SourceControl',side_effect=handoff.HandoffError('refused')), \
             patch.object(handoff.os,'kill') as kill, patch.object(handoff,'send') as send, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(handoff.HandoffError):handoff.switch(plan,[],'%1')
            kill.assert_not_called();send.assert_not_called()

    def test_wrong_target_runtime_cannot_be_reported_as_verified(self):
        plan={'target':'/root/.codex-3','sid':SID,'state':'/root/.codex','root':1}
        for flags,state in [([],plan['state']),(['--no-daemon'],'/root/.codex-3')]:
            p={'home':plan['target'],'args':['codex']+flags+['resume',SID],'state':state,'pid':2}
            with patch.object(handoff,'codex_processes',return_value=[p]):
                self.assertEqual(handoff.verified_processes(plan),[])

    def test_failed_resume_never_prints_success_or_types_into_an_agent(self):
        rollout=self.rollout('rollout-source.jsonl')
        plan={'source':{'pid':123,'ticks':55,'home':'old','args':['codex','resume',SID],'state':''},
              'managed':False,'sid':SID,'rollout':str(rollout),'state':'s','target':'t',
              'owners':[],'db':'db','executable':'codex','root':1}
        out=io.StringIO()
        with patch.object(handoff,'same_process',return_value=True), \
             patch.object(handoff.os,'kill'), patch.object(handoff,'wait_until',side_effect=[True,True,False]), \
             patch.object(handoff,'indexed_rollout',return_value=str(rollout)), \
             patch.object(handoff,'codex_processes',return_value=[{'pid':456,'args':['codex']}]), \
             patch.object(handoff,'descends',return_value=True), patch.object(handoff,'send') as send, \
             contextlib.redirect_stdout(out):
            with self.assertRaises(handoff.HandoffError):handoff.switch(plan,[],'%1')
            self.assertEqual(send.call_count,1)
        self.assertNotIn('OK:',out.getvalue())


if __name__=='__main__':unittest.main()

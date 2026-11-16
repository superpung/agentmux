"""Opt-in tests against the installed Codex binary, using disposable fake chats.

AGENTMUX_CODEX_TEST_BINARY=/absolute/path/to/codex python3 -m unittest discover ...
No real credentials or sessions are used and no turn/model request is sent.
"""
import contextlib
import json
import os
from pathlib import Path
import selectors
import shutil
import uuid
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest

from test_codex_account_handoff import handoff, SID, OTHER, PROGRAM

BINARY=os.environ.get('AGENTMUX_CODEX_TEST_BINARY')


class RPC:
    def __init__(self,binary,home,state=None,extra=()):
        env=dict(os.environ,CODEX_HOME=str(home))
        for k in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_THREAD_ID','AGENTMUX_CODEX_SQLITE_HOME']:
            env.pop(k,None)
        args=[binary,'-c','features.api_key_model_discovery=false']
        if state:args+=['-c','sqlite_home='+json.dumps(str(state))]
        args+=['app-server','--stdio']+list(extra)
        self.child=subprocess.Popen(args,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        self.serial=0;self.buffer=b''
        self.call('initialize',{'clientInfo':{'name':'agentmux-native-handoff-test','version':'1.0'},
                               'capabilities':{'experimentalApi':True}})

    def call(self, method, params):
        self.serial+=1
        self.child.stdin.write((json.dumps({'id':self.serial,'method':method,'params':params})+'\n').encode())
        self.child.stdin.flush()
        with selectors.DefaultSelector() as poll:
            poll.register(self.child.stdout, selectors.EVENT_READ)
            end=time.monotonic()+5
            while time.monotonic()<end:
                while b'\n' in self.buffer:
                    line,self.buffer=self.buffer.split(b'\n',1)
                    response=json.loads(line)
                    if response.get('id')==self.serial:
                        if 'error' in response:
                            raise handoff.HandoffError('Fixture RPC: '+json.dumps(response['error']))
                        return response.get('result',{})
                if not poll.select(.2):
                    continue
                chunk=os.read(self.child.stdout.fileno(),65536)
                if not chunk:
                    break
                self.buffer+=chunk
                if len(self.buffer)>1048576:
                    break
        raise handoff.HandoffError('The source daemon did not acknowledge the conversation handoff.')

    def close(self):
        if self.child.poll() is None:
            self.child.stdin.close()
            try:
                self.child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.child.terminate()
                self.child.wait(timeout=2)
        self.child.stdout.close()



@unittest.skipUnless(BINARY and os.name=='posix' and Path('/proc').exists(), 'requires opt-in Linux Codex binary')
class NativeCodexHandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='agentmux-native-regression-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.source=self.root/'source';self.target=self.root/'target';self.cwd=self.root/'work'
        for p in [self.source,self.target,self.cwd]:p.mkdir()
        # Keep auth/config/history for every test inside its disposable root.
        self.source.joinpath('sessions').mkdir()
        self.target.joinpath('sessions').symlink_to(self.source/'sessions',target_is_directory=True)
        self.old=self.rollout('2026/11/11/rollout-2026-11-11T15-12-33-'+SID+'.jsonl',['OLD-FIXTURE'])
        self.new=self.rollout('2026/11/15/rollout-2026-11-15T23-41-12-'+SID+'_01a1dfde-a1c7-73c2-8ec3-550a6f5eea61.jsonl',['OLD-FIXTURE','LATEST-FIXTURE'])
        for home,path in [(self.source,self.new),(self.target,self.old)]:
            rpc=RPC(BINARY,home)
            try:rpc.call('thread/resume',{'threadId':SID,'path':str(path),'excludeTurns':True})
            finally:rpc.close()

    def rollout(self,name,messages):
        p=self.source/'sessions'/name;p.parent.mkdir(parents=True,exist_ok=True)
        rows=[{'timestamp':'2026-11-11T07:12:33Z','type':'session_meta','payload':{
            'id':SID,'timestamp':'2026-11-11T07:12:33Z','cwd':str(self.cwd),'originator':'codex-tui',
            'cli_version':'0.169.0','source':'cli','model_provider':'openai'}}]
        for index,text in enumerate(messages):
            turn='01a1dfde-a1c7-73c2-8ec3-%012d' % index
            def event(payload):return {'timestamp':'2026-11-15T15:42:00Z','type':'event_msg','payload':payload}
            rows.append(event({'type':'task_started','turn_id':turn,'model_context_window':128000,'collaboration_mode_kind':'default'}))
            rows.append({'timestamp':'2026-11-15T15:42:00Z','type':'response_item','payload':{
                'type':'message','role':'user','content':[{'type':'input_text','text':text}]}})
            rows.append(event({'type':'user_message','message':text,'images':[],'local_images':[],'text_elements':[]}))
            rows.append(event({'type':'agent_message','message':'fixture answer','phase':'final_answer'}))
            rows.append(event({'type':'task_complete','turn_id':turn,'last_agent_message':'fixture answer'}))
        p.write_text(''.join(json.dumps(r)+'\n' for r in rows));return p

    def test_real_resume_selects_latest_source_despite_target_old_index_and_shared_sessions(self):
        # Reproduce the reported failure first using native thread resolution.
        rpc=RPC(BINARY,self.target)
        try:
            t=rpc.call('thread/resume',{'threadId':SID})['thread']
            self.assertEqual(t['path'],str(self.old))
            self.assertNotIn('LATEST-FIXTURE',json.dumps(t['turns']))
        finally:rpc.close()
        # The same native resume now uses the source's full runtime state.
        for home in [self.target,self.source,self.target]:
            rpc=RPC(BINARY,home,self.source)
            try:
                t=rpc.call('thread/resume',{'threadId':SID})['thread']
                self.assertEqual(t['id'],SID)
                self.assertEqual(t['path'],str(self.new))
                self.assertIn('LATEST-FIXTURE',json.dumps(t['turns']))
            finally:rpc.close()

    def test_paginated_history_survives_account_changes(self):
        env=dict(os.environ,CODEX_HOME=str(self.source))
        result=subprocess.run([BINARY,'migrate-rollouts','--thread',SID,'--apply','--json'],
                              env=env,text=True,capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr)
        path=handoff.indexed_rollout(self.source/'state_5.sqlite',SID)
        for home in [self.target,self.source,self.target]:
            rpc=RPC(BINARY,home,self.source)
            try:
                t=rpc.call('thread/resume',{'threadId':SID,'excludeTurns':True})['thread']
                self.assertEqual(t['id'],SID)
                self.assertEqual(t['path'],path)
                self.assertEqual(t['historyMode'],'paginated')
                turns=rpc.call('thread/turns/list',{'threadId':SID,'limit':20,'sortDirection':'asc'})
                self.assertIn('LATEST-FIXTURE',json.dumps(turns))
            finally:rpc.close()

    def test_only_the_source_thread_is_released_from_a_shared_server(self):
        # Native unix transport/proxy and handoff acknowledgement, no real daemon.
        endpoint=self.source/'app-server-control/app-server-control.sock'
        env=dict(os.environ,CODEX_HOME=str(self.source))
        for k in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_THREAD_ID']:env.pop(k,None)
        server=subprocess.Popen([BINARY,'-c','features.api_key_model_discovery=false',
                                 'app-server','--listen','unix://','--managed-daemon'],env=env,
                                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: self.stop(server))
        self.assertTrue(handoff.wait_until(endpoint.exists,5))
        plan={'source':{'home':str(self.source)},'executable':BINARY,'sid':SID,'rollout':str(self.new)}
        old=handoff.SourceControl(plan)
        other=self.rollout('2026/11/15/rollout-other.jsonl',['OTHER-FIXTURE'])
        rows=other.read_text().splitlines();meta=json.loads(rows[0]);meta['payload']['id']=OTHER
        other.write_text(json.dumps(meta)+'\n'+'\n'.join(rows[1:])+'\n')
        old.call('thread/resume',{'threadId':OTHER,'path':str(other),'excludeTurns':True})
        control=handoff.SourceControl(plan)
        try:
            self.assertIn(self.new,set(handoff.open_files(server.pid)))
            old.close()
            control.release(SID)
            self.assertTrue(handoff.wait_until(lambda:self.new not in set(handoff.open_files(server.pid)),5))
            self.assertIsNone(server.poll(), 'shared server must keep running')
            self.assertIn(other,set(handoff.open_files(server.pid)), 'other conversations must remain loaded')
        finally:control.close()

    @unittest.skipUnless(shutil.which('tmux'), 'requires isolated test tmux')
    def test_actual_tui_switches_accounts_and_back_with_the_latest_conversation(self):
        # This is the only input test, scoped to the explicitly approved test socket.
        tmux=[shutil.which('tmux'),'-L','agentmux-test']
        session='agentmux-test-handoff-'+uuid.uuid4().hex[:10]
        for home in [self.source,self.target]:
            login=subprocess.run([BINARY,'login','--with-api-key'],env=dict(os.environ,CODEX_HOME=str(home)),
                input='sk-agentmux-offline-fixture\n',text=True,capture_output=True,timeout=5)
            self.assertEqual(login.returncode,0,login.stderr)
            (home/'config.toml').write_text('model = "gpt-6.1-sol"\n'
                '[features]\napi_key_model_discovery = false\n'
                '[projects.'+json.dumps(str(self.cwd))+']\ntrust_level = "trusted"\n')
        pane=subprocess.check_output(tmux+['new-session','-d','-s',session,'-P','-F','#{pane_id}',
              '-c',str(self.cwd),'env','OPENAI_API_KEY=sk-agentmux-offline-fixture','/bin/bash','--noprofile','--norc'],text=True).strip()
        self.addCleanup(lambda: subprocess.run(tmux+['kill-session','-t',session],capture_output=True))
        root=int(subprocess.check_output(tmux+['display-message','-p','-t',pane,'#{pane_pid}']))
        endpoint=self.source/'app-server-control/app-server-control.sock'
        server=subprocess.Popen([BINARY,'-c','features.api_key_model_discovery=false',
            'app-server','--listen','unix://','--managed-daemon'],env=dict(os.environ,CODEX_HOME=str(self.source)),
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.addCleanup(lambda:self.stop(server))
        self.assertTrue(handoff.wait_until(endpoint.exists,5))
        start='CODEX_HOME='+shlex.quote(str(self.source))+' '+shlex.quote(BINARY)+ \
              ' --remote '+shlex.quote('unix://'+str(endpoint))+' resume '+SID
        handoff.send(tmux,pane,start)
        def current(home):
            return next((p for p in handoff.codex_processes() if p['home']==str(home)
                and 'app-server' not in p['args'] and handoff.resume_id(p['args'])==SID
                and handoff.descends(p['pid'],root)),None)
        self.assertTrue(handoff.wait_until(lambda:current(self.source) is not None,12))
        # Wait for the real runtime, rather than treating the TUI process as ready.
        def ready(home):
            try:
                p=current(home)
                return p and handoff.preflight(tmux,pane,p['pid'],str(self.cwd),str(self.target if home==self.source else self.source))
            except handoff.HandoffError as e:
                ready.error=str(e)
                return False
        ready.error=''
        ok=handoff.wait_until(lambda:bool(ready(self.source)),20)
        if not ok:
            screen=subprocess.check_output(tmux+['capture-pane','-p','-t',pane],text=True)
            self.fail(ready.error+'\nFixture TUI: '+screen)
        for source,target in [(self.source,self.target),(self.target,self.source)]:
            plan=ready(source)
            self.assertTrue(plan)
            self.assertEqual(plan['rollout'],str(self.new))
            switched=subprocess.run([sys.executable,'-c',PROGRAM,json.dumps(tmux),pane,
                str(plan['source']['pid']),str(self.cwd),str(target)],
                env=dict(os.environ,HOME=str(self.root)),text=True,capture_output=True,timeout=65)
            self.assertEqual(switched.returncode,0,switched.stdout+switched.stderr)
            self.assertIn('OK: '+SID,switched.stdout)
            p=current(target)
            self.assertIsNotNone(p)
            self.assertEqual(p['state'],str(self.source))
            self.assertEqual(handoff.indexed_rollout(plan['db'],SID),str(self.new))

    @staticmethod
    def stop(server):
        if server.poll() is None:
            server.terminate();server.wait(timeout=8)


if __name__=='__main__':unittest.main()

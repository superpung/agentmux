"""Exercise the exact remote program without touching live agent sessions."""
from pathlib import Path
import contextlib
import io
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
import uuid
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/AgentMuxCore/Agents/AgentApproval.swift'
PROGRAM = SOURCE.read_text().split('static let program = #"""', 1)[1].split('"""#', 1)[0]
approval = types.ModuleType('approval')
exec(compile(PROGRAM, str(SOURCE), 'exec'), approval.__dict__)


def screen(selected='No', action='synthetic action'):
    return '\n'.join([action, "Auto mode can't check actions in this session, so this one needs your approval",
                      'Do you want to proceed?', ('❯ ' if selected=='No' else '  ')+'No',
                      ('❯ ' if selected=='Yes' else '  ')+'Yes', 'Esc to cancel · Tab to amend',
                      '──────────────────────── synthetic ─'])


def framed_screen(background, selected='No', action='synthetic action'):
    return background + '\n' + '─' * 100 + '\n' + screen(selected, action)


def timed_bash_screen(seconds='0:33', action='printf example', background='previous output', reason='Multiple directory changes require approval'):
    return '\n'.join([background, '─' * 100, ' Bash command', ' Test command', '┄' * 100,
                      ' │ ' + action, '┄' * 100, ' ' + reason,
                      ' ⚠ Claude Code will automatically block this request in ' + seconds +
                      ', to avoid holding up an unattended session', '', ' Do you want to proceed?',
                      ' ❯ 1. Yes', '   2. No', '', ' Esc to cancel · Tab to amend',
                      '──────────────────────── synthetic ─'])


class AgentApprovalTests(unittest.TestCase):
    def test_claude_bash_approval_survives_its_own_expiry_timer(self):
        first = approval.parse_screen(timed_bash_screen(), 100)
        second = approval.parse_screen(timed_bash_screen('0:28', background='new output'), 100)
        self.assertEqual(first['token'], second['token'])
        self.assertEqual((second['selected'],second['yes']),(0,0))
        changed = approval.parse_screen(timed_bash_screen('0:28', action='printf changed'), 100)
        self.assertNotEqual(first['token'], changed['token'])
        changed_reason = approval.parse_screen(timed_bash_screen('0:28', reason='Different approval reason'), 100)
        self.assertNotEqual(first['token'], changed_reason['token'])

    def test_countdown_like_text_in_command_still_changes_approval_identity(self):
        first = approval.parse_screen(timed_bash_screen(action='printf "will block in 0:33"'), 100)
        second = approval.parse_screen(timed_bash_screen('0:28', action='printf "will block in 0:28"'), 100)
        self.assertNotEqual(first['token'], second['token'])

    def test_expiry_tick_between_rechecks_does_not_block_enter(self):
        p = dict(pid=42, pgrp=42, foreground=42, ticks=123, alive=True, name='claude')
        timers = iter(['0:33', '0:28', '0:27'])
        sent = []

        def tm(argv, *args):
            if args[0] == 'display-message': return '10 20 12 @1 100'
            if args[0] == 'list-clients': return ''
            if args[0] == 'capture-pane': return timed_bash_screen(next(timers))
            if args[0] == 'send-keys': sent.append(args[-1]); return ''
            self.fail(f'unexpected tmux command: {args[0]}')

        with patch.object(approval, 'tm', side_effect=tm), patch.object(approval, 'process', return_value=p), \
             patch.object(approval, 'belongs_to', return_value=True):
            request = approval.inspect(['tmux'], '%1', 42, 123)
            self.assertEqual(approval.approve(['tmux'], '%1', 42, 123, request['token'], (10,20)), 'APPROVED')
        self.assertEqual(sent, ['Enter'])

    def test_claude_dialog_fingerprint_ignores_only_content_outside_its_frame(self):
        first = approval.parse_screen(framed_screen('background frame 1'), 100)
        second = approval.parse_screen(framed_screen('background frame 2', 'Yes'), 100)
        self.assertEqual(first['token'], second['token'])
        changed = approval.parse_screen(framed_screen('background frame 2', action='different action'), 100)
        self.assertNotEqual(first['token'], changed['token'])
        indented = approval.parse_screen(framed_screen('background frame 1', action='    synthetic action'), 100)
        self.assertNotEqual(first['token'], indented['token'])

    def test_uncertain_frame_keeps_the_whole_action_in_the_fingerprint(self):
        def ambiguous(action):
            return framed_screen('background', action=action + '\n' + '─' * 100 + '\nmore of the action')
        first = approval.parse_screen(ambiguous('first action'), 100)
        changed = approval.parse_screen(ambiguous('changed action'), 100)
        self.assertNotEqual(first['token'], changed['token'])

    def test_screenshot_layout_and_cursor_fingerprint(self):
        no = approval.parse_screen(screen())
        yes = approval.parse_screen(screen('Yes'))
        self.assertEqual((no['yes'],no['selected']),(1,0))
        self.assertEqual((yes['yes'],yes['selected']),(1,1))
        self.assertEqual(no['token'],yes['token'])
        self.assertNotEqual(no['token'],approval.parse_screen(screen(action='different action'))['token'])

    def test_numbered_claude_and_codex_menus(self):
        for question,label,cursor in [('Do you want to proceed?','Yes','❯'),
                                      ('Would you like to run the following command?','Yes, proceed (y)','›')]:
            text='\n'.join([question,'  1. '+label,"  2. Yes, and don't ask again",cursor+' 3. No',
                            'Esc to cancel'])
            state=approval.parse_screen(text)
            self.assertEqual((state['yes'],state['selected']),(0,2))

    def test_partial_inactive_ambiguous_and_broad_permissions_are_refused(self):
        variants = [screen().replace('❯ No','No'), screen().replace('Yes\n','Yes, allow all\n'),
                    screen().replace('Do you want to proceed?','Which answer is correct?'),
                    screen().replace('Esc to cancel · Tab to amend',''), screen()+'\n❯ new draft',
                    screen().replace('  Yes','❯ Yes'), 'normal output: No\nYes',
                    'Do you want to proceed?\n❯ Yes\nNo\n',
                    'Do you want to proceed?\n❯ 1. Yes\n  3. No\nEsc to cancel']
        for text in variants:
            with self.subTest(text=text):
                self.assertIsNone(approval.parse_screen(text))

    def test_process_server_and_foreground_checks(self):
        p=dict(pid=42,ppid=12,pgrp=42,foreground=42,ticks=123,alive=True,name='claude')
        def tm(argv,*args):
            if args[0]=='display-message': return '10 20 12 @1 100'
            if args[0]=='list-clients': return '0 @1 0\n9999999999 @9 0\n9999999999 @1 1'
            return screen()
        with patch.object(approval,'tm',side_effect=tm), patch.object(approval,'belongs_to',return_value=True), \
             patch.object(approval,'process',return_value=p):
            self.assertIsNotNone(approval.inspect(['tmux'],'%1',42,123,(10,20),quiet=5))
            self.assertIsNone(approval.inspect(['tmux'],'%1',42,124,(10,20)))
            self.assertIsNone(approval.inspect(['tmux'],'%1',42,123,(10,21)))
            for changes in [dict(alive=False),dict(name='bash'),dict(foreground=99)]:
                with patch.object(approval,'process',return_value=dict(p,**changes)):
                    self.assertIsNone(approval.inspect(['tmux'],'%1',42,123,(10,20)))
            with patch.object(approval,'belongs_to',return_value=False):
                self.assertIsNone(approval.inspect(['tmux'],'%1',42,123,(10,20)))

    def test_recent_external_input_blocks_approval(self):
        p=dict(pid=42,pgrp=42,foreground=42,ticks=123,alive=True,name='claude')
        def tm(argv,*args):
            if args[0]=='display-message': return '10 20 12 @1 100'
            if args[0]=='list-clients': return '98 @1 0'
            return screen()
        with patch.object(approval,'tm',side_effect=tm), patch.object(approval,'belongs_to',return_value=True), \
             patch.object(approval,'process',return_value=p), patch.object(approval.time,'time',return_value=100):
            self.assertIsNotNone(approval.inspect(['tmux'],'%1',42,123))
            self.assertIsNone(approval.inspect(['tmux'],'%1',42,123,quiet=5))

    def test_action_moves_to_one_time_yes_and_confirms_once(self):
        state=dict(token='request',base='screen',activity=0,selected=0,yes=1)
        selected=dict(state,token='moved',selected=1)
        with patch.object(approval,'inspect',side_effect=[state,selected,selected]), patch.object(approval,'tm') as tm:
            self.assertEqual(approval.approve(['tmux'],'%1',42,123,'request',(10,20)),'APPROVED')
            self.assertEqual([c.args[-1] for c in tm.call_args_list],['Down','Enter'])

    def test_changed_request_or_process_never_gets_enter(self):
        state=dict(token='request',base='screen',activity=0,selected=0,yes=1)
        for changed in [None,dict(state,token='new',base='new'),dict(state,activity=2)]:
            with self.subTest(changed=changed), patch.object(approval,'inspect',side_effect=[state]+[changed]*100), \
                 patch.object(approval,'tm') as tm:
                self.assertEqual(approval.approve(['tmux'],'%1',42,123,'request',(10,20)),'CHANGED')
                self.assertNotIn('Enter',[c.args[-1] for c in tm.call_args_list])
        with patch.object(approval,'inspect',return_value=None),patch.object(approval,'tm') as tm:
            self.assertEqual(approval.approve(['tmux'],'%1',42,123,'request',(10,20)),'CHANGED')
            tm.assert_not_called()

    def test_navigation_waits_for_transient_blank_redraw(self):
        state=dict(token='request',base='screen',activity=0,selected=0,yes=1)
        selected=dict(state,token='moved',selected=1)
        with patch.object(approval,'inspect',side_effect=[state,None,None,selected,selected]),patch.object(approval,'tm') as tm:
            self.assertEqual(approval.approve(['tmux'],'%1',42,123,'request',(10,20)),'APPROVED')
            self.assertEqual([c.args[-1] for c in tm.call_args_list],['Down','Enter'])

    def test_final_check_runs_even_when_yes_is_already_selected(self):
        state=dict(token='request',base='screen',activity=0,selected=1,yes=1)
        with patch.object(approval,'inspect',side_effect=[state,None]),patch.object(approval,'tm') as tm:
            self.assertEqual(approval.approve(['tmux'],'%1',42,123,'request',(10,20)),'CHANGED')
            tm.assert_not_called()

    def test_probe_returns_only_identity_and_hashes(self):
        state=dict(token='a'*64,base='b'*64,selected=0,yes=1,activity=0)
        output=io.StringIO()
        with patch.object(approval,'inspect',return_value=state),contextlib.redirect_stdout(output):
            approval.main(['["tmux"]','probe','[{"pane":"%1","pid":"42","ticks":"123"}]'])
        self.assertEqual(output.getvalue(),'@@approval %1 42 123 '+'a'*64+' '+'b'*64+'\n')

    def test_process_identity_reads_start_tick_and_foreground_from_proc_fixture(self):
        with tempfile.TemporaryDirectory(prefix='agentmux-approval-proc-') as directory:
            root=Path(directory)
            p=root/'42'
            p.mkdir()
            fields=['S','12','42','12','100','42']+['0']*13+['123']
            (p/'stat').write_text('42 (claude) '+' '.join(fields))
            (p/'comm').write_text('claude\n')
            info=approval.process(42,root)
            self.assertEqual((info['ticks'],info['pgrp'],info['foreground'],info['name']),(123,42,42,'claude'))
            self.assertIsNone(approval.process(43,root))

    @unittest.skipUnless(shutil.which('tmux'), 'isolated tmux integration requires tmux')
    def test_real_tmux_selection_is_moved_and_submitted_once(self):
        # The only keys this test sends go to its newly created private socket.
        with tempfile.TemporaryDirectory(prefix='agentmux-approval-') as directory:
            base=Path(directory)
            output=base/'received.txt'
            program=base/'dialog.py'
            program.write_text('''import os,sys,termios,tty
fd=sys.stdin.fileno()
old=termios.tcgetattr(fd)
tty.setraw(fd)
selected=0
def draw():
    lines=['background frame for selection '+str(selected), '─'*100, 'synthetic action',
           "Auto mode can't check actions in this session, so this one needs your approval", 'Do you want to proceed?',
           ('❯ ' if selected==0 else '  ')+'No',
           ('❯ ' if selected==1 else '  ')+'Yes','Esc to cancel · Tab to amend']
    os.write(1,('\\x1b[2J\\x1b[H'+'\\r\\n'.join(lines)+'\\r\\n').encode())
draw()
try:
    while True:
        key=os.read(fd,1)
        if key==b'\\x1b':
            key+=os.read(fd,2)
        if key==b'\\x1b[B': selected=1; draw()
        elif key==b'\\x1b[A': selected=0; draw()
        elif key in (b'\\r',b'\\n'):
            with open(sys.argv[1],'a') as f: f.write(('Yes' if selected else 'No')+'\\n')
            os.write(1,b'\\x1b[2J\\x1b[Hcompleted\\r\\n')
finally:
    termios.tcsetattr(fd,termios.TCSANOW,old)
''')
            argv=[shutil.which('tmux'),'-L','agentmux-approval-'+uuid.uuid4().hex[:10],'-f','/dev/null']
            env=dict(os.environ)
            env.pop('TMUX',None)
            try:
                pane=subprocess.check_output(argv+['new-session','-d','-P','-F','#{pane_id}',
                    '-x','100','-y','24',shlex.join([sys.executable,'-u',str(program),str(output)])],env=env,text=True).strip()
                deadline=time.monotonic()+5
                while True:
                    captured=approval.tm(argv,'capture-pane','-p','-J','-t',pane)
                    parsed=approval.parse_screen(captured)
                    if parsed: break
                    self.assertLess(time.monotonic(),deadline,'synthetic dialog did not appear')
                    time.sleep(0.02)
                server=tuple(map(int,approval.tm(argv,'display-message','-p','-t',pane,'#{pid} #{start_time}').split()))
                fake=dict(pid=42,pgrp=42,foreground=42,ticks=123,alive=True,name='claude')
                # macOS has no /proc; the Linux identity checks have separate
                # fixtures above. Capture, cursor movement and Enter are real.
                with patch.object(approval,'process',return_value=fake),patch.object(approval,'belongs_to',return_value=True):
                    request=approval.inspect(argv,pane,42,123,server)
                    self.assertEqual(approval.approve(argv,pane,42,123,request['token'],server),'APPROVED')
                    self.assertEqual(approval.approve(argv,pane,42,123,request['token'],server),'CHANGED')
                deadline=time.monotonic()+2
                while not output.exists() and time.monotonic()<deadline: time.sleep(0.01)
                self.assertEqual(output.read_text(),'Yes\n')
            finally:
                subprocess.run(argv+['kill-server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__':
    unittest.main()

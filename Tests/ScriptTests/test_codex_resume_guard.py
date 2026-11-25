from contextlib import closing
import json
import os
from pathlib import Path
import runpy
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


GUARD = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts/agentmux-codex-resume.py"))
SID = "01a1c973-6fd1-7762-bd15-919f6b5e8c5b"
WRITER = "01a211f9-275b-7c01-b9f5-6fcf6c5b9238"
OTHER = "01a211fc-da42-74e2-9fcd-3d967e6676f7"


class ResumeGuardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name).resolve()
        self.source = self.home / ".codex"
        self.target = self.home / ".codex-3"
        self.sessions = self.source / "sessions"
        self.day = self.sessions / "2026/11/25"
        self.day.mkdir(parents=True)
        self.target.mkdir()
        (self.target / "sessions").symlink_to(self.sessions)
        self.root = self.rollout("10-00-00")

    def rollout(self, timestamp, writer=None, base=None, boundary_delta=0):
        suffix = f"_{writer}" if writer else ""
        p = self.day / f"rollout-2026-11-25T{timestamp}-{SID}{suffix}.jsonl"
        payload = {"id": SID}
        start = 0
        if base:
            ancestor, identity, end = base
            payload["history_base"] = {
                "thread_id": identity, "end_byte_offset": ancestor.stat().st_size,
                "end_ordinal_exclusive": end + boundary_delta,
            }
            start = end
        p.write_text(json.dumps({"type": "session_meta", "ordinal": start, "payload": payload}) + "\n"
                     + json.dumps({"type": "event_msg", "ordinal": start + 1, "payload": {}}) + "\n")
        return p

    def index(self, directory, path):
        with closing(sqlite3.connect(directory / "state_5.sqlite")) as db, db:
            db.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER)")
            db.execute("INSERT INTO threads VALUES (?, ?, 0)", (SID, str(path)))

    def test_routes_to_verified_continuation_even_when_ancestor_was_modified_later(self):
        middle = self.rollout("11-00-00", WRITER, (self.root, SID, 2))
        tip = self.rollout("12-00-00", OTHER, (middle, WRITER, 4))
        with self.root.open("a") as output:
            output.write('{"type":"event_msg","ordinal":2,"payload":{}}\n')
        indexes = {self.source: self.root, self.target: tip}
        self.assertEqual(GUARD["choose_route"](indexes, self.sessions, SID, self.source), self.target)

    def test_unindexed_new_segment_cannot_be_silently_ignored(self):
        self.rollout("11-00-00", WRITER, (self.root, SID, 2))
        with self.assertRaises(GUARD["ResumeConflict"]):
            GUARD["choose_route"]({self.source: self.root}, self.sessions, SID, self.source)

    def test_conflicting_siblings_and_bad_ordinal_are_rejected(self):
        one = self.rollout("11-00-00", WRITER, (self.root, SID, 2))
        two = self.rollout("12-00-00", OTHER, (self.root, SID, 2))
        with self.assertRaises(GUARD["ResumeConflict"]):
            GUARD["choose_route"]({self.source: one, self.target: two}, self.sessions, SID, self.source)
        with self.assertRaises(GUARD["ResumeConflict"]):
            invalid = self.rollout("12-00-00", OTHER, (self.root, SID, 2), boundary_delta=1)
            GUARD["lineage"](invalid, {self.root, invalid}, SID)

    def test_plain_resume_pins_runtime_and_retains_selected_account(self):
        tip = self.rollout("11-00-00", WRITER, (self.root, SID, 2))
        self.index(self.source, self.root)
        self.index(self.target, tip)
        binary = self.home / "native-codex"
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        argv = ["resume", SID, "message unchanged"]
        env = {"CODEX_HOME": str(self.source), "AGENTMUX_CODEX_REAL": str(binary)}
        with patch.dict(os.environ, env, clear=True), \
             patch.dict(GUARD["run"].__globals__, {"launch_codex": lambda exe, args, runtime:
                 (exe, args, runtime, os.environ["CODEX_HOME"])}):
            self.assertEqual(GUARD["run"](argv, self.home), (binary, argv, self.target, str(self.source)))
        pin, _ = GUARD["registry"](self.home, self.sessions, SID)
        self.assertEqual(json.loads(pin.read_text())["sqlite_home"], str(self.target))

    def test_second_guarded_writer_is_rejected(self):
        _, lease = GUARD["registry"](self.home, self.sessions, SID)
        with GUARD["lock"](lease, "busy"):
            with self.assertRaisesRegex(GUARD["ResumeConflict"], "busy"):
                with GUARD["lock"](lease, "busy"):
                    self.fail("two writers share the lease")

    def test_only_exact_local_uuid_resumes_are_guarded(self):
        self.assertEqual(GUARD["resume_uuid"](["resume", SID, "hello"]), SID)
        for args in (["resume", "--last"], ["resume", "by-name"], ["exec", "resume", SID],
                     ["resume", SID, "--remote", "unix://test"]):
            self.assertIsNone(GUARD["resume_uuid"](args))


if __name__ == "__main__":
    unittest.main()

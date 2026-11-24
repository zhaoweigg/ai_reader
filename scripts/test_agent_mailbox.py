import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from agent_mailbox import Mailbox, atomic_json

SCRIPT = str(Path(__file__).with_name("agent_mailbox.py"))


class MailboxTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "worker"
        (self.root / "from-coordinator").mkdir(parents=True)
        self.box = Mailbox(self.root, "worker")
        self.children = []
        self.addCleanup(self.stop_children)

    def stop_children(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate()

    def message(self, name, kind="GO", **payload):
        atomic_json(self.root / "from-coordinator" / (name + ".json"),
                    {"protocol_version": 1, "id": name, "sender": "coordinator", "type": kind, "payload": payload})

    def run_tool(self, *arguments):
        child = subprocess.Popen([sys.executable, SCRIPT, *arguments, "--worker", "worker", "--root", str(self.root)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        return child

    def lines(self, child, timeout=5):
        out, error = child.communicate(timeout=timeout)
        self.assertEqual(child.returncode, 0, error)
        return out.splitlines()

    def still_waiting(self, child, seconds=0.4):
        with self.assertRaises(subprocess.TimeoutExpired):
            child.wait(timeout=seconds)

    def test_a_message_that_arrived_before_the_watch_started_is_reported_at_once(self):
        self.message("coord-early")
        self.message("coord-done")
        self.box.ack("coord-done")
        lines = self.lines(self.run_tool("watch"))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("MAILBOX coord-early [GO] "), lines)

    def test_a_new_message_wakes_the_watch_without_polling(self):
        watch = self.run_tool("watch")
        self.still_waiting(watch)
        started = time.monotonic()
        self.message("coord-new", "BUILD_GO")
        lines = self.lines(watch)
        self.assertLess(time.monotonic() - started, 1.0, "reported as it lands, not on a timer")
        self.assertEqual([line.split()[1:3] for line in lines], [["coord-new", "[BUILD_GO]"]])

    def test_every_pending_message_is_listed_and_acknowledged_ones_never_return(self):
        for name in ("coord-a", "coord-b", "coord-c"):
            self.message(name)
        self.assertEqual([line.split()[1] for line in self.lines(self.run_tool("watch"))], ["coord-a", "coord-b", "coord-c"])
        self.box.ack("coord-a")
        self.box.ack("coord-c")
        # Nothing remembers what an earlier watch printed: an unacknowledged message is reported again.
        self.assertEqual([line.split()[1] for line in self.lines(self.run_tool("watch"))], ["coord-b"])
        self.box.ack("coord-b")
        self.still_waiting(self.run_tool("watch"))

    def test_an_ack_at_the_path_the_message_names_counts(self):
        named = self.root / "elsewhere" / "ack.json"
        self.message("coord-named", ack_path=str(named))
        self.assertEqual(len(self.box.scan()[0]), 1)
        path, wrote = self.box.ack("coord-named")
        self.assertEqual((path, wrote), (named, True))
        self.assertEqual(self.box.scan()[0], [])
        self.assertEqual(self.box.ack("coord-named"), (named, False))

    def test_a_message_a_running_job_waits_for_is_left_to_it_and_reported_if_the_job_dies(self):
        waiter = self.run_tool("wait", "coord-round-GO")
        deadline = time.monotonic() + 5
        while not (self.root / "claims" / "coord-round-GO.json").exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        watch = self.run_tool("watch")
        self.still_waiting(watch)
        self.message("coord-round-GO")
        self.assertEqual(self.lines(waiter), [str(self.root / "from-coordinator" / "coord-round-GO.json")])
        # The job that claimed it has exited without acknowledging: the watch reports it now.
        self.assertEqual([line.split()[1] for line in self.lines(watch)], ["coord-round-GO"])
        self.assertFalse((self.root / "claims" / "coord-round-GO.json").exists(), "a finished job removes its claim")

    def test_a_claim_left_by_a_dead_process_does_not_hide_a_message(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        atomic_json(self.root / "claims" / "coord-orphan.json", {"pid": dead.pid})
        self.message("coord-orphan")
        self.assertEqual([name for name, _, _ in self.box.scan()[0]], ["coord-orphan"])

    def test_a_file_still_being_written_is_reported_once_complete(self):
        path = self.root / "from-coordinator" / "coord-slow.json"
        text = json.dumps({"id": "coord-slow", "type": "GO", "payload": {}})
        path.write_text(text[:10])
        watch = self.run_tool("watch")
        self.still_waiting(watch)
        with open(path, "a") as stream:
            stream.write(text[10:])
        self.assertEqual([line.split()[1:3] for line in self.lines(watch)], [["coord-slow", "[GO]"]])

    def test_a_file_that_never_becomes_readable_is_reported_as_such(self):
        (self.root / "from-coordinator" / "coord-broken.json").write_text("{")
        lines = self.lines(self.run_tool("watch"), timeout=8)
        self.assertEqual([line.split()[1:3] for line in lines], [["coord-broken", "[UNREADABLE]"]])

    def test_the_baseline_leaves_out_old_backlog_but_not_what_arrives_later(self):
        self.message("coord-old-1")
        self.message("coord-old-2")
        child = self.run_tool("baseline", "--note", "before the watcher existed")
        self.assertIn("2 unacknowledged messages", self.lines(child)[0])
        watch = self.run_tool("watch")
        self.still_waiting(watch)
        self.message("coord-after")
        self.assertEqual([line.split()[1] for line in self.lines(watch)], ["coord-after"])
        self.assertEqual(json.loads((self.root / "watch-baseline.json").read_text())["ignored"], ["coord-old-1", "coord-old-2"])

    def test_stream_reports_each_message_once_and_keeps_running(self):
        self.message("coord-first")
        watch = self.run_tool("watch", "--stream")
        self.assertEqual(watch.stdout.readline().split()[1], "coord-first")
        self.message("coord-second")
        self.assertEqual(watch.stdout.readline().split()[1], "coord-second")
        self.still_waiting(watch, 0.3)

    def test_wait_times_out_with_its_own_exit_code(self):
        child = self.run_tool("wait", "coord-never", "--timeout", "0.3")
        child.communicate(timeout=5)
        self.assertEqual(child.returncode, 3)

    def test_an_idle_watch_uses_no_processor_time(self):
        watch = self.run_tool("watch")
        self.still_waiting(watch, 1.0)
        used = subprocess.check_output(["ps", "-o", "time=", "-p", str(watch.pid)], text=True).strip()
        minutes, seconds = used.split(":")
        self.assertLess(int(minutes) * 60 + float(seconds), 0.5, used)


if __name__ == "__main__":
    unittest.main()

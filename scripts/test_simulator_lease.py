import unittest
import contextlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch, Mock
from simulator_lease import validate, main


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.record = {"owner_thread": "worker", "lease_id": "new-job", "head": "source",
                       "device_uuid": "DEVICE-A", "state": "assigned"}
        self.registry = {"slots": {"A": self.record}}

    def check(self, **changes):
        values = dict(slot="A", owner="worker", lease="new-job", head="source", device="DEVICE-A")
        values.update(changes)
        return validate(self.registry, **values)

    def test_current_lease_passes_without_mutating_record(self):
        self.assertEqual(self.check()["lease_id"], "new-job")
        self.assertEqual(self.record["state"], "assigned")

    def test_cli_accepts_registered_third_slot(self):
        record = {**self.record, "device_uuid": "DEVICE-C"}
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "registry.json"
            registry.write_text(json.dumps({"slots": {"C": record}}))
            args = ["simulator_lease.py", "--registry", str(registry), "--slot", "C",
                    "--owner", "worker", "--lease", "new-job", "--head", "source",
                    "--device", "DEVICE-C", "--worktree", directory, "--require-idle"]
            output = io.StringIO()
            with patch("sys.argv", args), patch("simulator_lease.subprocess.check_output", side_effect=["source", ""]), \
                 patch("simulator_lease.subprocess.run", return_value=Mock(returncode=0)), contextlib.redirect_stdout(output):
                self.assertEqual(main(), 0)
            self.assertEqual(json.loads(output.getvalue())["slot"], "C")

    def test_unregistered_slot_is_still_refused(self):
        with self.assertRaisesRegex(ValueError, "Lease mismatch"):
            self.check(slot="C")

    def test_delayed_old_go_is_rejected_even_for_same_worker(self):
        with self.assertRaisesRegex(ValueError, "lease_id"):
            self.check(lease="old-job")

    def test_new_owner_wins_over_old_message(self):
        self.record["owner_thread"] = "other-worker"
        with self.assertRaisesRegex(ValueError, "owner_thread"):
            self.check()

    def test_source_and_device_are_both_bound(self):
        for change in ({"head": "old-source"}, {"device": "DEVICE-B"}):
            with self.assertRaises(ValueError):
                self.check(**change)

    def test_unowned_or_recovering_is_not_a_test_lease(self):
        for state in ("available", "recovering", "finalizing"):
            self.record["state"] = state
            with self.assertRaises(ValueError):
                self.check()

    def test_even_finalizing_old_xcodebuild_blocks_new_launch(self):
        with self.assertRaisesRegex(ValueError, "PID 123"):
            self.check(process_lines=["123 /Applications/Xcode.app/bin/xcodebuild -destination id=DEVICE-A test"])

    def test_other_device_and_shell_mentions_do_not_block(self):
        self.check(process_lines=["123 /Applications/Xcode.app/bin/xcodebuild -destination id=DEVICE-B test",
                                  "456 /bin/zsh -c echo xcodebuild DEVICE-A"])

    def test_orphaned_ui_runner_blocks_after_xcodebuild_exits(self):
        with self.assertRaisesRegex(ValueError, "PID 789"):
            self.check(process_lines=["789 /CoreSimulator/Devices/DEVICE-A/data/App/LeafReaderUITests-Runner"])


if __name__ == "__main__":
    unittest.main()

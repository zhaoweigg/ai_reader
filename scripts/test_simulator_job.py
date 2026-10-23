import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

module_spec = importlib.util.spec_from_file_location("simulator_job", Path(__file__).with_name("simulator_job.py"))
job = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(job)


class SimulatorJobTests(unittest.TestCase):
    def test_stale_lease_aborts_before_any_device_or_preference_access(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "spec.json"
            path.write_text(json.dumps(dict(worktree=directory, registry=directory + "/registry.json",
                slot="A", owner="worker", lease_id="stale", head="head", device_uuid="device")))
            with patch.object(sys, "argv", ["simulator_job.py", str(path)]), \
                 patch.object(job.subprocess, "run", side_effect=subprocess.CalledProcessError(2, "guard")) as run, \
                 patch.object(job, "device_preferences") as preferences:
                with self.assertRaises(subprocess.CalledProcessError):
                    job.main()
                preferences.assert_not_called()
                self.assertEqual(run.call_count, 1)
                self.assertIn("--require-idle", run.call_args.args[0])
                self.assertEqual(Path(run.call_args.args[0][1]), Path(job.__file__).resolve().with_name("simulator_lease.py"))

    def test_stale_lease_cannot_use_an_obsolete_permissive_worktree_guard(self):
        # An older feature branch may have a different CLI or guard. Never copy
        # into its frozen tracked tree or let its old guard bypass current leases.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            (root / "scripts").mkdir()
            (root / "scripts/simulator_lease.py").write_text("raise SystemExit(0)\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                            "commit", "-qm", "old branch guard"], cwd=root, check=True)
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            registry = root / "registry.json"
            registry.write_text(json.dumps({"slots": {"C": {"owner_thread": "new-owner",
                "lease_id": "new-lease", "head": head, "device_uuid": "C-device", "state": "assigned"}}}))
            spec = root / "spec.json"
            spec.write_text(json.dumps(dict(worktree=directory, registry=str(registry), slot="C",
                owner="stale-owner", lease_id="stale-lease", head=head, device_uuid="C-device")))
            with patch.object(sys, "argv", ["simulator_job.py", str(spec)]), \
                 patch.object(job, "keyboard_snapshot") as preferences:
                with self.assertRaises(subprocess.CalledProcessError):
                    job.main()
                preferences.assert_not_called()
            self.assertEqual((root / "scripts/simulator_lease.py").read_text(), "raise SystemExit(0)\n")
            self.assertEqual(subprocess.check_output(["git", "diff", "--name-only"], cwd=root, text=True), "")

    def test_absent_keyboard_restoration_preserves_own_other_keys_and_peer_device(self):
        values = {"A": {"Scale": 0.75}, "B": {"ConnectHardwareKeyboard": True, "Scale": 1.0}}
        peer = copy.deepcopy(values["B"])
        with patch.object(job, "device_preferences", side_effect=lambda device: values[device].copy()), \
             patch.object(job, "write_device_preferences", side_effect=lambda device, value: values.__setitem__(device, value)):
            original = job.keyboard_snapshot("A")
            job.set_keyboard("A", {"present": True, "value": False})
            values["A"]["Window"] = "retained"
            job.set_keyboard("A", original)
        self.assertEqual(values["A"], {"Scale": 0.75, "Window": "retained"})
        self.assertEqual(values["B"], peer)

    def test_clipboard_probe_is_opt_in_so_copy_suites_can_change_it(self):
        self.assertIsNone(job.clipboard_probe_token({}))
        spec = {"slot": "A", "test_runner_env": {"LEAF_ISOLATION_RUN": "unique-run"}}
        self.assertIsNone(job.clipboard_probe_token(spec))
        spec["clipboard_probe"] = True
        self.assertEqual(job.clipboard_probe_token(spec), b"A-unique-run")

    def test_runner_exit_wait_is_scoped_to_the_assigned_uuid(self):
        peer = "42 /Devices/B/data/LeafReaderUITests-Runner.app/LeafReaderUITests-Runner"
        own = "43 /Devices/A/data/LeafReaderUITests-Runner.app/LeafReaderUITests-Runner"
        with patch.object(job.subprocess, "check_output", return_value=peer):
            job.wait_for_runner_exit("A", timeout=0)
        with patch.object(job.subprocess, "check_output", return_value=own):
            with self.assertRaisesRegex(RuntimeError, "retain the lease"):
                job.wait_for_runner_exit("A", timeout=0)

    def test_boolean_and_integer_preference_types_restore_exactly(self):
        for original_value in (False, True, 0, 1):
            value = {"ConnectHardwareKeyboard": original_value}
            def write(_device, updated):
                value.clear(); value.update(updated)
            with patch.object(job, "device_preferences", side_effect=lambda _: value.copy()), \
                 patch.object(job, "write_device_preferences", side_effect=write):
                original = job.keyboard_snapshot("A")
                job.set_keyboard("A", {"present": True, "value": False})
                job.set_keyboard("A", original)
            self.assertIs(type(value["ConnectHardwareKeyboard"]), type(original_value))
            self.assertEqual(value["ConnectHardwareKeyboard"], original_value)


if __name__ == "__main__":
    unittest.main()

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

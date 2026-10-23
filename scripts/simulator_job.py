#!/usr/bin/env python3
"""Run one already-granted simulator job and restore only its keyboard preference.

The coordinator assigns leases separately. This runner never writes ownership.
The shared preference lock protects the read/modify/write across independent jobs.
"""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".job-")
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


@contextlib.contextmanager
def preference_lock(registry):
    with open(Path(registry).parent / "simulator-preferences.lock", "a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def device_preferences(device):
    data = subprocess.check_output(["defaults", "export", "com.apple.iphonesimulator", "-"])
    return plistlib.loads(data).get("DevicePreferences", {}).get(device, {}).copy()


def write_device_preferences(device, value):
    # -dict-add changes only this UUID, not the entire shared DevicePreferences map.
    subprocess.run(["defaults", "write", "com.apple.iphonesimulator", "DevicePreferences",
                    "-dict-add", device, plistlib.dumps(value).decode()], check=True)


def keyboard_snapshot(device):
    value = device_preferences(device)
    return {"present": "ConnectHardwareKeyboard" in value,
            "value": value.get("ConnectHardwareKeyboard")}


def set_keyboard(device, snapshot):
    value = device_preferences(device)
    if snapshot["present"]:
        value["ConnectHardwareKeyboard"] = snapshot["value"]
    else:
        value.pop("ConnectHardwareKeyboard", None)
    write_device_preferences(device, value)
    actual = keyboard_snapshot(device)
    if actual != snapshot or type(actual["value"]) is not type(snapshot["value"]):
        raise RuntimeError("Keyboard preference did not round-trip exactly")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text())
    worktree = Path(spec["worktree"])
    guard = [sys.executable, str(worktree / "scripts/simulator_lease.py"),
             "--registry", spec["registry"], "--slot", spec["slot"],
             "--owner", spec["owner"], "--lease", spec["lease_id"],
             "--head", spec["head"], "--device", spec["device_uuid"],
             "--worktree", str(worktree)]
    subprocess.run(guard + ["--require-idle"], check=True)
    result = worktree / spec["result_bundle"]
    if result.exists():
        raise RuntimeError("Result bundle already exists; refusing to overwrite evidence")
    metadata = {"spec": spec, "prepared_at": stamp()}
    evidence = worktree / spec["evidence"]
    env = os.environ.copy()
    for key, value in spec.get("test_runner_env", {}).items():
        env["TEST_RUNNER_" + key] = value
    command = ["xcodebuild", "test-without-building", "-project", "LeafReader.xcodeproj",
               "-scheme", "LeafReader", "-destination", "platform=iOS Simulator,id=" + spec["device_uuid"],
               "-derivedDataPath", spec["derived_data"], "-parallel-testing-enabled", "NO",
               "-resultBundlePath", spec["result_bundle"]]
    command += ["-only-testing:" + identifier for identifier in spec["tests"]]
    original = None
    original_clipboard = None
    process = None
    exit_code = 1
    def forward_signal(number, _frame):
        if process is not None and process.poll() is None:
            os.killpg(process.pid, number)
    previous_handlers = {number: signal.signal(number, forward_signal)
                         for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        with preference_lock(spec["registry"]):
            original = keyboard_snapshot(spec["device_uuid"])
            metadata["original_keyboard"] = original
            atomic_json(evidence, metadata)  # persist before the first preference mutation
            set_keyboard(spec["device_uuid"], {"present": True, "value": False})
        subprocess.run(guard + ["--require-idle"], check=True)
        original_clipboard = subprocess.check_output(
            ["xcrun", "simctl", "pbpaste", spec["device_uuid"]], timeout=10)
        clipboard_token = (spec["slot"] + "-" + spec["test_runner_env"]["LEAF_ISOLATION_RUN"]).encode()
        subprocess.run(["xcrun", "simctl", "pbcopy", spec["device_uuid"]],
                       input=clipboard_token, timeout=10, check=True)
        started = time.monotonic()
        with open(worktree / spec["log"], "w") as log:
            process = subprocess.Popen(command, cwd=worktree, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            metadata.update(started_at=stamp(), pid=process.pid, command=command)
            atomic_json(evidence, metadata)
            print(json.dumps({"event": "START", "slot": spec["slot"], "pid": process.pid,
                              "lease_id": spec["lease_id"]}), flush=True)
            try:
                exit_code = process.wait(timeout=spec.get("timeout", 600))
            except subprocess.TimeoutExpired:
                metadata["timed_out"] = True
                for number, seconds in [(signal.SIGINT, 20), (signal.SIGTERM, 10), (signal.SIGKILL, 10)]:
                    os.killpg(process.pid, number)
                    try:
                        exit_code = process.wait(timeout=seconds)
                        break
                    except subprocess.TimeoutExpired:
                        continue
        clipboard = subprocess.check_output(["xcrun", "simctl", "pbpaste", spec["device_uuid"]], timeout=10)
        metadata["clipboard_isolated"] = clipboard == clipboard_token
        if not metadata["clipboard_isolated"]:
            exit_code = exit_code or 1
        metadata.update(actual_exit=exit_code, finished_at=stamp(), seconds=time.monotonic() - started)
    finally:
        # An exception or interrupt must never restore preferences while our child still runs.
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=30)
        if original_clipboard is not None:
            subprocess.run(guard, check=True)
            subprocess.run(["xcrun", "simctl", "pbcopy", spec["device_uuid"]],
                           input=original_clipboard, timeout=10, check=True)
            metadata["clipboard_restored"] = True
        if original is not None:
            # Never restore preferences after ownership has moved to a different lease.
            subprocess.run(guard, check=True)
            with preference_lock(spec["registry"]):
                set_keyboard(spec["device_uuid"], original)
                metadata["restored_keyboard"] = keyboard_snapshot(spec["device_uuid"])
                metadata["preferences_restored"] = True
        atomic_json(evidence, metadata)
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    print(json.dumps({"event": "RELEASE", "slot": spec["slot"], "actual_exit": exit_code,
                      "lease_id": spec["lease_id"], "evidence": str(evidence)}), flush=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

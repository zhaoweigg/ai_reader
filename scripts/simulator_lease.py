#!/usr/bin/env python3
"""Fail closed before simulator jobs when a delayed GO no longer owns the slot.

This is read-only. The coordinator must not revoke a granted lease until release
or cancellation acknowledgement AND actual job exit, so a successful preflight
remains valid through launch. Workers send events; only the coordinator writes.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


def validate(registry, slot, owner, lease, head, device, process_lines=()):
    record = registry.get("slots", {}).get(slot, {})
    expected = {"owner_thread": owner, "lease_id": lease, "head": head, "device_uuid": device}
    for key, value in expected.items():
        if not value or record.get(key) != value:
            raise ValueError(f"Lease mismatch: {slot}.{key}; do not use this device")
    if record.get("state") not in ("assigned", "testing"):
        raise ValueError(f"Slot {slot} is not assigned for testing")
    for line in process_lines:
        match = re.match(r"\s*(\d+)\s+(\S+)(.*)", line)
        if not match:
            continue
        executable = Path(match[2]).name
        test_process = executable in ("xcodebuild", "xctest") or executable.endswith("UITests-Runner")
        if test_process and device in match[2] + match[3]:
            raise ValueError(f"Device already has test process PID {match[1]}; wait for actual exit")
    return {"slot": slot, "device_uuid": device, "lease_id": lease, "head": head}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--slot", required=True, help="Slot name present in the canonical registry (A, B, C, ...)")
    parser.add_argument("--owner", required=True)
    parser.add_argument("--lease", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--require-idle", action="store_true", help="Required before starting a new test job")
    args = parser.parse_args()
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.worktree, text=True).strip()
        if head != args.head:
            raise ValueError("Worktree HEAD differs from the granted/tested source")
        for diff in (["git", "diff", "--quiet"], ["git", "diff", "--cached", "--quiet"]):
            if subprocess.run(diff, cwd=args.worktree).returncode:
                raise ValueError("Tracked worktree changes differ from the granted source")
        lines = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True).splitlines() if args.require_idle else []
        result = validate(json.loads(args.registry.read_text()), args.slot, args.owner,
                          args.lease, args.head, args.device, lines)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2
    print(json.dumps({"ok": True, **result}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Expire generated Leaf artifacts after 72 hours. Dry-run unless --apply is set.

Use a fresh coordinator keep file: {"collected_at": <epoch>, "paths": [...] }.
The keep file names artifacts currently consumed by jobs, pending handoffs or installs.
Source checkouts, recovery bundles, reusable models and live control data are excluded.
"""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time

RETENTION_SECONDS = 72 * 3600
CONTROL_NAMES = {"simulator-coordination.json", "simulator-preferences.lock",
                 "retention-current-active-paths.json"}
SOURCE_SUFFIXES = {".py", ".sh", ".js", ".swift", ".c", ".h", ".bundle", ".p12", ".p8",
                   ".mobileprovision", ".onnx", ".safetensors"}


def related(a, b):
    return a == b or a in b.parents or b in a.parents


def source_or_asset(path):
    if path.name in CONTROL_NAMES or path.name.startswith(".") or path.name.lower().startswith(("license", "copying", "copyright")):
        return True
    if not path.is_dir() or path.is_symlink():
        return path.suffix in SOURCE_SUFFIXES
    return (path / ".git").exists() or (path / "LeafReader").is_dir() or any(
        path.glob("*.xcodeproj")) or "model" in path.name.lower() or path.name == "ThirdParty"


def build_units(build):
    """Keep archived source; evaluate relocated generated outputs using their original mtimes."""
    for child in sorted(build.iterdir()):
        if source_or_asset(child):
            continue
        if child.is_dir() and not child.is_symlink():
            if child.name == "agent-mailbox":
                # Only completed, acknowledged message pairs expire. Unread messages remain live.
                for worker in (child / "v1").glob("*"):
                    for origin, acknowledger in [("from-worker", "by-coordinator"), ("from-coordinator", "by-worker")]:
                        for message in (worker / origin).glob("*.json"):
                            ack = worker / "acks" / acknowledger / message.name
                            if ack.is_file() and not message.is_symlink() and not ack.is_symlink():
                                yield message
                                yield ack
                        for ack in (worker / "acks" / acknowledger).glob("*.json"):
                            if not (worker / origin / ack.name).exists() and not ack.is_symlink():
                                yield ack
                continue
            if child.name == "worktree-archives":
                for archived in child.glob("*/*/checkout/build"):
                    if not any(part.is_symlink() for part in [archived, *archived.parents] if part != child and child in part.parents):
                        yield from build_units(archived)
                continue
            if child.name.startswith("retained-worktree-evidence-"):
                for entry in sorted(child.iterdir()):
                    if entry.is_dir() and not entry.is_symlink():
                        if (entry / "build").is_dir() and not (entry / "build").is_symlink():
                            yield from build_units(entry / "build")
                    elif not source_or_asset(entry):
                        yield entry
                continue
            if child.name.endswith("-archive") and (child / "build").is_dir() and not (child / "build").is_symlink():
                yield from build_units(child / "build")
                for metadata in child.iterdir():
                    if not metadata.is_dir() and not source_or_asset(metadata):
                        yield metadata
                continue
        yield child


@dataclass(frozen=True)
class Snapshot:
    newest: float
    files: int
    bytes: int
    allocated_bytes: int


def snapshot(path):
    """Do not follow links or let a directory touched by relocation renew old evidence."""
    newest, files, size, allocated = 0.0, 0, 0, 0
    pending = [path]
    while pending:
        current = pending.pop()
        info = current.lstat()
        if stat.S_ISDIR(info.st_mode):
            pending.extend(current.iterdir())
        else:
            newest = max(newest, info.st_mtime)
            files += 1
            size += info.st_size
            allocated += getattr(info, "st_blocks", 0) * 512
    return Snapshot(newest, files, size, allocated)


def remove_tree(path):
    # QA freezes signed bundles with read-only directories. Only unlock the expired
    # artifact selected for removal; leave protected/current artifacts untouched.
    for directory, _, _ in os.walk(path, followlinks=False):
        current = Path(directory)
        info = current.lstat()
        if stat.S_ISDIR(info.st_mode):
            current.chmod(stat.S_IMODE(info.st_mode) | stat.S_IWUSR | stat.S_IXUSR)
    shutil.rmtree(path)


def sweep(builds, keeps=(), *, now=None, apply=False):
    now = time.time() if now is None else now
    cutoff = now - RETENTION_SECONDS
    report = {"created_at": now, "cutoff": cutoff, "apply": apply,
              "expired": [], "protected": [], "changed": [], "errors": []}
    for build in builds:
        if not build.is_dir() or build.is_symlink():
            continue
        for path in build_units(build):
            if any(related(path, keep) for keep in keeps):
                report["protected"].append(str(path))
                continue
            try:
                before = snapshot(path)
                if before.newest >= cutoff:
                    continue
                entry = {"path": str(path), **before.__dict__}
                if apply:
                    # Recheck immediately before deleting an artifact as a complete unit.
                    if snapshot(path) != before:
                        report["changed"].append(str(path))
                        continue
                    if path.is_symlink() or not path.is_dir():
                        path.unlink()
                    else:
                        remove_tree(path)
                report["expired"].append(entry)
            except OSError as error:
                report["errors"].append({"path": str(path), "error": str(error)})
    report["expired_bytes"] = sum(e["bytes"] for e in report["expired"])
    report["expired_allocated_bytes"] = sum(e["allocated_bytes"] for e in report["expired"])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--keep-file", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    output = subprocess.check_output(["git", "-C", str(root), "worktree", "list", "--porcelain"], text=True)
    builds = [Path(line[9:]) / "build" for line in output.splitlines() if line.startswith("worktree ")]
    keeps = []
    if args.keep_file:
        record = json.loads(args.keep_file.read_text())
        age = time.time() - record["collected_at"]
        if not 0 <= age <= 900:
            parser.error("The active-path inventory must be collected within the last 15 minutes")
        keeps = [Path(os.path.abspath(p)) for p in record["paths"]]
        keeps.extend([args.keep_file.absolute(), args.report.absolute()])
    elif args.apply:
        parser.error("--apply requires a fresh --keep-file after checking active jobs and pending installs")
    report = sweep(builds, keeps, apply=args.apply)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.report.with_suffix(args.report.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    os.replace(temporary, args.report)
    print(json.dumps({k: v for k, v in report.items() if not isinstance(v, list)}))
    print(json.dumps({k: len(v) for k, v in report.items() if isinstance(v, list)}))
    return bool(report["errors"])


if __name__ == "__main__":
    raise SystemExit(main())

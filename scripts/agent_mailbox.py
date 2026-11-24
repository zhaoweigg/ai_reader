#!/usr/bin/env python3
"""Event-driven reader for a worker's agent mailbox (build/agent-mailbox/v1/<worker>).

A worker that cannot be messaged directly (a Claude Code session) keeps one `watch` running
in the background. It sleeps in the kernel (kqueue) until the coordinator's file lands, then
prints one line per message and exits, which wakes the session. Nothing is polled.

No message can be missed:
- What is pending is read from disk each time: a coordinator message with no ACK in
  acks/by-worker. A message that arrived before the watch started, or between two
  watches, is reported the moment the next watch starts.
- The directory is registered with the kernel before it is scanned, so a message cannot
  land in between.
- A message some running job is waiting for by name (`wait`, or `claim` from a round
  runner) is left to that job. If the job dies before acknowledging it, the watch
  reports it at once.

usage:
  agent_mailbox.py watch    --worker ID            exit as soon as anything is pending
  agent_mailbox.py wait     --worker ID NAME       block until from-coordinator/NAME.json exists
  agent_mailbox.py pending  --worker ID            list what is pending now
  agent_mailbox.py ack      --worker ID NAME       acknowledge a message that was read
  agent_mailbox.py baseline --worker ID            leave today's unacknowledged backlog out of `watch`
"""
import argparse
import atexit
import datetime
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CHANGED = (select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE
           | select.KQ_NOTE_ATTRIB | select.KQ_NOTE_LINK) if hasattr(select, "kqueue") else 0
# A file that is not yet valid JSON is still being written. It is reported as unreadable
# only if it stays that way this long; the wait is a single deadline, not a loop.
UNREADABLE_AFTER = 2.0


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    with os.fdopen(handle, "w") as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.rename(temporary, path)


def main_checkout():
    """The shared checkout, where every worktree finds the same build/ directory."""
    common = subprocess.check_output(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                     cwd=Path(__file__).resolve().parent, text=True).strip()
    return Path(common).parent


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Mailbox:
    def __init__(self, root, worker):
        self.root, self.worker = Path(root), worker
        self.inbox = self.root / "from-coordinator"
        self.acks = self.root / "acks" / "by-worker"
        self.claims = self.root / "claims"
        self.baseline_path = self.root / "watch-baseline.json"
        self._claimed = []

    # Reading

    def read(self, path):
        try:
            value = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def message_id(self, message, path):
        return (message or {}).get("id") or Path(path).stem

    def acknowledged(self, message, path):
        payload = (message or {}).get("payload")
        named = payload.get("ack_path") if isinstance(payload, dict) else None
        if named and os.path.exists(named):
            return True
        return any((self.acks / (name + ".json")).exists() for name in {self.message_id(message, path), Path(path).stem})

    def ignored(self):
        value = self.read(self.baseline_path) or {}
        return set(value.get("ignored", []))

    def live_claims(self):
        """{message name: pid} for claims whose job is still running."""
        found = {}
        for path in self.claims.glob("*.json"):
            pid = (self.read(path) or {}).get("pid")
            if isinstance(pid, int) and alive(pid):
                found[path.stem] = pid
        return found

    def scan(self):
        """(ready, unreadable, claims): ready is [(id, type, path)] for a session to act on."""
        ignored, claims, ready, unreadable = self.ignored(), self.live_claims(), [], []
        def arrival(item):
            try:
                return (item.stat().st_mtime, item.name)
            except OSError:
                return (0, item.name)
        for path in sorted(self.inbox.glob("*.json"), key=arrival):
            message = self.read(path)
            if self.acknowledged(message, path):
                continue
            if message is None:
                unreadable.append(path)
                continue
            name = self.message_id(message, path)
            if name in ignored or path.stem in ignored or name in claims or path.stem in claims:
                continue
            ready.append((name, str(message.get("type", "?")), path))
        return ready, unreadable, claims

    # Writing

    def ack(self, name, note=""):
        path = self.inbox / (name + ".json")
        message = self.read(path)
        if message is None:
            raise SystemExit("no readable message: " + str(path))
        payload = message.get("payload") if isinstance(message.get("payload"), dict) else {}
        target = Path(payload.get("ack_path") or self.acks / (self.message_id(message, path) + ".json"))
        if target.exists():
            return target, False
        now, identity = stamp(), self.message_id(message, path)
        atomic_json(target, {"protocol_version": 1, "id": "ack-" + identity, "sender": self.worker, "recipient": "coordinator",
                             "type": "ACK", "created_at": now, "reply_to": identity,
                             "payload": {"message_id": identity, "received_at": now, "payload_read": True, "note": note}})
        return target, True

    def claim(self, names, owner=""):
        """Tell `watch` that this process will handle these messages itself."""
        if not self._claimed:
            atexit.register(self.release)
        for name in names:
            atomic_json(self.claims / (name + ".json"), {"pid": os.getpid(), "owner": owner, "created_at": stamp()})
            self._claimed.append(name)

    def release(self):
        for name in self._claimed:
            path = self.claims / (name + ".json")
            if (self.read(path) or {}).get("pid") == os.getpid():
                try:
                    path.unlink()
                except OSError:
                    pass
        self._claimed = []

    def set_baseline(self, note):
        ready, _, _ = self.scan()
        ignored = sorted(self.ignored() | {name for name, _, _ in ready})
        atomic_json(self.baseline_path, {"created_at": stamp(), "worker": self.worker, "note": note, "ignored": ignored})
        return len(ready), len(ignored)

    # Waiting

    def wait_for(self, name, timeout=None):
        """Block until from-coordinator/<name>.json is complete; return (path, message)."""
        path, deadline = self.inbox / (name + ".json"), None if timeout is None else time.monotonic() + timeout
        with Events() as events:
            events.directory(self.inbox)
            while True:
                if path.exists():
                    events.file(path)
                    message = self.read(path)
                    if message is not None:
                        return path, message
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise TimeoutError("timed out waiting for " + name)
                events.wait(remaining)

    def watch(self, stream=False, emit=print):
        """Report every pending message. Returns after the first report unless `stream`."""
        self.claims.mkdir(parents=True, exist_ok=True)
        reported, first_unreadable = set(), {}
        with Events() as events:
            events.directory(self.inbox)
            events.directory(self.claims)
            while True:
                ready, unreadable, claims = self.scan()
                # Register before trusting what was just read: a change in between wakes the wait.
                added = [events.file(path) for path in unreadable]
                added += [events.process(pid) for pid in set(claims.values())]
                if any(added):
                    continue
                now = time.monotonic()
                for path in unreadable:
                    first_unreadable.setdefault(path, now)
                overdue = [path for path in unreadable if now - first_unreadable[path] >= UNREADABLE_AFTER]
                lines = [(name, "MAILBOX %s [%s] %s" % (name, kind, path)) for name, kind, path in ready]
                lines += [(path.stem, "MAILBOX %s [UNREADABLE] %s" % (path.stem, path)) for path in overdue]
                fresh = [line for name, line in lines if name not in reported]
                for line in fresh:
                    emit(line)
                reported.update(name for name, _ in lines)
                if fresh:
                    sys.stdout.flush()
                    if not stream:
                        return len(fresh)
                waiting = [first_unreadable[path] + UNREADABLE_AFTER - now for path in unreadable if path not in overdue]
                events.wait(max(0.05, min(waiting)) if waiting else None)


class Events:
    """Kernel notifications for directories, files still being written, and jobs exiting."""

    def __init__(self):
        if not hasattr(select, "kqueue"):
            raise SystemExit("agent_mailbox.py needs kqueue (macOS)")
        self.queue, self.descriptors, self.processes = select.kqueue(), {}, set()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        for descriptor in self.descriptors.values():
            os.close(descriptor)
        self.queue.close()

    def _vnode(self, path):
        key = str(path)
        if key in self.descriptors:
            return False
        try:
            descriptor = os.open(key, os.O_RDONLY)
        except OSError:
            return False
        self.descriptors[key] = descriptor
        self.queue.control([select.kevent(descriptor, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, CHANGED)], 0)
        return True

    def directory(self, path):
        Path(path).mkdir(parents=True, exist_ok=True)
        return self._vnode(path)

    def file(self, path):
        return self._vnode(path)

    def process(self, pid):
        """True when newly registered, or when the process is already gone (scan again)."""
        if pid in self.processes:
            return False
        self.processes.add(pid)
        try:
            self.queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)], 0)
        except (ProcessLookupError, PermissionError):
            pass
        return True

    def wait(self, timeout=None):
        for event in self.queue.control(None, 32, timeout):
            if event.filter == select.KQ_FILTER_PROC:
                self.processes.discard(event.ident)
            elif event.fflags & (select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME):
                # The watched file was replaced or removed: forget it so its successor is registered.
                for key, descriptor in list(self.descriptors.items()):
                    if descriptor == event.ident and not os.path.isdir(key):
                        os.close(descriptor)
                        del self.descriptors[key]


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["watch", "wait", "pending", "ack", "baseline"])
    parser.add_argument("name", nargs="?")
    parser.add_argument("--worker", required=True)
    parser.add_argument("--root", help="mailbox directory (default: <main checkout>/build/agent-mailbox/v1/<worker>)")
    parser.add_argument("--stream", action="store_true", help="watch: keep running, one line per new message")
    parser.add_argument("--timeout", type=float, help="wait: seconds before giving up (exit 3)")
    parser.add_argument("--note", default="")
    # Intermixed, so the message name may follow --worker as the usage line shows.
    options = parser.parse_intermixed_args(arguments)
    root = Path(options.root) if options.root else main_checkout() / "build" / "agent-mailbox" / "v1" / options.worker
    if not (root / "from-coordinator").is_dir():
        raise SystemExit("no mailbox at " + str(root))
    box = Mailbox(root, options.worker)
    if options.command == "watch":
        box.watch(stream=options.stream)
    elif options.command == "pending":
        ready, unreadable, claims = box.scan()
        for name, kind, path in ready:
            print("MAILBOX %s [%s] %s" % (name, kind, path))
        for path in unreadable:
            print("MAILBOX %s [UNREADABLE] %s" % (path.stem, path))
        print("%d pending, %d claimed by running jobs, %d in the baseline" % (len(ready) + len(unreadable), len(claims), len(box.ignored())))
    elif options.command in ("wait", "ack"):
        if not options.name:
            parser.error(options.command + " needs a message name")
        if options.command == "ack":
            path, wrote = box.ack(options.name, options.note)
            print(("wrote " if wrote else "ACK already exists: ") + str(path))
        else:
            box.claim([options.name], owner="wait")
            try:
                path, _ = box.wait_for(options.name, options.timeout)
            except TimeoutError as error:
                print(error, file=sys.stderr)
                return 3
            print(path)
    else:
        added, total = box.set_baseline(options.note or "historical backlog, not actionable")
        print("%d unacknowledged messages added to the baseline (%d in all): %s" % (added, total, box.baseline_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

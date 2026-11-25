#!/usr/bin/env python3
"""Split a test round into simulator jobs by measured duration and say how many slots are worth asking for.

    python3 -I scripts/plan_simulator_jobs.py harvest build/*.xcresult
        Records each passing test case's duration in build/test-timings.json (kept per worktree, ignored by git).
    python3 -I scripts/plan_simulator_jobs.py plan tests.txt [--free N] [--slots N]
        tests.txt has one -only-testing identifier per line (Target/Class/testName, or Target/Class for a class).
        Prints the jobs, packed longest test first onto the least-loaded job, and the expected wall time for
        every slot count up to the free slots (at most five).

Planning numbers: a test never measured counts as 60 s (UI) or 1 s (unit); a class never measured counts as
5 s (unit) or 300 s (UI). Every job also pays a fixed start-up of 25 s (installing and launching the app and
the runner; measured 10-35 s). The suggested slot count is the fewest slots whose wall time is within 15 % (and
45 s) of using every free slot: a slot that saves less is left for other workers.
"""
import argparse
import json
import os
import subprocess
import sys

STARTUP = 25.0
DB = os.path.join("build", "test-timings.json")


def load():
    try:
        return json.load(open(DB))
    except (OSError, ValueError):
        return {}


def harvest(bundles):
    db = load()
    found = 0
    for bundle in bundles:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                             capture_output=True, text=True)
        if out.returncode != 0:
            print(f"skipped {bundle}: {out.stderr.strip()[:200]}", file=sys.stderr)
            continue

        def walk(node, target, suite):
            kind, name = node.get("nodeType"), node.get("name", "")
            if kind in ("Unit test bundle", "UI test bundle"):
                target = name
            elif kind == "Test Suite":
                suite = name
            elif kind == "Test Case" and node.get("result") == "Passed" and node.get("durationInSeconds") is not None:
                nonlocal found
                key = f"{target}/{suite}/{name.removesuffix('()')}"
                db[key] = round(float(node["durationInSeconds"]), 1)
                found += 1
            for child in node.get("children", []):
                walk(child, target, suite)

        for top in json.loads(out.stdout).get("testNodes", []):
            walk(top, "", "")
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    json.dump(db, open(DB, "w"), indent=1, sort_keys=True, ensure_ascii=False)
    print(f"recorded {found} passing test cases; {len(db)} known in {DB}")


def cost(test, db):
    ui = "UITests" in test.split("/")[0]
    if test in db:
        return db[test]
    if test.count("/") == 1:
        members = [v for k, v in db.items() if k.startswith(test + "/")]
        return sum(members) if members else (300.0 if ui else 5.0)
    return 60.0 if ui else 1.0


def pack(tests, slots, db):
    jobs = [{"seconds": STARTUP, "tests": []} for _ in range(slots)]
    for test in sorted(tests, key=lambda t: -cost(t, db)):
        job = min(jobs, key=lambda j: j["seconds"])
        job["tests"].append(test)
        job["seconds"] += cost(test, db)
    return [j for j in jobs if j["tests"]]


def plan(path, free, slots):
    db = load()
    tests = list(dict.fromkeys(line.strip() for line in open(path) if line.strip() and not line.startswith("#")))
    free = max(1, min(5, free))
    walls = {n: max(j["seconds"] for j in pack(tests, n, db)) for n in range(1, free + 1)}
    # An extra slot must save more than 15 % and more than 45 s; otherwise it is left for other workers.
    chosen = slots or next(n for n in range(1, free + 1) if walls[n] - walls[free] <= max(walls[free] * 0.15, 45))
    print(json.dumps({
        "slots": chosen,
        "expected_wall_seconds_by_slots": {n: round(w) for n, w in walls.items()},
        "serial_seconds": round(sum(cost(t, db) for t in tests) + STARTUP),
        "not_yet_measured": [t for t in tests if t not in db and not any(k.startswith(t + "/") for k in db)],
        "jobs": [{"expected_seconds": round(j["seconds"]), "tests": j["tests"]} for j in pack(tests, chosen, db)],
    }, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    h = sub.add_parser("harvest"); h.add_argument("bundles", nargs="+")
    p = sub.add_parser("plan"); p.add_argument("tests"); p.add_argument("--free", type=int, default=5); p.add_argument("--slots", type=int)
    args = parser.parse_args()
    harvest(args.bundles) if args.command == "harvest" else plan(args.tests, args.free, args.slots)

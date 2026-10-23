#!/usr/bin/env python3
"""Read-only reconciliation of durable worker handoffs and verified main artifacts.

Messages are delivery hints, not the queue. This command never installs, builds,
changes slot ownership, or treats a readiness flag as verification evidence.
"""
import argparse
import json
from pathlib import Path
import subprocess


def read_object(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object: {path}")
    return value


def ancestor(root, older, newer):
    if not older or not newer:
        return False
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", older, newer], cwd=root,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def summary_path(record):
    for key in ("verification_summary", "worker_evidence", "evidence"):
        value = record.get(key)
        if isinstance(value, str) and value.endswith(".json"):
            return Path(value)
    return None


def audit(root, registry, handoffs, is_ancestor):
    phone = registry.get("phone", {})
    candidates = {}
    errors = []
    for source, record in [
        *((key, value) for key, value in phone.items()
          if key.startswith("pending_") and isinstance(value, dict)),
        *handoffs,
    ]:
        merge = record.get("merge_commit") or record.get("main_commit")
        state = str(record.get("state", "")).lower()
        claimed_ready = (record.get("ready_for_main_build") is True
                         or record.get("source_ready") is True
                         or summary_path(record) is not None
                         or ("merged" in state and "verified" in state))
        if merge and claimed_ready:
            item = candidates.setdefault(merge, {"merge_commit": merge, "sources": [], "records": []})
            item["sources"].append(source)
            item["records"].append(record)

    actions, covered = [], []
    for merge, item in sorted(candidates.items()):
        if not is_ancestor(merge, "origin/main"):
            actions.append({"action": "verify_merge", "merge_commit": merge, "sources": item["sources"]})
            continue
        artifacts = [b for b in phone.get("ready_builds", [])
                     if b.get("build_branch") == "main"
                     and b.get("clean_checkout_at_build") is True
                     and b.get("build_succeeded") is True
                     and b.get("codesign_verified") is True
                     and b.get("artifact") and b.get("binary_sha256")
                     and is_ancestor(merge, b.get("main_commit"))]
        if artifacts:
            artifact = max(artifacts, key=lambda b: int(b.get("build", 0)))
            # Hold/Skip/awaiting approval are all recorded offers, not permission
            # to install and not reasons to create repeated offers on every wake.
            covered.append({"merge_commit": merge, "build": artifact["build"],
                            "decision": artifact.get("decision", "not_offered")})
            if artifact.get("decision") is None:
                actions.append({"action": "offer_verified_build", "build": artifact["build"],
                                "merge_commit": merge})
            continue

        summaries = []
        for record in item["records"]:
            path = summary_path(record)
            if path is None:
                continue
            try:
                summaries.append(read_object(path))
            except (OSError, ValueError) as exc:
                errors.append({"path": str(path), "error": str(exc)})
        # Fail closed: a ready flag or stale prose alone cannot greenlight a build.
        verified = bool(summaries)
        for summary in summaries:
            if summary.get("merge_commit") != merge:
                verified = False
            if (summary.get("unresolved_failures") or summary.get("distinct_failed_remaining", 0)
                    or summary.get("failed", 0)):
                verified = False
            if not any(summary.get(k, 0) for k in
                       ("distinct_cases_passed", "distinct_passed_cases", "distinct_passed")):
                verified = False
            screenshot_review = summary.get("screenshots_reviewed")
            if not screenshot_review and isinstance(summary.get("screenshots"), dict):
                screenshot_review = any(
                    key.endswith("_reviewed") and isinstance(count, int) and count > 0
                    for key, count in summary["screenshots"].items()
                )
            if not screenshot_review:
                verified = False
        actions.append({"action": "prepare_main_build" if verified else "verify_worker_evidence",
                        "merge_commit": merge, "sources": item["sources"]})

    for request in registry.get("slot_requests", []):
        slot = registry.get("slots", {}).get(request.get("requested_slot"), {})
        if slot.get("state") == "available" and not slot.get("owner_thread"):
            actions.append({"action": "coordinate_slot_handoff", "slot": request.get("requested_slot"),
                            "owner_thread": request.get("owner_thread")})
    return {"actions": actions, "covered_handoffs": covered, "errors": errors,
            "note": "Read-only audit; reverify source/evidence/artifact before acting. No install authorization inferred."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--registry", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    path = args.registry or root / "build/simulator-coordination.json"
    try:
        registry = read_object(path)
        handoffs, handoff_errors = [], []
        for handoff in sorted((root / "build").glob("*ready-handoff.json")):
            try:
                handoffs.append((str(handoff), read_object(handoff)))
            except (OSError, ValueError) as exc:
                # One corrupt/partially written worker file must not hide other
                # valid deliveries. Still report it and return a nonzero status.
                handoff_errors.append({"path": str(handoff), "error": str(exc)})
        report = audit(root, registry, handoffs, lambda a, b: ancestor(root, a, b))
        report["errors"].extend(handoff_errors)
    except (OSError, ValueError) as exc:
        report = {"actions": [], "errors": [{"error": str(exc)}]}
    print(json.dumps(report, indent=2))
    return 2 if report["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())

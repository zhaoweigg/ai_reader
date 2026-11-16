import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from coordination_audit import audit


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.summary = self.root / "summary.json"
        self.summary.write_text(json.dumps({"merge_commit": "feature", "distinct_cases_passed": 7,
                                            "unresolved_failures": [], "screenshots_reviewed": True}))
        self.handoff = {"merge_commit": "feature", "ready_for_main_build": True,
                        "verification_summary": str(self.summary),
                        "handoff_route_error": "Cannot steer conversation without an active turn id"}
        self.registry = {"phone": {"pending_feature": self.handoff, "ready_builds": []}}

    def run_audit(self, handoffs=None, ancestor=None):
        return audit(self.root, self.registry, handoffs or [], ancestor or (lambda a, b: True))

    def artifact(self, decision="awaiting_user"):
        return {"main_commit": "combined", "build": "44", "build_branch": "main",
                "clean_checkout_at_build": True, "build_succeeded": True,
                "codesign_verified": True, "artifact": "/verified/app", "binary_sha256": "digest",
                "decision": decision}

    def test_failed_message_still_discovers_stranded_merge(self):
        result = self.run_audit([("durable.json", self.handoff)])
        self.assertEqual([a["action"] for a in result["actions"]], ["prepare_main_build"])
        self.assertEqual(len(result["actions"][0]["sources"]), 2)

    def test_combined_artifact_covers_earlier_feature_without_duplicate_offer(self):
        for decision in ("awaiting_user", "Hold", "Skip", "Install now"):
            self.registry["phone"]["ready_builds"] = [self.artifact(decision)]
            self.assertEqual(self.run_audit()["actions"], [])

    def test_feature_branch_or_unsigned_artifact_does_not_satisfy_main_build(self):
        for field, value in (("build_branch", "feature"), ("codesign_verified", False),
                             ("clean_checkout_at_build", False), ("build_succeeded", False)):
            artifact = self.artifact(); artifact[field] = value
            self.registry["phone"]["ready_builds"] = [artifact]
            self.assertEqual(self.run_audit()["actions"][0]["action"], "prepare_main_build")

    def test_unmerged_candidate_is_not_built(self):
        self.assertEqual(self.run_audit(ancestor=lambda a, b: False)["actions"][0]["action"], "verify_merge")

    def test_final_summary_is_found_without_message_or_ready_flag(self):
        self.handoff.pop("ready_for_main_build")
        self.assertEqual(self.run_audit()["actions"][0]["action"], "prepare_main_build")

    def test_structured_screenshot_review_counts_are_supported(self):
        summary = json.loads(self.summary.read_text())
        summary.pop("screenshots_reviewed")
        summary["screenshots"] = {"final_named_reviewed": 100, "contact_sheets": ["review.jpg"]}
        self.summary.write_text(json.dumps(summary))
        self.assertEqual(self.run_audit()["actions"][0]["action"], "prepare_main_build")

    def test_corrupt_worker_file_does_not_hide_other_candidates(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test", "-c",
                        "user.email=test@example.test", "commit", "--allow-empty", "-qm", "base"], check=True)
        subprocess.run(["git", "-C", str(self.root), "branch", "feature"], check=True)
        subprocess.run(["git", "-C", str(self.root), "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
        build = self.root / "build"; build.mkdir()
        (build / "bad-ready-handoff.json").write_text("{")
        (build / "simulator-coordination.json").write_text(json.dumps(self.registry))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("coordination_audit.py")),
                                 "--root", str(self.root)], capture_output=True, text=True)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["actions"][0]["action"], "prepare_main_build")
        self.assertTrue(report["errors"])

    def test_missing_evidence_is_not_a_green_build(self):
        self.summary.unlink()
        result = self.run_audit()
        self.assertEqual(result["actions"][0]["action"], "verify_worker_evidence")
        self.assertTrue(result["errors"])

    def installed_phone(self):
        self.registry["phone"].update({"installed_main_commit": "shipped", "installed_build": "147",
            "installed_binary_sha256": "digest", "state": "installed_launched_version_verified"})

    def expire_summary(self):
        self.summary.unlink()
        build = self.root / "build"
        build.mkdir(exist_ok=True)
        (build / "artifact-retention-latest.json").write_text(json.dumps({"apply": True, "cutoff": 100,
            "expired": [{"path": str(self.summary), "newest": 99}]}))

    def test_expired_shipped_proof_is_reported_without_requeue_or_green_test(self):
        self.installed_phone()
        self.expire_summary()
        report = self.run_audit()
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["actions"], [])
        missing = report["unavailable_historical_evidence"][0]
        self.assertEqual(missing["status"], "expired")
        self.assertIn("No such file", missing["error"])
        self.assertFalse(missing["verification_revalidated"])

    def test_expired_unshipped_proof_still_blocks_delivery(self):
        self.installed_phone()
        self.expire_summary()
        report = self.run_audit(ancestor=lambda a, b: b != "shipped")
        self.assertTrue(report["errors"])
        self.assertEqual(report["actions"][0]["action"], "verify_worker_evidence")

    def test_shipped_missing_proof_stays_explicit_after_cleanup_receipt_replaced(self):
        self.installed_phone()
        self.summary.unlink()
        report = self.run_audit()
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["unavailable_historical_evidence"][0]["status"], "unavailable")

    def test_incomplete_install_state_cannot_hide_missing_active_evidence(self):
        self.installed_phone()
        self.expire_summary()
        self.registry["phone"]["state"] = "installation_pending"
        self.assertTrue(self.run_audit()["errors"])

    def test_stale_ready_flag_cannot_override_failure_or_wrong_commit(self):
        for change in ({"unresolved_failures": ["failure"]}, {"merge_commit": "different"},
                       {"screenshots_reviewed": False}, {"distinct_cases_passed": 0}):
            summary = {"merge_commit": "feature", "distinct_cases_passed": 7,
                       "unresolved_failures": [], "screenshots_reviewed": True}
            summary.update(change); self.summary.write_text(json.dumps(summary))
            self.assertEqual(self.run_audit()["actions"][0]["action"], "verify_worker_evidence")

    def test_only_unowned_available_slot_is_actionable(self):
        self.registry["phone"]["ready_builds"] = [self.artifact()]
        self.registry["slot_requests"] = [{"requested_slot": "A", "owner_thread": "worker"}]
        for state, owner, count in (("testing", "other", 0), ("available", "other", 0),
                                    ("available", None, 1)):
            self.registry["slots"] = {"A": {"state": state, "owner_thread": owner}}
            self.assertEqual(len(self.run_audit()["actions"]), count)

    def test_waiting_for_a_build_is_not_an_executable_handoff(self):
        self.registry["phone"]["ready_builds"] = [self.artifact()]
        self.registry["slots"] = {"A": {"state": "available", "owner_thread": None}}
        self.registry["slot_requests"] = [{"requested_slot": "A", "owner_thread": "worker",
                                            "state": "waiting_for_ready_head"}]
        self.assertEqual(self.run_audit()["actions"], [])


if __name__ == "__main__":
    unittest.main()

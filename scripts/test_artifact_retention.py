import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from artifact_retention import RETENTION_SECONDS, Snapshot, snapshot, sweep


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.build = Path(self.directory.name) / "build"
        self.build.mkdir()
        self.now = 2_000_000_000
        self.cutoff = self.now - RETENTION_SECONDS

    def file(self, name, age=1):
        path = self.build / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("test artifact")
        os.utime(path, (self.cutoff - age, self.cutoff - age))
        return path

    def test_dry_run_and_exact_72_hour_boundary(self):
        expired = self.file("old.json")
        boundary = self.file("boundary.json", 0)
        recent = self.file("recent.log", -1)
        report = sweep([self.build], now=self.now)
        self.assertEqual([e["path"] for e in report["expired"]], [str(expired)])
        self.assertTrue(all(p.exists() for p in [expired, boundary, recent]))
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(expired.exists())
        self.assertTrue(boundary.exists())

    def test_whole_bundle_with_recent_file_stays_intact(self):
        old = self.file("Current.app/library")
        self.file("Current.app/executable", -1)
        sweep([self.build], now=self.now, apply=True)
        self.assertTrue(old.exists())

    def test_relocated_evidence_uses_contents_not_directory_date(self):
        old = self.file("retained-worktree-evidence-today/worker/build/Old.xcresult/output")
        os.utime(old.parent, (self.now, self.now))
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(old.parent.exists())

    def test_protects_parent_or_child_consumed_by_active_job(self):
        old = self.file("DerivedData/Build/Products/Current.app/executable")
        sweep([self.build], [old], now=self.now, apply=True)
        self.assertTrue(old.exists())
        sweep([self.build], [self.build], now=self.now, apply=True)
        self.assertTrue(old.exists())

    def test_keeps_source_models_credentials_and_control_state(self):
        paths = [self.file(name) for name in ["Source/LeafReader/file.swift", "VoiceModel/model.onnx",
                 "agent-mailbox/v1/worker/from-worker/unread.json", "coordinator_helper.py", "simulator-coordination.json", "key.p12"]]
        sweep([self.build], now=self.now, apply=True)
        self.assertTrue(all(p.exists() for p in paths))

    def test_completed_mailbox_messages_expire_but_unread_messages_survive(self):
        completed = self.file("agent-mailbox/v1/worker/from-worker/done.json")
        ack = self.file("agent-mailbox/v1/worker/acks/by-coordinator/done.json")
        unread = self.file("agent-mailbox/v1/worker/from-worker/unread.json")
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(completed.exists())
        self.assertFalse(ack.exists())
        self.assertTrue(unread.exists())

    def test_later_mailbox_ack_expires_on_subsequent_sweep(self):
        message = self.file("agent-mailbox/v1/worker/from-worker/done.json")
        ack = self.file("agent-mailbox/v1/worker/acks/by-coordinator/done.json", -1)
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(message.exists())
        self.assertTrue(ack.exists())
        sweep([self.build], now=self.now + 2, apply=True)
        self.assertFalse(ack.exists())

    def test_archived_build_proofs_also_expire(self):
        output = self.file("baseline-archive/build/Test.xcresult/output")
        proof = self.file("baseline-archive/manifest.json")
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(output.exists())
        self.assertFalse(proof.exists())

    def test_source_recovery_survives_but_its_old_test_output_expires(self):
        source = self.file("worktree-archives/qa-date/worker/checkout/LeafReader/source.swift")
        evidence = self.file("worktree-archives/qa-date/worker/checkout/build/Test.xcresult/output")
        sweep([self.build], now=self.now, apply=True)
        self.assertTrue(source.exists())
        self.assertFalse(evidence.exists())

    def test_symlink_target_is_never_traversed(self):
        outside = Path(self.directory.name) / "outside"
        outside.mkdir()
        target = outside / "source"
        target.write_text("keep")
        link = self.build / "old-link"
        link.symlink_to(outside, target_is_directory=True)
        os.utime(link, (self.cutoff - 1, self.cutoff - 1), follow_symlinks=False)
        sweep([self.build], now=self.now, apply=True)
        self.assertFalse(link.is_symlink())
        self.assertEqual(target.read_text(), "keep")

    def test_archived_checkout_symlink_is_never_traversed(self):
        external = Path(self.directory.name) / "source-checkout"
        output = external / "build" / "keep.log"
        output.parent.mkdir(parents=True)
        output.write_text("keep")
        os.utime(output, (self.cutoff - 1, self.cutoff - 1))
        archive = self.build / "worktree-archives/qa-date/worker"
        archive.mkdir(parents=True)
        (archive / "checkout").symlink_to(external, target_is_directory=True)
        sweep([self.build], now=self.now, apply=True)
        self.assertTrue(output.exists())

    def test_changed_artifact_is_not_deleted(self):
        path = self.file("changed.log")
        before = snapshot(path)
        with patch("artifact_retention.snapshot", side_effect=[before, Snapshot(self.now, 1, 99, 512)]):
            report = sweep([self.build], now=self.now, apply=True)
        self.assertEqual(report["changed"], [str(path)])
        self.assertTrue(path.exists())

    def test_expired_frozen_app_can_be_removed(self):
        path = self.file("Frozen.app/_CodeSignature/CodeResources")
        path.parent.chmod(0o555)
        path.parent.parent.chmod(0o555)
        report = sweep([self.build], now=self.now, apply=True)
        self.assertEqual(report["errors"], [])
        self.assertFalse(path.parent.parent.exists())


if __name__ == "__main__":
    unittest.main()

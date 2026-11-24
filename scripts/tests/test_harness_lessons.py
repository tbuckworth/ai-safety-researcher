"""Local cross-run lesson capture, weekly review, and promotion into the harness."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import harness_lessons as lessons


class HarnessLessonTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.runs = [self.root / name for name in ("first", "second")]
        for run in self.runs:
            (run / "audit").mkdir(parents=True)
            (run / "state.md").write_text("---\nstatus: complete\n---\n")
            (run / "audit" / "results-audit.md").write_text("Finding 1. Duplicate family.\n")
        self.now = datetime(2026, 12, 31, tzinfo=timezone.utc)
        self.row = {"key": "split-overlap", "failure": "Same family in train and test",
                    "evidence": "audit/results-audit.md", "locator": "Finding 1",
                    "why_missed": "Validation compared row IDs", "check": "Compare families."}
        self.accept = {"status": "accepted", "reason": "Verified across runs",
                       "check": "Check split independence by family.", "change": "Validate grouped splits.",
                       "regression": "Duplicated family with unique row IDs fails."}

    def decide(self, run, packet, decisions):
        return lessons.review(run, {"packet": packet.name, "decisions": decisions}, self.now)

    def test_records_are_private_idempotent_and_checks_available_before_review(self):
        run = self.runs[0]
        first = lessons.record(run, self.row)
        self.assertEqual(first, lessons.record(run, self.row))
        path = Path(first["recorded"])
        self.assertEqual(lessons.read_json(path)["sha256"],
                         lessons.digest((run / self.row["evidence"]).read_bytes()))
        # Use local git's own ignore rules, as publishing does.
        subprocess.run(["git", "init", "-q", str(run)], check=True)
        subprocess.run(["git", "-C", str(run), "check-ignore", "-q", str(path)], check=True)
        self.assertEqual(lessons.checks(self.runs[1])["checks"],
                         [{"key": "split-overlap", "status": "candidate", "check": "Compare families."}])
        for source in ("../other", "missing", "/etc/hosts"):
            with self.subTest(source=source), self.assertRaises((ValueError, FileNotFoundError)):
                lessons.record(run, {**self.row, "evidence": source})
        (run / "external").symlink_to(self.runs[1] / self.row["evidence"])
        with self.assertRaises(ValueError):
            lessons.record(run, {**self.row, "evidence": "external"})

    def test_cli_reads_only_its_archive_and_weekly_stdout_omits_case_details(self):
        script = Path(lessons.__file__)
        first, second = self.runs
        lessons.record(first, self.row)
        other = self.root / "separate-archive" / "run"
        other.mkdir(parents=True)
        (other / "state.md").write_text("---\nstatus: complete\n---\n")
        output = subprocess.check_output([sys.executable, script, "checks", other], text=True)
        self.assertEqual(json.loads(output), {"checks": [], "pending_pr": []})
        message = json.loads(subprocess.check_output([sys.executable, script, "weekly", second], text=True))
        self.assertEqual(set(message), {"review"})
        self.assertEqual(Path(message["review"]).parent, self.root / ".harness-reviews")
        self.assertNotIn(self.row["failure"], json.dumps(message))
        bad = subprocess.run([sys.executable, script, "weekly", self.root], capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("state.md", bad.stderr)

    def test_tampered_record_does_not_enter_next_design(self):
        first, second = self.runs
        path = Path(lessons.record(first, self.row)["recorded"])
        row = lessons.read_json(path)
        row["check"] = "A different check under the previously reviewed identity."
        path.write_text(json.dumps(row))
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            lessons.checks(second)

    def test_pending_and_duplicate_evidence_then_reopens_only_on_new_observation(self):
        first, second = self.runs
        for run in self.runs:
            lessons.record(run, self.row)
        packet = Path(lessons.weekly(first, self.now)["review"])
        candidates = lessons.read_json(packet)["candidates"]
        self.assertEqual(list(candidates), ["split-overlap"])
        self.assertEqual(len(candidates["split-overlap"]["observations"]), 2)
        self.assertEqual(lessons.weekly(first, self.now)["review"], str(packet))
        with self.assertRaises(ValueError):
            self.decide(first, packet, {})
        with self.assertRaises(ValueError):
            self.decide(second, packet, {"split-overlap": self.accept})
        self.decide(first, packet, {"split-overlap": self.accept})
        week_two = self.now + timedelta(weeks=1)
        self.assertIsNone(lessons.weekly(second, week_two)["review"])
        self.assertEqual(lessons.checks(second)["pending_pr"][0]["change"], self.accept["change"])
        lessons.record(second, {**self.row, "why_missed": "New evidence from a rerun"})
        reopened = Path(lessons.weekly(second, week_two + timedelta(weeks=1))["review"])
        data = lessons.read_json(reopened)["candidates"]["split-overlap"]
        self.assertEqual(data["previous"]["status"], "accepted")
        self.assertEqual(len(data["observations"]), 3)

    def test_accepted_change_survives_moving_original_run_out_of_archive(self):
        first, second = self.runs
        lessons.record(first, self.row)
        packet = Path(lessons.weekly(second, self.now)["review"])
        self.decide(second, packet, {"split-overlap": self.accept})
        (self.root / "archive").mkdir()
        first.rename(self.root / "archive" / first.name)
        queued = lessons.checks(second)
        self.assertEqual(queued["pending_pr"][0]["key"], "split-overlap")
        lessons.record(second, self.row)
        reopened = Path(lessons.weekly(second, self.now + timedelta(weeks=1))["review"])
        self.assertEqual(len(lessons.read_json(reopened)["candidates"]["split-overlap"]["observations"]), 2)

    def test_review_failure_hands_off_and_expired_claim_cannot_commit(self):
        first, second = self.runs
        lessons.record(first, self.row)
        with ThreadPoolExecutor(max_workers=2) as pool:
            claims = list(pool.map(lambda run: lessons.weekly(run, self.now)["review"], self.runs))
        self.assertEqual(sum(bool(claim) for claim in claims), 1)
        winner = self.runs[0] if claims[0] else self.runs[1]
        other = second if winner == first else first
        self.assertFalse(lessons.release(other)["released"])
        self.assertTrue(lessons.release(winner)["released"])
        lost = Path(lessons.weekly(other, self.now)["review"])
        recovered = Path(lessons.weekly(winner, self.now + timedelta(hours=2))["review"])
        with self.assertRaises(ValueError):
            self.decide(other, lost, {"split-overlap": self.accept})
        self.decide(winner, recovered, {"split-overlap": {"status": "deferred", "reason": "Needs replication"}})
        self.assertIsNone(lessons.weekly(other, self.now + timedelta(days=1))["review"])
        retry = Path(lessons.weekly(other, self.now + timedelta(weeks=1))["review"])
        self.assertEqual(lessons.read_json(retry)["candidates"]["split-overlap"]["previous"]["status"], "deferred")

    def test_decisions_are_atomic_and_rejections_suppress_candidates(self):
        first = self.runs[0]
        for key in ("split-overlap", "invalid-denominator"):
            lessons.record(first, {**self.row, "key": key})
        packet = Path(lessons.weekly(first, self.now)["review"])
        decisions = {"split-overlap": {"status": "rejected", "reason": "Already covered by a fixture"},
                     "invalid-denominator": {**self.accept, "regression": ""}}
        with self.assertRaises(ValueError):
            self.decide(first, packet, decisions)
        self.assertTrue(all(row["status"] == "candidate" for row in lessons.checks(first)["checks"]))
        decisions["invalid-denominator"] = self.accept
        self.decide(first, packet, decisions)
        self.assertEqual([row["key"] for row in lessons.checks(first)["checks"]], ["invalid-denominator"])

    def test_integration_requires_merged_pr_and_preserves_prior_review(self):
        run = self.runs[0]
        lessons.record(run, self.row)
        packet = Path(lessons.weekly(run, self.now)["review"])
        self.decide(run, packet, {"split-overlap": self.accept})
        data = {"key": "split-overlap", "pr": "https://github.com/example/plugin/pull/7",
                "validation": "Group-overlap regression failed on parent and passed on fix."}
        source = self.root / "source"
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "remote", "add", "origin",
                        "git@github.com:example/plugin.git"], check=True)
        # The GitHub lookup is the external boundary. Repository discovery and
        # all review and ledger logic run locally.
        with patch.object(subprocess, "check_output", side_effect=[
            json.dumps({"state": "OPEN", "mergeCommit": None}),
            json.dumps({"state": "MERGED", "mergeCommit": {"oid": "a" * 40}}),
        ]) as gh:
            with self.assertRaises(ValueError):
                lessons.integrate(run, data, self.now, source)
            self.assertTrue(lessons.checks(run)["pending_pr"])
            with self.assertRaisesRegex(ValueError, "different repository"):
                lessons.integrate(run, {**data, "pr": "https://github.com/other/plugin/pull/7"},
                                  self.now, source)
            lessons.integrate(run, data, self.now, source)
            self.assertEqual(gh.call_count, 2)
            self.assertEqual(gh.call_args.args[0][:6], ["gh", "pr", "view", "7", "--repo", "example/plugin"])
        self.assertEqual(lessons.checks(run)["pending_pr"], [])
        history = lessons.read_json(self.root / ".harness-reviews" / "ledger.json")["history"]["split-overlap"]
        self.assertEqual([decision["status"] for decision in history], ["accepted", "integrated"])
        self.assertEqual(history[-1]["validation"], data["validation"])


if __name__ == "__main__":
    unittest.main()

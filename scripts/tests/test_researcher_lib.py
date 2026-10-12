"""Unit tests for scripts/researcher_lib.py (stdlib unittest; no network)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import researcher_lib as lib  # noqa: E402

# The body shared by tasks#1919 and #1920: one follow-up request filed twice.
DUP_BODY = """The experimental setup needs a more realistic model organism. Key issues: ...

The core Salad vs Soup comparison methodology was sound.

---
Parent: #1874 | Repo: https://github.com/tbuckworth/research-salad-vs-soup-does-token-interleaving | Run: 2026-04-03-salad-vs-soup"""


def issue(number, labels=(), body="", title=None):
    return {"number": number, "title": title or f"Issue {number}", "body": body,
            "labels": [{"name": name} for name in labels]}


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_run(root: Path, name: str, **fields) -> Path:
    run = root / name
    lines = ["---"] + [f"{k}: {v}" for k, v in fields.items()] + ["---", "", "body"]
    write(run / "state.md", "\n".join(lines) + "\n")
    return run


def results(verdict: str, component: str = "Component A") -> str:
    return f"# Experiment Results\n\n## Component Tested\n{component}\n\n## Verdict: {verdict}\n\n## Setup\n- x\n"


PREFLIGHT_OK = """| Check | Status | Evidence |
|-------|--------|----------|
| method-fidelity | PASS | test |
| training-sanity | N/A | none |
| metric-separation | PASS | AUROC 0.9 |
"""
PREFLIGHT_BAD = PREFLIGHT_OK.replace("| training-sanity | N/A | none |", "| training-sanity | FAIL | QuestionQuestion... |")


class FollowupKeyTest(unittest.TestCase):
    def test_identical_requests_share_a_key(self):
        self.assertEqual(lib.followup_key(DUP_BODY), lib.followup_key(DUP_BODY + "\n\n"))
        self.assertEqual(lib.followup_key(DUP_BODY), lib.followup_key(DUP_BODY.replace("\n", "\r\n")))

    def test_different_requests_differ(self):
        self.assertNotEqual(lib.followup_key(DUP_BODY), lib.followup_key(DUP_BODY.replace("realistic", "bigger")))

    def test_recorded_marker_wins(self):
        body = DUP_BODY + "\n<!-- followup-key: 0123456789abcdef -->"  # gitleaks:allow (placeholder key, not a secret)
        self.assertEqual(lib.followup_key(body), "0123456789abcdef")
        # ...and the computed key ignores the marker, so the creator and the
        # picker agree.
        self.assertEqual(lib.compute_followup_key(body), lib.compute_followup_key(DUP_BODY))


class PickIssueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def pick(self, issues, **kwargs):
        return lib.pick_issue(issues, lib.local_runs(self.out), **kwargs)

    def test_skips_claimed_and_processed_by_either_backend(self):
        issues = [issue(5, ["status:codex-researching"]), issue(4, ["status:claude-processed"]),
                  issue(3, ["status:codex-processed"]), issue(2)]
        self.assertEqual(self.pick(issues)["number"], 2)

    def test_skips_issue_with_a_local_run(self):
        make_run(self.out, "2026-03-24-x", issue_number=1898, status="complete")
        issues = [issue(1898), issue(1897)]
        self.assertEqual(self.pick(issues)["number"], 1897)
        self.assertEqual(self.pick(issues, allow_rerun=True)["number"], 1898)

    def test_nothing_to_pick(self):
        self.assertIsNone(self.pick([issue(1, ["status:claude-processed"])]))

    def test_duplicate_followup_of_processed_issue_is_skipped(self):
        issues = [issue(1920, ["type:follow-up", "status:claude-processed"], DUP_BODY),
                  issue(1919, ["type:follow-up"], DUP_BODY)]
        self.assertIsNone(self.pick(issues))

    def test_duplicate_followups_run_once_lowest_number_first(self):
        issues = [issue(1920, ["type:follow-up"], DUP_BODY), issue(1919, ["type:follow-up"], DUP_BODY)]
        picked = self.pick(issues)
        self.assertEqual(picked["number"], 1919)
        self.assertEqual(picked["followup_key"], lib.followup_key(DUP_BODY))

    def test_followup_already_run_locally_is_skipped(self):
        make_run(self.out, "2026-04-04-followup", issue_number=1920, status="failed",
                 followup_key=lib.followup_key(DUP_BODY))
        self.assertIsNone(self.pick([issue(1919, ["type:follow-up"], DUP_BODY)]))

    def test_explicit_allows_rerun_of_processed_issue(self):
        make_run(self.out, "old", issue_number=7, status="complete")
        picked = self.pick([issue(7, ["status:claude-processed"])], explicit=True)
        self.assertEqual(picked["number"], 7)

    def test_explicit_refuses_researching_or_in_progress(self):
        self.assertIsNone(self.pick([issue(7, ["status:codex-researching"])], explicit=True))
        make_run(self.out, "live", issue_number=8, status="experiments_planned")
        self.assertIsNone(self.pick([issue(8)], explicit=True))


class VerdictTest(unittest.TestCase):
    def test_real_world_verdict_lines(self):
        cases = {
            "## Verdict: PASS": "PASS",
            "## Verdict: PASS (with important caveats)": "PASS",
            "## Verdict: FAIL (Kill Criterion #2 Triggered)": "FAIL",
            "**Verdict: PASS — the judge-validity failure is resolved.**": "PASS",
            "## Verdict: PARTIAL PASS": "MIXED",
            "## Verdict: MIXED (Component 1: PASS, Component 4: FAIL)": "MIXED",
            "## Verdict\n\nFAIL\n": "FAIL",
            "## Verdict: INCONCLUSIVE": "INCONCLUSIVE",
            "## Verdict: <PASS | FAIL | INCONCLUSIVE>": "UNKNOWN",
            "### Verdict rationale\nWhy.\n\n## Verdict: FAIL": "FAIL",
            "## Verdict: FAIL-on-affordability (needs an 80GB GPU)": "INCONCLUSIVE",
            "## Verdict: FAIL (on affordability)": "INCONCLUSIVE",
            "## Verdict: PASS (affordable under the local profile)": "PASS",
            "no verdict here": "UNKNOWN",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(lib.parse_verdict(text), expected)


class OutcomeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = Path(self.tmp.name) / "run"
        self.run.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def add_exp(self, name, verdict, preflight=PREFLIGHT_OK):
        write(self.run / "experiments" / name / "results.md", results(verdict))
        if preflight is not None:
            write(self.run / "experiments" / name / "preflight.md", preflight)

    def outcome(self, **kwargs):
        args = dict(status="complete", timed_out=False, publish_state="pushed")
        args.update(kwargs)
        return lib.compute_outcome(self.run, **args)

    def test_complete_requires_results_and_push(self):
        self.add_exp("exp-001", "PASS")
        self.assertEqual(self.outcome()["outcome"], "complete")
        self.assertEqual(self.outcome(publish_state="skipped")["outcome"], "complete-local")
        failed = self.outcome(publish_state="failed", publish_error="disk nearly full")
        self.assertEqual(failed["outcome"], "unpublished")
        self.assertTrue(any("disk nearly full" in r for r in failed["reasons"]))

    def test_negative_result_is_still_a_result(self):
        self.add_exp("exp-001", "FAIL")
        self.assertEqual(self.outcome()["outcome"], "complete")

    def test_timeout_after_report_stays_complete_but_says_so(self):
        # tasks#1874: the timeout used to overwrite a finished run to "failed".
        self.add_exp("exp-001", "PASS")
        facts = self.outcome(timed_out=True)
        self.assertEqual(facts["outcome"], "complete")
        self.assertTrue(any("audit was skipped" in r for r in facts["reasons"]))

    def test_unfinished_runs(self):
        self.add_exp("exp-001", "PASS")
        self.assertEqual(self.outcome(status="timed_out", timed_out=True)["outcome"], "partial")
        self.assertEqual(self.outcome(status="failed")["outcome"], "partial")
        self.assertEqual(self.outcome(status="audit_complete", paused=True, publish_state="skipped")["outcome"], "paused")

    def test_no_results(self):
        self.assertEqual(self.outcome()["outcome"], "no-results")
        self.assertEqual(self.outcome(status="failed")["outcome"], "failed")
        self.add_exp("exp-001", "INCONCLUSIVE")
        self.assertEqual(self.outcome()["outcome"], "no-results")

    def test_failed_preflight_makes_a_claimed_verdict_inconclusive(self):
        # tasks#1863: gibberish fine-tunes reported as a negative finding.
        self.add_exp("exp-001", "FAIL", PREFLIGHT_BAD)
        facts = self.outcome()
        self.assertEqual(facts["outcome"], "no-results")
        exp = facts["experiments"][0]
        self.assertEqual((exp["stated_verdict"], exp["verdict"]), ("FAIL", "INCONCLUSIVE"))
        self.assertIn("training-sanity", exp["note"])

    def test_missing_preflight_is_reported(self):
        self.add_exp("exp-001", "PASS", preflight=None)
        facts = self.outcome()
        self.assertEqual(facts["outcome"], "complete")
        self.assertTrue(any("no pre-flight record for exp-001" in r for r in facts["reasons"]))

    def test_unreadable_preflight_is_not_a_clean_preflight(self):
        self.add_exp("exp-001", "PASS", preflight="We checked everything carefully.\n")
        facts = self.outcome()
        self.assertEqual(facts["experiments"][0]["preflight"], "unreadable")
        self.assertTrue(any("no readable check table for exp-001" in r for r in facts["reasons"]))

    def test_wrapper_notes_are_reported(self):
        self.add_exp("exp-001", "PASS")
        facts = self.outcome(notes=["experiments/exp-001/big.dat not published"])
        self.assertIn("experiments/exp-001/big.dat not published", facts["reasons"])

    def test_prior_experiments_are_ignored(self):
        write(self.run / "prior" / "experiments" / "exp-001" / "results.md", results("PASS"))
        self.assertEqual(self.outcome()["outcome"], "no-results")

    def test_theory_only_rethink_counts_as_a_result(self):
        write(self.run / "rethink-rationale.md", "why it cannot work")
        facts = self.outcome()
        self.assertEqual(facts["outcome"], "complete")
        self.assertTrue(any("theory-only" in r for r in facts["reasons"]))


class IssueCommentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = Path(self.tmp.name) / "2026-10-12-topic"
        write(self.run / "experiments" / "exp-001" / "results.md", results("PASS", "Routing localises toxicity"))
        write(self.run / "experiments" / "exp-001" / "preflight.md", PREFLIGHT_OK)
        write(self.run / "experiments" / "exp-002" / "results.md", results("FAIL", "Persists through DPO"))
        write(self.run / "experiments" / "exp-002" / "preflight.md", PREFLIGHT_BAD)
        write(self.run / "paper" / "paper.pdf", "%PDF")
        write(self.run / "next-steps.md", "# Proposed Next Steps: x\n\n**Run ID**: r\n**Outcome**: Routing localises, persistence untested.\n\n"
                                          "## Ranked Next Steps\n\n### 1. Validate the metric at t=0\n- Do: x\n\n### 2. Capability-pressure RL\n- Do: y\n")
        write(self.run / "audit" / "results-audit.md", "## Overall disposition: HONEST-NEGATIVE\n## audit_exit_reason: true-null\n")

    def tearDown(self):
        self.tmp.cleanup()

    def comment(self, publish_state, repo_web):
        facts = lib.compute_outcome(self.run, status="complete", timed_out=False,
                                    publish_state=publish_state, publish_error="git push of main failed")
        return lib.issue_comment(facts, run_dir=self.run, run_id="2026-10-12-topic", repo_web=repo_web,
                                 branch="main", agent_label="Claude fable", host="desktop",
                                 is_followup=False, visibility="private")

    def test_published_comment_carries_findings_and_links(self):
        text = self.comment("pushed", "https://github.com/o/research-x")
        self.assertIn("outcome: complete", text.splitlines()[0])
        self.assertIn("https://github.com/o/research-x/tree/main (private)", text)
        self.assertIn("https://github.com/o/research-x/blob/main/paper/paper.pdf", text)
        self.assertIn("https://github.com/o/research-x/blob/main/next-steps.md", text)
        self.assertIn("Routing localises, persistence untested.", text)
        self.assertIn("| exp-001 | Routing localises toxicity | PASS |", text)
        self.assertIn("INCONCLUSIVE (stated FAIL, but pre-flight failed: training-sanity)", text)
        self.assertIn("Results audit: HONEST-NEGATIVE (true-null)", text)
        self.assertIn("1. Validate the metric at t=0", text)

    def test_unpublished_comment_has_no_dead_link(self):
        text = self.comment("failed", "")
        self.assertIn("finished but NOT PUBLISHED", text)
        self.assertIn("not on GitHub; local only at `desktop:", text)
        self.assertIn("git push of main failed", text)
        self.assertNotIn("github.com", text)


class CliTest(unittest.TestCase):
    def test_pick_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = subprocess.run([sys.executable, str(SCRIPTS / "researcher_lib.py"), "pick", "--output-dir", tmp],
                                 input=json.dumps([issue(3, ["status:claude-processed"]), issue(2)]),
                                 capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(out.stdout)["number"], 2)

    def test_find_followup_cli(self):
        issues = [{"number": 1920, "url": "u1920", "body": DUP_BODY}, {"number": 1919, "url": "u1919", "body": DUP_BODY}]
        out = subprocess.run([sys.executable, str(SCRIPTS / "researcher_lib.py"), "find-followup",
                              "--key", lib.followup_key(DUP_BODY)],
                             input=json.dumps(issues), capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "1919 u1919")


if __name__ == "__main__":
    unittest.main()

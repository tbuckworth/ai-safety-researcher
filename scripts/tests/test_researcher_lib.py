"""Unit tests for scripts/researcher_lib.py (stdlib unittest; no network)."""

import contextlib
import io
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


def run_lib(*args, stdin=""):
    return subprocess.run([sys.executable, str(SCRIPTS / "researcher_lib.py"), *args],
                          input=stdin, capture_output=True, text=True)


class FrontmatterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state.md"

    def tearDown(self):
        self.tmp.cleanup()

    def test_values_are_yaml_scalars(self):
        # A model may quote any value or add a comment; neither may leak into
        # run ids, branch names or status checks.
        write(self.state, '---\nrun_id: "2026-01-15-quoted"\nstatus: complete  # report compiled\n'
                          "mode: 'autonomous'\ntopic: \"say \\\"hi\\\" to C:\\\\tmp\"\ncurrent_step: \"3\"\n"
                          "status: failed\n---\n\nstatus: body line\n")
        fields = lib.read_frontmatter(self.state)
        self.assertEqual(fields["run_id"], "2026-01-15-quoted")
        self.assertEqual(fields["status"], "complete")
        self.assertEqual(fields["mode"], "autonomous")
        self.assertEqual(fields["topic"], 'say "hi" to C:\\tmp')
        self.assertEqual(fields["current_step"], "3")

    def test_state_field_cli(self):
        write(self.state, '---\nrun_id: "r1"\nissue_number: 7\n---\nowner: body\n')
        self.assertEqual(run_lib("state-field", str(self.state), "run_id").stdout, "r1\n")
        self.assertEqual(run_lib("state-field", str(self.state), "owner").stdout, "\n")
        missing = run_lib("state-field", str(self.state.parent / "nope.md"), "run_id")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("nope.md", missing.stderr)

    def test_terminal_statuses_cli(self):
        self.assertEqual(run_lib("terminal-statuses").stdout.split(), list(lib.TERMINAL_STATUSES))

    def test_unreadable_file_raises(self):
        # A state.md that cannot be read is an error, not a run with no fields.
        self.state.mkdir()
        with self.assertRaises(OSError):
            lib.read_frontmatter(self.state)

    def test_run_without_frontmatter_is_reported(self):
        # Such a run is not counted when picking checks for duplicates; say so.
        root = Path(self.tmp.name)
        write(root / "2026-01-01-bare" / "state.md", "status: complete\n")
        make_run(root, "2026-01-02-ok", status="complete", issue_number="7")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            runs = lib.local_runs(root)
        self.assertEqual([run["_dir"] for run in runs],
                         [str(root / "2026-01-01-bare"), str(root / "2026-01-02-ok")])
        self.assertIn(f"WARN: {root / '2026-01-01-bare' / 'state.md'} has no frontmatter", stderr.getvalue())
        self.assertNotIn("2026-01-02-ok", stderr.getvalue())


class BackendLabelTest(unittest.TestCase):
    def test_labels_come_from_the_backend_list(self):
        for backend in lib.BACKENDS:
            self.assertIn(lib.status_label(backend, "researching"), lib.RESEARCHING_LABELS)
            self.assertIn(lib.status_label(backend, "processed"), lib.BUSY_LABELS)
        self.assertEqual(run_lib("status-label", "codex", "researching").stdout, "status:codex-researching\n")
        self.assertEqual(run_lib("backends").stdout.split(), list(lib.BACKENDS))
        self.assertNotEqual(run_lib("status-label", "gemini", "researching").returncode, 0)

    def test_research_ideas_label_cli(self):
        self.assertEqual(run_lib("research-ideas-label").stdout, f"{lib.RESEARCH_IDEAS_LABEL}\n")

    def test_claimed(self):
        free = {"state": "OPEN", "labels": [{"name": "list:research-ideas"}]}
        processed = {"state": "OPEN", "labels": [{"name": "status:claude-processed"}]}
        researching = {"state": "OPEN", "labels": [{"name": "status:codex-researching"}]}
        closed = {"state": "CLOSED", "labels": []}
        self.assertEqual(lib.claimed_reason(free, explicit=False), "")
        self.assertIn("status:claude-processed", lib.claimed_reason(processed, explicit=False))
        # An explicit request may re-run a finished issue, never one in progress.
        self.assertEqual(lib.claimed_reason(processed, explicit=True), "")
        self.assertIn("status:codex-researching", lib.claimed_reason(researching, explicit=True))
        self.assertIn("closed", lib.claimed_reason(closed, explicit=True))
        self.assertEqual(run_lib("claimed", stdin=json.dumps(free)).stdout, "")
        self.assertIn("status:claude-processed", run_lib("claimed", stdin=json.dumps(processed)).stdout)
        self.assertEqual(run_lib("claimed", "--explicit", stdin=json.dumps(processed)).stdout, "")


class FollowupIssueTest(unittest.TestCase):
    FEEDBACK = "Use a bigger model organism.\n\n---\n\nThe old one was too small.\n"

    def build(self, feedback=FEEDBACK, **meta):
        args = dict(parent="1874", repo_url="https://github.com/o/research-x", run_id="2026-04-03-x")
        args.update(meta)
        return lib.followup_issue(feedback, **args)

    def test_round_trip_keeps_feedback_with_a_rule(self):
        built = self.build()
        self.assertEqual(built["title"], "[Follow-up] Use a bigger model organism.")
        meta = lib.followup_meta({"title": built["title"], "body": built["body"],
                                  "labels": [{"name": lib.FOLLOWUP_LABEL}]})
        self.assertEqual(meta, {"is_followup": True, "title": "Use a bigger model organism.",
                                "parent_issue": "1874", "prior_repo": "https://github.com/o/research-x",
                                "prior_run_id": "2026-04-03-x", "feedback": self.FEEDBACK.strip()})

    def test_key_is_recorded_and_matches_the_body(self):
        built = self.build()
        self.assertIn(f"<!-- followup-key: {built['key']} -->", built["body"])
        self.assertEqual(lib.followup_key(built["body"]), built["key"])
        self.assertEqual(lib.compute_followup_key(built["body"]), built["key"])

    def test_body_matches_issues_already_filed(self):
        # Issues filed before the body was built here must keep their key, or a
        # second filing of the same request is not recognised as a duplicate.
        built = self.build("The experimental setup needs a more realistic model organism. Key issues: ...\n\n"
                           "The core Salad vs Soup comparison methodology was sound.\n",
                           repo_url="https://github.com/tbuckworth/research-salad-vs-soup-does-token-interleaving",
                           run_id="2026-04-03-salad-vs-soup")
        self.assertEqual(built["key"], lib.followup_key(DUP_BODY))

    def test_no_metadata_no_footer(self):
        built = self.build("Just feedback.", parent="", repo_url="", run_id="")
        self.assertNotIn("Parent:", built["body"])
        meta = lib.followup_meta({"title": built["title"], "body": built["body"],
                                  "labels": [{"name": lib.FOLLOWUP_LABEL}]})
        self.assertEqual((meta["prior_repo"], meta["feedback"]), ("", "Just feedback."))

    def test_label_comes_from_the_lib(self):
        # create-followup-issue.sh files follow-ups, and lists them for duplicates, under this label.
        self.assertEqual(self.build()["label"], lib.FOLLOWUP_LABEL)

    def test_title_is_cut_at_70_characters(self):
        self.assertEqual(self.build("x" * 100)["title"], "[Follow-up] " + "x" * 70)

    def test_plain_issue_is_not_a_followup(self):
        meta = lib.followup_meta({"title": "Idea", "body": DUP_BODY, "labels": []})
        self.assertFalse(meta["is_followup"])

    def test_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            feedback = Path(tmp) / "feedback.txt"
            write(feedback, self.FEEDBACK)
            out = run_lib("followup-issue", "--feedback-file", str(feedback), "--parent", "1874",
                          "--repo-url", "https://github.com/o/research-x", "--run-id", "2026-04-03-x")
            built = json.loads(out.stdout)
            self.assertEqual(built, self.build())
            issue_json = json.dumps({"number": 5, "title": built["title"], "body": built["body"],
                                     "labels": [{"name": lib.FOLLOWUP_LABEL}]})
            meta = json.loads(run_lib("followup-meta", stdin=issue_json).stdout)
            self.assertEqual(meta["feedback"], self.FEEDBACK.strip())


class SlugifyTest(unittest.TestCase):
    def test_cut_never_leaves_a_hyphen(self):
        # "gradient-routing-" is what a plain 17-character cut used to leave.
        self.assertEqual(lib.slugify("Gradient routing persistence", 17, word_boundary=False), "gradient-routing")
        self.assertEqual(lib.slugify("  Does X (really) help?  ", 60, word_boundary=False), "does-x-really-help")

    def test_word_boundary_drops_the_partial_word(self):
        self.assertEqual(lib.slugify("Gradient routing persistence", 20, word_boundary=True), "gradient-routing")
        self.assertEqual(lib.slugify("Gradient routing persistence", 16, word_boundary=True), "gradient-routing")
        self.assertEqual(lib.slugify("Gradient routing persistence", 20, word_boundary=False), "gradient-routing-per")

    def test_cli(self):
        self.assertEqual(run_lib("slug", "--max-length", "40", "--word-boundary", "--", "-Leading dash").stdout,
                         "leading-dash\n")


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

    def test_success_flag(self):
        self.add_exp("exp-001", "PASS")
        self.assertTrue(self.outcome()["success"])
        self.assertTrue(self.outcome(publish_state="skipped")["success"])
        self.assertFalse(self.outcome(publish_state="failed")["success"])
        self.assertFalse(self.outcome(status="failed")["success"])
        self.assertFalse(self.outcome(paused=True, publish_state="skipped")["success"])

    def test_findings_are_collected(self):
        self.add_exp("exp-001", "PASS")
        write(self.run / "next-steps.md", "**Outcome**: It holds.\n\n## Ranked Next Steps\n\n### 1. Scale up\n")
        write(self.run / "audit" / "results-audit.md", "## Overall disposition: HONEST-POSITIVE\n")
        facts = self.outcome()
        self.assertEqual((facts["findings"], facts["next_step_titles"], facts["audit"]),
                         ("It holds.", ["Scale up"], "HONEST-POSITIVE"))
        self.assertEqual(json.loads(json.dumps(facts)), facts)

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

    def test_preflight_that_cannot_be_read_raises(self):
        # Not "no readable table": the outcome fails loudly instead.
        self.add_exp("exp-001", "PASS", preflight=None)
        (self.run / "experiments" / "exp-001" / "preflight.md").mkdir()
        with self.assertRaises(OSError):
            lib.parse_preflight(self.run / "experiments" / "exp-001" / "preflight.md")

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

    def test_comment_is_formatted_from_the_outcome_alone(self):
        facts = lib.compute_outcome(self.run, status="complete", timed_out=False, publish_state="pushed")
        (self.run / "next-steps.md").unlink()
        (self.run / "audit" / "results-audit.md").unlink()
        text = lib.issue_comment(facts, run_dir=self.run, run_id="2026-10-12-topic",
                                 repo_web="https://github.com/o/research-x", branch="main", agent_label="Claude fable",
                                 host="desktop", is_followup=False, visibility="private")
        self.assertIn("Routing localises, persistence untested.", text)
        self.assertIn("Results audit: HONEST-NEGATIVE (true-null)", text)
        self.assertIn("2. Capability-pressure RL", text)

    def test_unpublished_comment_has_no_dead_link(self):
        text = self.comment("failed", "")
        self.assertIn("finished but NOT PUBLISHED", text)
        self.assertIn("not on GitHub; local only at `desktop:", text)
        self.assertIn("git push of main failed", text)
        self.assertNotIn("github.com", text)

    def test_cli_requires_branch_and_visibility(self):
        args = ["issue-comment", "--run-dir", str(self.run), "--status", "complete", "--publish-state", "pushed",
                "--run-id", "r", "--repo-web", "https://github.com/o/research-x"]
        ok = run_lib(*args, "--branch", "main", "--visibility", "internal")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("https://github.com/o/research-x/tree/main (internal)", ok.stdout)
        for missing in ("--branch", "--visibility"):
            given = ["--branch", "main", "--visibility", "private"]
            del given[given.index(missing):given.index(missing) + 2]
            result = run_lib(*args, *given)
            self.assertEqual(result.returncode, 2)
            self.assertIn(missing, result.stderr)
        self.assertEqual(run_lib(*args, "--branch", "main", "--visibility", "secret").returncode, 2)


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



class ResultsEmailTest(unittest.TestCase):
    def test_plain_text_alternative(self):
        text = lib.html_to_text(
            "<html><head><style>p{color:red}</style></head><body><h1>Bottom&nbsp;line</h1>"
            "<p>Positive: the filter <b>halves</b> misalignment.</p><ul><li>5 seeds</li><li>matched loss</li></ul>"
            "<table><tr><th>Arm</th><th>EM %</th></tr><tr><td>filter</td><td>8.1</td></tr></table>"
            "<img src=\"cid:main\" alt=\"EM rate by arm\"></body></html>")
        self.assertEqual(text, "Bottom line\n\nPositive: the filter halves misalignment.\n\n- 5 seeds\n- matched loss"
                               "\n\nArm | EM %\nfilter | 8.1\n[EM rate by arm]\n")
        self.assertNotIn("color", text)

    def test_inline_images_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / "run"
            write(run / "figures/main.png", "png")
            write(run / "figures/notes.txt", "x")
            write(Path(tmp) / "outside.png", "png")
            write(run / "email-draft.html", '<img src="cid:main"><img src="cid:dup"><img src="cid:txt">')
            self.assertEqual(lib.email_images(run), ([], []))                  # no listing: no images
            write(run / "email-images.txt", "# plots\nmain = figures/main.png\nmain=figures/main.png\n"
                                            "unplaced=figures/main.png\nesc=../outside.png\ntxt=figures/notes.txt\n"
                                            "bad name=figures/main.png\nmissing=figures/none.png\n")
            images, problems = lib.email_images(run)
            self.assertEqual(images, [f"main={(run / 'figures/main.png').resolve()}"])
            self.assertEqual([p.split(":")[0] for p in problems],
                             ["main", "unplaced", "esc", "txt", "'bad name=figures/main.png'", "missing"])
            # The CLI fails on any bad line, so the email is fixed rather than sent without it.
            bad = run_lib("email-images", "--run-dir", str(run))
            self.assertEqual(bad.returncode, 1)
            self.assertEqual(bad.stdout, "")
            self.assertIn("unplaced: email-draft.html does not place it", bad.stderr)
            write(run / "email-images.txt", "# plots\nmain = figures/main.png\n")
            good = run_lib("email-images", "--run-dir", str(run))
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertEqual(good.stdout.strip(), images[0])


if __name__ == "__main__":
    unittest.main()

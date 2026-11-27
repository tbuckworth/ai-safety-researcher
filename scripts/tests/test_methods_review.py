"""Exercise review and approval via the real CLI. Only the paid Codex call is replaced."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "methods_review.py"

# Capture inputs and return a structured last message as a real non-interactive
# provider would. The repository test suite cannot use the live model.
PROVIDER = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
prompt = sys.stdin.read()
output = Path(args[args.index("--output-last-message") + 1])
schema = json.loads(Path(args[args.index("--output-schema") + 1]).read_text())
call = {"args": args, "prompt": prompt, "schema": schema}
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps(call) + "\\n")
if "FAIL_PROVIDER" in os.environ:
    sys.exit(1)
if "BAD_RESPONSE" in os.environ:
    output.write_text("{}")
else:
    # Re-check every finding the schema requires, as a real reviewer must, and
    # raise one new finding: blocking unless the stated decision is approve.
    decision = os.environ.get("DECISION", "approve")
    rechecks = {finding: {"status": os.environ.get("RECHECK", "resolved"), "blocking": True, "text": "Re-checked."}
                for finding in schema["properties"]["rechecks"]["required"]}
    blocking = os.environ.get("BLOCKING", "false" if decision == "approve" else "true") == "true"
    # The finding's sources: SOURCES (comma-separated), else every reviewed input.
    allowed = schema["properties"]["new_findings"]["items"]["properties"]["sources"]["items"]["enum"]
    sources = [n for n in os.environ["SOURCES"].split(",") if n] if "SOURCES" in os.environ else allowed
    new = [{"blocking": blocking, "title": "Split", "text": "One fixed split",
            "reopens": os.environ.get("REOPENS", ""), "sources": sources}]
    output.write_text(json.dumps({"decision": decision, "summary": "Scope justified",
                                  "rechecks": rechecks, "new_findings": new}))
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 20, "output_tokens": 5}}))
"""


class ReviewTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.run = Path(temporary.name) / "study"
        self.run.mkdir()
        self.mode("autonomous")
        self.write("method-spec.md", "Estimate a difference in held-out accuracy.")
        self.write("success-criteria.md", "Effects beyond 2 percentage points count.")
        self.write("methods-order.json", '["exp-f01", "exp-f02"]')
        self.write("experiments/exp-f01/plan.md", "Paired checkpoints with an identical split.")
        self.write("experiments/exp-f02/plan.md", "Repeat on a new split.")
        self.calls = Path(temporary.name) / "calls.jsonl"
        self.binary = Path(temporary.name) / "codex"
        self.binary.write_text(PROVIDER)
        self.binary.chmod(0o700)
        self.env = dict(os.environ, RESEARCHER_CODEX_BIN=str(self.binary), CALLS=str(self.calls))

    def mode(self, mode):
        self.write("state.md", f"---\nmode: {mode}\nrun_id: demo\ntopic: calibration\n---\n")

    def write(self, name, content):
        path = self.run / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def invoke(self, action, *args, code=0):
        proc = subprocess.run([sys.executable, SCRIPT, action, self.run, *args],
                              env=self.env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, code, (proc.stdout, proc.stderr))
        return proc.stdout.strip()

    def records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def ledger(self, phase):
        return json.loads((self.run / "reviews" / phase / "ledger.json").read_text())

    def draft(self, text):
        self.write("briefing.md", text)
        self.write("review-figures.json", '{"figures":[],"reason":"Text-only briefing."}')

    def test_independent_plan_reviews_and_bound_auto_approval(self):
        self.invoke("verify", code=1)
        self.invoke("approve-auto", code=1)
        rev = self.invoke("plan")
        self.assertEqual(rev, self.invoke("plan"))
        calls = self.records()
        self.assertEqual(len(calls), 3)
        self.assertEqual(len({c["prompt"] for c in calls}), 3)
        for call in calls:
            self.assertIn("Paired checkpoints", call["prompt"])
            self.assertNotIn("Scope justified", call["prompt"])
            args = call["args"]
            self.assertIn("--ephemeral", args)
            self.assertEqual(args[args.index("--sandbox") + 1], "read-only")
            self.assertEqual(args[args.index("--model") + 1], "gpt-6.2-sol")
            self.assertIn('model_reasoning_effort="xhigh"', args)
            self.assertIn("shell_tool", args)
            self.assertIn("multi_agent_v2", args)
        self.assertEqual(self.invoke("approve-auto"), rev)
        self.assertIn("Scope justified", self.records()[3]["prompt"])
        self.assertEqual(self.invoke("verify"), rev)
        self.invoke("approve-human", rev, code=1)
        self.assertEqual(len(self.records()), 4)
        stored = json.loads((self.run / "reviews/approval" / f"{rev}.json").read_text())
        self.assertEqual(stored["reviews"][0]["usage"][0]["input_tokens"], 20)
        self.assertGreaterEqual(stored["reviews"][0]["elapsed_seconds"], 0)

        self.write("methods-order.json", '["exp-f02", "exp-f01"]')
        self.invoke("verify", code=1)
        self.write("methods-order.json", '["exp-f01", "exp-f02"]')
        self.write("experiments/exp-f02/plan.md", "Different comparison")
        self.invoke("verify", code=1)
        frozen = json.loads((self.run / "reviews/plan" / f"{rev}.json").read_text())["methods"]
        self.assertEqual(frozen["experiments/exp-f02/plan.md"], "Repeat on a new split.")
        self.assertEqual(frozen["success-criteria.md"], (self.run / "success-criteria.md").read_text())
        self.assertNotIn("study", frozen)
        self.write("methods-order.json", '["exp-f01"]')
        self.invoke("plan", code=1)
        self.write("methods-order.json", '["exp-f01","exp-f01","exp-f02"]')
        self.invoke("plan", code=1)

    def test_interactive_approver_must_identify_exact_revision(self):
        self.mode("interactive")
        self.env["DECISION"] = "revise"
        rev = self.invoke("plan")
        self.invoke("approve-auto", code=1)
        self.invoke("approve-human", "older", code=1)
        self.invoke("approve-human", rev)
        self.invoke("verify")
        self.write("prior/success-criteria.md", "New inherited anchor")
        self.invoke("verify", code=1)
        self.assertEqual(len(self.records()), 3)

    def test_rejected_or_incomplete_approval_never_allows_execution(self):
        self.env["FAIL_PROVIDER"] = "1"
        self.invoke("plan", code=1)
        self.invoke("approve-auto", code=1)
        del self.env["FAIL_PROVIDER"]
        self.env["BAD_RESPONSE"] = "1"
        self.invoke("plan", code=1)
        del self.env["BAD_RESPONSE"]
        self.invoke("plan")
        self.env["DECISION"] = "stop"
        self.invoke("approve-auto", code=4)
        self.invoke("verify", code=4)

    def test_evidence_and_report_revisions(self):
        self.write("experiments/exp-f01/results.md", "Measured 2 pp on one pilot.")
        self.write("experiments/exp-f01/run.log", "seed 0, n = 20")
        self.env["DECISION"] = "revise"
        self.invoke("evidence", code=3)
        self.assertIn("revise", self.invoke("verify-evidence"))
        self.write("experiments/exp-f01/run.log", "seed 0, n = 10")
        self.invoke("verify-evidence", code=1)
        self.write("briefing.md", "Not enough evidence for a conclusion.")
        self.invoke("presentation", code=1)
        self.write("review-figures.json", '{"figures":[],"reason":""}')
        self.invoke("presentation", code=1)
        self.write("review-figures.json", '{"figures":["paper/figures/primary.png"],"reason":""}')
        self.write("paper/figures/primary.png", "figure bytes")
        self.invoke("presentation", code=3)
        self.invoke("verify-presentation", code=3)
        self.write("briefing.md", "One development seed. The primary trial did not run.")
        self.env["DECISION"] = "approve"
        self.invoke("presentation")
        self.invoke("verify-presentation")
        args = self.records()[-1]["args"]
        self.assertEqual(args[args.index("--image") + 1], str(self.run / "paper/figures/primary.png"))
        self.write("paper/figures/primary.png", "changed")
        self.invoke("verify-presentation", code=1)
        self.write("review-figures.json", '{"figures":["../external.png"],"reason":""}')
        self.invoke("presentation", code=1)

    def test_historical_observations_can_be_audited_without_prospective_approval(self):
        (self.run / "methods-order.json").unlink()
        self.write("experiments/exp-f01/results.md", "Pilot measured 18/20.")
        self.invoke("evidence")
        self.assertIn("Prospective agreement cannot be verified", self.records()[0]["prompt"])
        self.assertIn("Missing from this run", self.records()[0]["prompt"])
        self.invoke("verify-evidence")
        self.invoke("verify", code=1)
        self.write("briefing.md", "Historical pilot only.")
        self.write("review-figures.json", '{"figures":[],"reason":"This note records a method change."}')
        self.invoke("presentation")
        self.assertIn("reviews/evidence/", self.records()[-1]["prompt"])

    def test_partial_diagnostic_can_be_read_without_experiments_or_paper(self):
        (self.run / "methods-order.json").unlink()
        self.write("next-steps.md", "Stopped at study design.")
        self.invoke("presentation")
        self.invoke("verify-presentation")
        self.invoke("verify", code=1)
    def test_evidence_preserves_approval_timing_and_allows_retrospective_review(self):
        self.write("experiments/exp-f01/results.md", "Pilot observed before an amendment.")
        revision = self.invoke("plan")
        self.invoke("approve-auto")
        approval = json.loads((self.run / "reviews/approval" / f"{revision}.json").read_text())
        self.assertEqual(approval["results_already_present"], ["exp-f01"])
        self.write("experiments/exp-f02/results.md", "Confirmation after approval.")
        self.invoke("verify")
        self.invoke("evidence")
        self.assertIn("results_already_present", self.records()[-1]["prompt"])
        self.write("methods-order.json", '["exp-f02"]')
        self.invoke("verify", code=1)
        self.invoke("evidence")
        self.assertIn("Prospective agreement cannot be verified", self.records()[-1]["prompt"])

    def test_later_rounds_see_earlier_findings_and_the_hub_responses(self):
        self.draft("Muon leaks least.")
        self.env["DECISION"] = "revise"
        self.invoke("presentation", code=3)
        finding = self.ledger("presentation")["findings"][0]
        check = finding["events"][-1]
        self.assertEqual((finding["id"], check["status"], check["blocking"]), ("presentation-1", "open", True))
        self.invoke("respond", "presentation", "presentation-1", "fixed", "Headline now gives the pooled gap")
        self.draft("Muon leaks 12.5 points less at zero safe examples.")
        self.env["DECISION"] = "approve"
        self.invoke("presentation")
        second = self.records()[-1]
        self.assertEqual(second["schema"]["properties"]["rechecks"]["required"], ["presentation-1"])
        self.assertIn("Headline now gives the pooled gap", second["prompt"])
        self.assertIn("Round 2 of at most 3", second["prompt"])
        self.assertIn('"changed": ["briefing.md"]', second["prompt"])
        finding = self.ledger("presentation")["findings"][0]
        self.assertEqual(finding["events"][-1]["status"], "resolved")
        self.assertEqual([event["by"] for event in finding["events"]], ["reviewer", "hub", "reviewer"])

    def test_only_blocking_findings_withhold_a_draft(self):
        self.env["RESEARCHER_MAX_REVIEW_ROUNDS"] = "5"
        self.draft("Draft one.")
        self.env.update(DECISION="revise", BLOCKING="false")
        revision = self.invoke("presentation")
        receipt = json.loads((self.run / "reviews/presentation" / f"{revision}.json").read_text())["reviews"][0]
        self.assertEqual((receipt["decision"], receipt["stated_decision"]), ("approve", "revise"))
        self.assertFalse(receipt["findings"][0]["blocking"])
        self.draft("Draft two.")
        self.env.update(DECISION="approve", RECHECK="open", BLOCKING="true")
        self.invoke("presentation", code=3)
        self.draft("Draft three.")
        self.env.update(RECHECK="open", BLOCKING="false")
        self.invoke("presentation", code=3)

    def test_round_cap_ends_each_loop_until_a_new_cycle(self):
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS="2", DECISION="revise", RECHECK="open")
        self.draft("Draft one.")
        self.invoke("presentation", code=3)
        self.draft("Draft two.")
        # The last round of the cycle still asks for revision: its exit is the stage's exit at the cap.
        last = self.invoke("presentation", code=5)
        self.assertIn("This is the last round", self.records()[-1]["prompt"])
        self.assertEqual(self.invoke("presentation", code=5), last)
        self.assertEqual(self.invoke("verify-presentation", code=5), last)
        self.draft("Draft three.")
        self.assertEqual(self.invoke("presentation", code=5), last)
        self.assertEqual(len(self.records()), 2)
        self.invoke("presentation", "--new-cycle", "Titus asked for one more pass (mail 12)", code=3)
        rounds = self.ledger("presentation")["rounds"]
        self.assertEqual([(r["round"], r["cycle"]) for r in rounds], [(1, 1), (2, 1), (3, 2)])
        self.assertEqual(rounds[2]["cycle_reason"], "Titus asked for one more pass (mail 12)")
        self.invoke("presentation", "--new-cycle", "again", code=1)
        self.invoke("evidence", "--new-cycle", "no cap here", code=2)

    def test_plan_cap_exit_approves_the_last_reviewed_revision_once_restored(self):
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS="1", DECISION="revise")
        reviewed = self.invoke("plan")
        self.invoke("plan")
        self.write("experiments/exp-f02/plan.md", "Repeat on a new split with a second seed.")
        self.assertEqual(self.invoke("plan", code=5), reviewed)
        self.invoke("approve-auto", code=1)
        methods = json.loads((self.run / "reviews/plan" / f"{reviewed}.json").read_text())["methods"]
        for name, text in methods.items():
            self.write(name, text)
        self.env["DECISION"] = "approve"
        self.assertEqual(self.invoke("approve-auto"), reviewed)
        self.assertIn("Review ledger of the plan stage", self.records()[-1]["prompt"])
        self.assertEqual(self.invoke("verify"), reviewed)

    def test_final_reader_sees_the_evidence_ledger(self):
        self.write("experiments/exp-f01/results.md", "Measured 2 pp on one pilot.")
        self.env["DECISION"] = "revise"
        self.invoke("evidence", code=3)
        self.draft("One pilot measured 2 pp.")
        self.env["DECISION"] = "approve"
        self.invoke("presentation")
        prompt = self.records()[-1]["prompt"]
        self.assertIn("Review ledger of the evidence stage", prompt)
        self.assertIn('"evidence-1"', prompt)
        self.assertNotIn("Review ledger of the presentation stage", prompt)

    def test_hub_responses_name_a_recorded_open_finding(self):
        self.draft("Draft one.")
        self.env["DECISION"] = "revise"
        self.invoke("presentation", code=3)
        self.invoke("respond", "presentation", "presentation-9", "fixed", "Moved", code=1)
        self.invoke("respond", "presentation", "presentation-1", "fixed", " ", code=1)
        self.invoke("respond", "presentation", "presentation-1", "ignored", "Moved", code=2)
        self.invoke("respond", "plan", "presentation-1", "fixed", "Moved", code=1)
        self.invoke("respond", "presentation", "presentation-1", "limit", "Stated under Limits in briefing.md")
        self.draft("Draft two, with limits.")
        self.env["DECISION"] = "approve"
        self.invoke("presentation")
        self.invoke("respond", "presentation", "presentation-1", "declined", "Settled", code=1)
        events = self.ledger("presentation")["findings"][0]["events"]
        self.assertEqual(events[1]["response"], "limit")
        self.assertEqual(events[1]["after_round"], 1)

    def test_a_settled_finding_reopens_only_as_a_linked_new_finding(self):
        self.env["RESEARCHER_MAX_REVIEW_ROUNDS"] = "5"
        self.draft("Draft one.")
        self.env["DECISION"] = "revise"
        self.invoke("presentation", code=3)
        self.draft("Draft two.")
        self.env["DECISION"] = "approve"
        self.invoke("presentation")
        self.draft("Draft three.")
        self.env.update(DECISION="revise", REOPENS="presentation-1")
        self.invoke("presentation", code=3)
        schema = self.records()[-1]["schema"]["properties"]["new_findings"]["items"]["properties"]["reopens"]
        self.assertEqual(schema["enum"], ["", "presentation-1"])
        reopened = self.ledger("presentation")["findings"][-1]
        self.assertEqual((reopened["id"], reopened["reopens"]), ("presentation-3", "presentation-1"))

    def test_each_plan_critic_rechecks_its_own_findings_and_sees_the_others(self):
        self.env["DECISION"] = "revise"
        self.invoke("plan")
        owners = {f["id"]: f["role"] for f in self.ledger("plan")["findings"]}
        self.assertEqual(owners, {"plan-1": "assumption-challenger", "plan-2": "mentor-review", "plan-3": "pre-mortem"})
        self.write("experiments/exp-f02/plan.md", "Repeat on a new split with a second seed.")
        self.invoke("plan")
        later = self.records()[3:]
        self.assertEqual(sorted(c["schema"]["properties"]["rechecks"]["required"][0] for c in later),
                         ["plan-1", "plan-2", "plan-3"])
        for call in later:
            for finding in owners:
                self.assertIn(f'"{finding}"', call["prompt"])

    def revise_plan(self, text):
        self.write("experiments/exp-f02/plan.md", text)
        return self.invoke("plan")

    def test_approver_revision_below_the_cap_starts_a_new_plan_cycle(self):
        self.env["DECISION"] = "revise"
        self.invoke("plan")
        self.env["RECHECK"] = "resolved"
        self.revise_plan("Repeat on a new split with a second seed.")
        settled = [f["id"] for f in self.ledger("plan")["findings"]
                   if f["events"][-1]["status"] == "resolved"]
        self.assertEqual(settled, ["plan-1", "plan-2", "plan-3"])
        self.invoke("approve-auto", code=3)
        schema = self.records()[-1]["schema"]["properties"]["new_findings"]["items"]["properties"]
        self.assertEqual(schema["reopens"]["enum"], ["", "plan-1", "plan-2", "plan-3"])
        self.assertIn("Round 1 of at most 3", self.records()[-1]["prompt"])
        self.assertEqual(self.ledger("plan")["pending_cycle"],
                         "the automatic approver requested a revision (approval round 1)")
        self.invoke("approve-auto", code=3)
        self.invoke("respond", "approval", "approval-1", "fixed", "exp-f02 now names its second seed")
        self.env["DECISION"] = "approve"
        self.revise_plan("Repeat on a new split with a second and third seed.")
        rounds = self.ledger("plan")["rounds"]
        self.assertEqual([(r["round"], r["cycle"]) for r in rounds], [(1, 1), (2, 1), (3, 2)])
        self.assertEqual(rounds[2]["cycle_reason"], "the automatic approver requested a revision (approval round 1)")
        self.assertNotIn("pending_cycle", self.ledger("plan"))
        revision = self.invoke("approve-auto")
        self.assertEqual(self.invoke("verify"), revision)

    def test_approver_revision_at_the_cap_admits_the_reviewed_revision(self):
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS="2", DECISION="revise", RECHECK="open")
        self.invoke("plan")
        self.invoke("approve-auto", code=3)
        self.invoke("respond", "approval", "approval-1", "limit", "Stated in exp-f02")
        reviewed = self.revise_plan("Repeat on a new split with a second seed.")
        self.assertEqual(self.invoke("approve-auto", code=5), reviewed)
        self.assertIn("This is the last approval round", self.records()[-1]["prompt"])
        calls = len(self.records())
        self.assertEqual(self.invoke("approve-auto", code=5), reviewed)
        self.assertEqual(self.invoke("verify"), reviewed)
        self.assertNotIn("pending_cycle", self.ledger("plan"))
        report = json.loads(self.invoke("cap-findings"))
        self.assertEqual(report["ids"][:2], ["approval-1", "approval-2"])
        self.assertIn("plan-1", report["ids"])
        self.assertIn("Methods approval at its round cap", report["markdown"])
        self.assertIn("approval-2 (Split)", report["notes"][0])
        # The evidence critic is told why execution went ahead.
        self.write("experiments/exp-f01/results.md", "Measured 2 pp on one pilot.")
        self.invoke("evidence", code=3)
        self.assertIn("still asked for revision in its last round", self.records()[-1]["prompt"])
        # No further approval round: an edited plan must go back to the reviewed one.
        self.write("experiments/exp-f02/plan.md", "Something else.")
        self.invoke("verify", code=1)
        self.assertEqual(len(self.records()), calls + 1)
        # The approver's open findings are still listed for the report after the edit.
        self.assertEqual(json.loads(self.invoke("cap-findings"))["ids"][:2], ["approval-1", "approval-2"])

    def test_a_stop_at_the_cap_still_stops(self):
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS="1", DECISION="stop")
        self.invoke("plan")
        self.invoke("approve-auto", code=4)
        self.invoke("verify", code=4)
        self.assertEqual(json.loads(self.invoke("cap-findings"))["ids"], [])

    def test_a_later_round_blocks_only_on_changed_material(self):
        self.draft("Draft one.")
        self.env["DECISION"] = "revise"
        self.invoke("presentation", code=3)
        self.invoke("respond", "presentation", "presentation-1", "fixed", "Reworded")
        # Round 2: a new blocking finding on review-figures.json, which round 1 reviewed unchanged.
        self.write("briefing.md", "Draft two.")
        self.env.update(RECHECK="resolved", SOURCES="review-figures.json")
        self.invoke("presentation")
        prompt = self.records()[-1]["prompt"]
        self.assertIn('"changed": ["briefing.md"]', prompt)
        self.assertIn('"unchanged": [', prompt)
        certified = self.ledger("presentation")["findings"][1]
        event = certified["events"][-1]
        self.assertEqual((certified["id"], event["blocking"], event["stated_blocking"]), ("presentation-2", False, True))
        self.assertIn("certified range", event["certified"])
        self.assertEqual(certified["sources"], ["review-figures.json"])
        # Round 3: one on the changed briefing blocks; a re-check cannot make the certified one blocking.
        self.write("briefing.md", "Draft three.")
        self.env.update(RECHECK="open", SOURCES="briefing.md")
        self.invoke("presentation", code=5)
        findings = {f["id"]: f["events"][-1] for f in self.ledger("presentation")["findings"]}
        self.assertFalse(findings["presentation-2"]["blocking"])
        self.assertTrue(findings["presentation-3"]["blocking"])
        # A finding that reopens a settled one blocks whatever its sources.
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS="5", SOURCES="", REOPENS="presentation-1")
        self.write("briefing.md", "Draft four.")
        self.invoke("presentation", code=3)
        self.assertTrue(self.ledger("presentation")["findings"][-1]["events"][-1]["blocking"])

    def test_sources_must_name_reviewed_inputs(self):
        self.draft("Draft one.")
        self.env.update(DECISION="revise", SOURCES="no-such-file.md")
        self.invoke("presentation", code=1)

    def declined_run(self, rounds, cap=3):
        """A run that an older rule stopped after `rounds` approval rounds asking for revision."""
        self.env.update(RESEARCHER_MAX_REVIEW_ROUNDS=str(cap), DECISION="revise")
        self.invoke("plan")
        for n in range(rounds):
            if n:
                self.revise_plan(f"Repeat on a new split, revision {n}.")
            revision = self.invoke("approve-auto", code=5 if n + 1 >= cap else 3)
        self.write("methods-stop.md", "Stopped at the one-revision limit.")
        self.write("audit/results-audit.md", "NO-EXPERIMENTS")
        self.write("paper/paper.tex", "Protocol only.")
        self.write("next-steps.md", "Apply the repairs.")
        self.draft("Declined before execution.")
        self.invoke("presentation", code=3)
        self.write("success-criteria.md", "Edited by the report step.")
        return revision

    def test_reopen_supersedes_a_stop_from_the_old_revision_limit(self):
        revision = self.declined_run(2)
        calls = len(self.records())
        result = json.loads(self.invoke("reopen-declined"))
        self.assertTrue(result["reopened"])
        self.assertEqual((result["revision"], result["approval_rounds"], result["at_cap"]), (revision, 2, False))
        self.assertEqual(result["restored"], ["success-criteria.md"])
        history = self.run / result["moved_to"]
        for name in ("methods-stop.md", "briefing.md", "next-steps.md", "review-figures.json", "paper/paper.tex",
                     "audit/results-audit.md"):
            self.assertTrue((history / name).is_file(), name)
            self.assertFalse((self.run / name).exists(), name)
        self.assertIn("one-revision limit", (history / "README.md").read_text())
        self.assertEqual((self.run / "success-criteria.md").read_text(), "Effects beyond 2 percentage points count.")
        self.assertIn("approval round 2", self.ledger("plan")["pending_cycle"])
        self.assertIn("superseded", self.ledger("presentation")["pending_cycle"])
        # Step 8 takes the approver's last decision again: a revision below the cap.
        self.assertEqual(self.invoke("approve-auto", code=3), revision)
        self.assertEqual(len(self.records()), calls)
        self.assertFalse(json.loads(self.invoke("reopen-declined"))["reopened"])

    def test_reopen_at_the_cap_proceeds_with_the_reviewed_revision(self):
        revision = self.declined_run(2, cap=2)
        result = json.loads(self.invoke("reopen-declined"))
        self.assertTrue(result["reopened"] and result["at_cap"])
        self.assertNotIn("pending_cycle", self.ledger("plan"))
        self.assertEqual(self.invoke("approve-auto", code=5), revision)
        self.assertEqual(self.invoke("verify"), revision)

    def test_reopen_leaves_a_stated_stop_or_a_started_experiment(self):
        self.declined_run(1)
        self.write("literature/synthesis.md", "A review added after the approval.")
        self.assertIn("does not keep (literature/synthesis.md)", json.loads(self.invoke("reopen-declined"))["why"])
        (self.run / "literature/synthesis.md").unlink()
        self.mode("interactive")
        self.assertIn("not autonomous", json.loads(self.invoke("reopen-declined"))["why"])
        self.mode("autonomous")
        self.write("experiments/exp-f01/started", "")
        self.assertIn("already started", json.loads(self.invoke("reopen-declined"))["why"])
        (self.run / "experiments/exp-f01/started").unlink()
        approval = self.ledger("approval")
        approval["rounds"][-1]["decisions"]["auto"] = "stop"
        self.write("reviews/approval/ledger.json", json.dumps(approval))
        self.assertIn("not revise", json.loads(self.invoke("reopen-declined"))["why"])
        self.assertTrue((self.run / "methods-stop.md").is_file())

    def test_receipts_recorded_before_the_ledger_still_verify(self):
        self.mode("interactive")
        revision = self.invoke("plan")
        path = self.run / "reviews/plan" / f"{revision}.json"
        receipt = json.loads(path.read_text())
        for report in receipt["reviews"]:
            report["findings"] = [finding["text"] for finding in report["findings"]]
        path.write_text(json.dumps(receipt))
        self.invoke("approve-human", revision)
        self.assertEqual(self.invoke("verify"), revision)

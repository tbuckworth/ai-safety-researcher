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
call = {"args": args, "prompt": prompt}
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps(call) + "\\n")
if "FAIL_PROVIDER" in os.environ:
    sys.exit(1)
if "BAD_RESPONSE" in os.environ:
    output.write_text("{}")
else:
    output.write_text(json.dumps({"decision": os.environ.get("DECISION", "approve"),
                                  "summary": "Scope justified", "findings": ["One fixed split"]}))
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
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

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

"""Unit tests for scripts/results_report.py (stdlib unittest; no network, no model)."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import researcher_lib as lib  # noqa: E402
import results_report as report  # noqa: E402

AGENT_USAGE = shutil.which("agent-usage")


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def run_report(*args, env=None):
    return subprocess.run([sys.executable, str(SCRIPTS / "results_report.py"), *args],
                          capture_output=True, text=True, env=env)


# The login order is the installed mailroom's own code, run on a test configuration.
@unittest.skipUnless(AGENT_USAGE, "the agent mailroom (agent-usage) is not installed")
class LoginsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.arrow = self.root / "logins" / "arrow"
        write(self.arrow / ".credentials.json", "")
        (self.root / "logins" / "unset-up").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def logins(self, order, extra=None, **env):
        accounts = {"personal": {"config_dir": None}, "arrow": {"config_dir": str(self.arrow)},
                    "fresh": {"config_dir": str(self.root / "logins" / "unset-up")}}
        cfg = dict({"usage": {"claude_accounts": accounts, "order": order}}, **(extra or {}))
        write(self.root / "config" / "config.json", json.dumps(cfg))
        child = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "AGENT_MAIL", "ANTHROPIC"))}
        child.update(AGENT_MAIL_CONFIG_DIR=str(self.root / "config"), AGENT_MAIL_STATE_DIR=str(self.root / "state"),
                     **env)
        result = run_report("logins", "--agent-usage", AGENT_USAGE, env=child)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_order_skips_logins_not_set_up(self):
        out = self.logins(["claude:personal", "claude:arrow", "claude:fresh", "codex"])
        self.assertEqual(out["logins"], [
            {"kind": "claude", "name": "personal", "config_dir": ""},
            {"kind": "claude", "name": "arrow", "config_dir": str(self.arrow)},
            {"kind": "codex", "name": "codex", "config_dir": ""},
        ])

    def test_codex_first_when_the_order_says_so(self):
        out = self.logins(["codex", "claude:arrow"])
        self.assertEqual([x["name"] for x in out["logins"]], ["codex", "arrow"])

    def test_never_the_api_key(self):
        # With a secret name, token and project files, the mailroom itself would add its paid API key last.
        token = write(self.root / "bws" / "token", "not-a-real-token")
        project = write(self.root / "bws" / "project", "not-a-real-project")
        out = self.logins(["claude:personal", "codex"], extra={
            "orchestrator_fallback_secret": "SOME_API_KEY", "bws_token_file": str(token),
            "bws_project_file": str(project)})
        self.assertEqual([x["name"] for x in out["logins"]], ["personal", "codex"])

    def test_names_the_inherited_session_to_unset(self):
        out = self.logins(["claude:personal"], CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="abc",
                          CLAUDE_CONFIG_DIR=str(self.arrow), KEEP_ME="1")
        self.assertEqual(out["unset"], ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR"])

    def test_names_another_login_s_endpoint_and_models_to_unset(self):
        # What a login's settings file puts in the environment of a session on it, whatever the mailroom drops.
        login_env = {"ANTHROPIC_BASE_URL": "https://per-token.example.test", "ANTHROPIC_MODEL": "m",
                     "ANTHROPIC_DEFAULT_SONNET_MODEL": "m", "ANTHROPIC_SMALL_FAST_MODEL": "m",
                     "CLAUDE_CODE_SUBAGENT_MODEL": "m", "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "60000",
                     "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
        out = self.logins(["claude:personal", "codex"], KEEP_ME="1", **login_env)
        self.assertEqual(out["unset"], sorted(login_env))

    def test_unimportable_mailroom_fails(self):
        result = run_report("logins", "--agent-usage", str(self.root / "bin" / "agent-usage"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("agentmail", result.stderr)


class TemplateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = Path(self.tmp.name) / "2026-11-24-a-run"
        write(self.run / "state.md", "---\ntopic: 'The raw topic <b>'\nstatus: complete\n---\n")
        write(self.run / "briefing.md", "# Research Briefing: Does A beat B & C?\n\nText.\n")
        write(self.run / "experiments" / "exp-001" / "results.md",
              "# Results\n\n## Component Tested\nA against B\n\n## Verdict: INCONCLUSIVE\n")
        write(self.run / "experiments" / "exp-001" / "preflight.md",
              "| Check | Status |\n|---|---|\n| pipeline-smoke | FAIL |\n")
        write(self.run / "next-steps.md", "**Outcome**: Nothing settled yet.\n\n## Ranked Next Steps\n\n"
                                          "### 1. Fix the pipeline\n\n### 2. Run the study\n")
        write(self.run / "paper" / "paper.pdf", "%PDF")
        write(self.run / ".repo_url", "https://github.com/o/research-a/tree/followup-x\n")
        write(self.run / "paper" / "figures" / "main.png", "PNG")
        write(self.run / "review-figures.json",
              json.dumps({"figures": ["paper/figures/main.png", "../outside.png", "paper/missing.png"]}))
        write(self.run.parent / "outside.png", "PNG")
        self.facts = lib.compute_outcome(self.run, status="complete", timed_out=False, publish_state="pushed")

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, **kw):
        args = dict(facts=self.facts, issue_url="https://github.com/o/tasks/issues/7", host_alias="desktop",
                    plugin_dir="/home/u/researcher", agent_bin="codex", continue_command="$researcher:researcher-continue",
                    agent_label="OpenAI Codex m (xhigh)", why=["personal: weekly limit <reached>"], today=date(2026, 11, 26))
        args.update(kw)
        return report.template_report(self.run, **args)

    def test_subject_and_headline(self):
        out = self.build()
        self.assertEqual(out["subject"], "[Auto-Research] Does A beat B & C? — finished without a conclusive "
                                         "experiment verdict — 1 inconclusive")
        self.assertIn("Does A beat B &amp; C?", out["html"])
        self.assertIn("Nothing settled yet.", out["html"])
        self.assertIn("26 Nov 2026", out["html"])
        self.assertIn('href="https://github.com/o/tasks/issues/7"', out["html"])

    def test_says_why_no_model_wrote_it(self):
        html = self.build()["html"]
        self.assertIn("Written without a model.", html)
        self.assertIn("<li>personal: weekly limit &lt;reached&gt;</li>", html)
        self.assertIn("assembled without a model", html)

    def test_results_caveats_and_next_steps(self):
        html = self.build()["html"]
        self.assertIn(">INCONCLUSIVE</span>", html)
        self.assertIn("pre-flight checks failed: pipeline-smoke", html)
        self.assertIn("Fix the pipeline", html)
        self.assertIn("Run the study", html)
        for reason in self.facts["reasons"]:
            self.assertIn(report._esc(reason), html)

    def test_links_name_the_follow_up_branch(self):
        html = self.build()["html"]
        self.assertIn('href="https://github.com/o/research-a/tree/followup-x"', html)
        self.assertIn('href="https://github.com/o/research-a/blob/followup-x/paper/paper.pdf"', html)
        self.assertIn('href="https://github.com/o/research-a/blob/followup-x/next-steps.md"', html)

    def test_unpublished_run_has_no_repo_link(self):
        (self.run / ".repo_url").unlink()
        html = self.build()["html"]
        self.assertIn("not on GitHub", html)
        self.assertNotIn("github.com/o/research-a", html)

    def test_continue_steps(self):
        html = self.build()["html"]
        self.assertIn("ssh desktop", html)
        self.assertIn(f"$researcher:researcher-continue {self.run}", html)
        self.assertNotIn("ssh ", self.build(host_alias="local")["html"])

    def test_only_listed_figures_inside_the_run(self):
        out = self.build()
        self.assertEqual(out["images"], [("figure1", (self.run / "paper/figures/main.png").resolve())])
        self.assertIn('src="cid:figure1"', out["html"])

    def test_a_record_missing_a_field_fails(self):
        facts = {k: v for k, v in self.facts.items() if k != "next_step_titles"}
        with self.assertRaises(KeyError):
            self.build(facts=facts)

    def test_title_falls_back_to_the_topic(self):
        (self.run / "briefing.md").unlink()
        self.assertTrue(self.build()["subject"].startswith("[Auto-Research] The raw topic <b> — "))

    def test_cli_writes_the_draft(self):
        write(self.run / "email-images.txt", "stale=old.png\n")
        (self.run / "run-outcome.json").write_text(json.dumps(self.facts), encoding="utf-8")
        result = run_report("template", "--run-dir", str(self.run), "--issue-url", "", "--host-alias", "local",
                            "--plugin-dir", "/p", "--agent", "claude", "--continue-command", "/researcher-continue",
                            "--agent-label", "Claude m", "--why", "a", "--why", "b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.run / "email-subject.txt").read_text().startswith("[Auto-Research] Does A beat"))
        self.assertIn("<li>b</li>", (self.run / "email-draft.html").read_text())
        self.assertEqual((self.run / "email-images.txt").read_text(), "figure1=paper/figures/main.png\n")
        # The helper that sends it accepts the draft it wrote.
        images, problems = lib.email_images(self.run)
        self.assertEqual(problems, [])
        self.assertEqual(len(images), 1)

    def test_no_figure_leaves_no_listing(self):
        (self.run / "review-figures.json").unlink()
        write(self.run / "email-images.txt", "stale=old.png\n")
        report.write_template(self.run, self.build())
        self.assertFalse((self.run / "email-images.txt").exists())


class SplitRepoUrlTest(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(report.split_repo_url("https://github.com/o/r"), ("https://github.com/o/r", "main"))
        self.assertEqual(report.split_repo_url("https://github.com/o/r.git/"), ("https://github.com/o/r", "main"))
        self.assertEqual(report.split_repo_url("https://github.com/o/r/tree/b-1/x"), ("https://github.com/o/r", "b-1"))


if __name__ == "__main__":
    unittest.main()

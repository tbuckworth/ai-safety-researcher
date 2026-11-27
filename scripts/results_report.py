#!/usr/bin/env python3
"""The parts of a run's results report that need no model (scripts/runner/notify.sh send_email):

  logins    the logins a model may write the report on, in the agent mailroom's order
  template  the report assembled from the run directory's saved files alone, for when no
            login could write it

Standard library only, apart from `logins`, which imports the installed mailroom's
own package (agentmail) to read its login order.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import researcher_lib as lib  # noqa: E402

# --------------------------------------------------------------------------
# The login order
# --------------------------------------------------------------------------


def report_logins(agent_usage: Path, environ: dict[str, str]) -> dict:
    """The ways to run the report's writer, in the order the mailroom's own headless runs use
    (agentmail.headless.logins: each Claude login of its usage.order that is set up, and Codex where
    that order puts it), as {"unset": [...], "logins": [{"kind", "name", "config_dir"}, ...]}.

    `agent_usage` is the installed mailroom's agent-usage, whose checkout holds the agentmail package
    (as all-hands-weekly finds it). `unset` names the variables of `environ` a child CLI must not
    inherit (agentmail.accounts.CLAUDE_ENV_DROP: another session's id, login or API key);
    `config_dir` is the Claude login's CLAUDE_CONFIG_DIR, empty for the default login and for Codex.
    The API key the mailroom tries last is left out (its secret name is cleared for this call, so its
    token is never read): it bills per token, and a report with no model costs nothing. Raises
    ImportError when agentmail cannot be imported from there, and whatever the mailroom raises for
    an unreadable configuration."""
    root = str(Path(agent_usage).resolve().parent.parent)
    if root not in sys.path:
        sys.path.insert(0, root)
    from agentmail import config, headless  # the mailroom's package, at `root`

    logins, drop = [], set()
    cfg = dict(config.load(), orchestrator_fallback_secret="")
    for name, _command, env in headless.logins(cfg, ["claude"], environ, ["codex"]):
        if name == headless.API_KEY:
            continue
        drop.update(k for k in environ if k not in env)
        logins.append({"kind": "codex" if name == "codex" else "claude", "name": name,
                       "config_dir": "" if name == "codex" else env.get("CLAUDE_CONFIG_DIR", "")})
    return {"unset": sorted(drop), "logins": logins}


# --------------------------------------------------------------------------
# The report with no model
# --------------------------------------------------------------------------

# The colours and boxes of the model-written report (commands/researcher-auto-email.md),
# so that a report assembled here reads like the others.
FONT = "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
H2 = "font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;"
BOX = "border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;"
CELL = "padding: 8px 12px; border-bottom: 1px solid #f1f5f9; vertical-align: top;"
HEAD_CELL = "text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;"
KEY_CELL = "padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;"
CODE = "background: #e2e8f0; padding: 1px 5px; border-radius: 3px;"
LINK = "color: #2563eb;"
BADGES = {
    "PASS": ("#dcfce7", "#166534"),
    "FAIL": ("#fee2e2", "#991b1b"),
    "MIXED": ("#fef9c3", "#854d0e"),
    "INCONCLUSIVE": ("#fef9c3", "#854d0e"),
}
BADGE_OTHER = ("#e2e8f0", "#334155")
MAX_FIGURES = 2


def _esc(text: str) -> str:
    return html.escape(str(text), quote=True)


def _link(url: str, text: str) -> str:
    return f'<a href="{_esc(url)}" style="{LINK}">{_esc(text)}</a>'


def _badge(verdict: str) -> str:
    background, colour = BADGES.get(verdict, BADGE_OTHER)
    return (f'<span style="background: {background}; color: {colour}; padding: 2px 8px; border-radius: 4px;'
            f' font-size: 12px; font-weight: 600;">{_esc(verdict)}</span>')


def split_repo_url(url: str) -> tuple[str, str]:
    """(repository web address, branch) of a run's .repo_url: https://github.com/OWNER/NAME, or a
    follow-up's https://github.com/OWNER/NAME/tree/BRANCH. The runner reads the same addresses in
    bash (scripts/runner/common.sh repo_path_of and repo_url_branch); a change of form goes in both.
    The branch is "main" when the address names none."""
    url = url.strip().rstrip("/")
    repo, _, rest = url.partition("/tree/")
    return repo.removesuffix(".git"), (rest.split("/")[0] if rest else "main")


def report_title(run_dir: Path) -> str:
    """The briefing's title (its first heading, without a leading "Research Briefing:"), else
    state.md's topic, else the run directory's name."""
    briefing = run_dir / "briefing.md"
    if briefing.is_file():
        match = re.search(r"^#\s+(.+)$", briefing.read_text(encoding="utf-8", errors="replace"), re.MULTILINE)
        if match:
            return re.sub(r"^Research Briefing\s*:\s*", "", match.group(1).strip(), flags=re.IGNORECASE)
    topic = lib.read_frontmatter(run_dir / "state.md").get("topic", "") if (run_dir / "state.md").is_file() else ""
    return topic.strip() or run_dir.name


def headline_figures(run_dir: Path) -> list[Path]:
    """The first MAX_FIGURES headline figures that review-figures.json lists (docs/WORKFLOW.md),
    those that are image files inside the run directory; none when the run has no such file."""
    manifest = run_dir / "review-figures.json"
    if not manifest.is_file():
        return []
    listed = json.loads(manifest.read_text(encoding="utf-8")).get("figures") or []
    root = run_dir.resolve()
    figures = []
    for rel in listed:
        path = (run_dir / str(rel)).resolve()
        if path.is_relative_to(root) and path.is_file() and path.suffix.lower() in lib.IMAGE_SUFFIXES:
            figures.append(path)
    return figures[:MAX_FIGURES]


def template_report(run_dir: Path, *, facts: dict, issue_url: str, host_alias: str, plugin_dir: str,
                    agent_bin: str, continue_command: str, agent_label: str, why: list[str],
                    today: date) -> dict:
    """The report of the run in `run_dir`, assembled with no model from what the run saved:
    `facts` (its run-outcome.json, researcher_lib.compute_outcome), its title (report_title), its
    published repository (.repo_url, present only after a verified push), its headline figures
    (headline_figures) and the continuation facts the runner gives a model writer. `why` says why
    no model wrote it. Returns {"subject", "html", "images"}: images are (NAME, path) pairs the HTML
    places as cid:NAME. The subject carries no outcome prefix; send-results-email.sh adds it. Raises
    KeyError when `facts` lacks a field compute_outcome writes."""
    title = report_title(run_dir)
    outcome = facts["outcome"]
    headline = lib.OUTCOME_HEADLINES.get(outcome, outcome)
    counts = facts["counts"]
    repo_file = run_dir / ".repo_url"
    repo_url = repo_file.read_text(encoding="utf-8").strip() if repo_file.is_file() else ""
    repo_web, branch = split_repo_url(repo_url) if repo_url else ("", "")
    figures = headline_figures(run_dir)
    images = [(f"figure{i}", path) for i, path in enumerate(figures, 1)]
    success = facts["success"]

    parts = [f'<div style="{FONT}; max-width: 700px; margin: 0 auto; color: #1a1a1a; line-height: 1.6;">']

    original = f" · {_link(issue_url, 'Original idea')}" if issue_url else ""
    parts.append(
        f'<div style="background: #f0f4f8; border-left: 4px solid #2563eb; padding: 16px 20px; margin-bottom: 24px;">'
        f'<h1 style="margin: 0 0 8px 0; font-size: 20px; color: #1e293b;">{_esc(title)}</h1>'
        f'<div style="font-size: 14px; color: #64748b;">Autonomous AI Safety Research Report · '
        f'{_esc(today.strftime("%-d %b %Y"))}{original}</div></div>')

    colours = ("#f0fdf4", "#bbf7d0") if success else ("#fef2f2", "#fecaca")
    finding = facts["findings"] or "The run's next-steps.md gives no one-line outcome."
    parts.append(
        f'<div style="background: {colours[0]}; border: 1px solid {colours[1]}; {BOX} font-size: 14px;">'
        f'<strong>Headline: the run {_esc(headline)}.</strong> {_esc(finding)}</div>')

    reasons = "".join(f"<li>{_esc(reason)}</li>" for reason in why)
    parts.append(
        f'<div style="background: #fffbeb; border: 1px solid #fde68a; {BOX} font-size: 14px;">'
        f'<strong>Written without a model.</strong> No model login could write this report, so it was '
        f'assembled from the run\'s saved files alone: the outcome the runner recorded, the experiments\' '
        f'verdicts and the proposed next steps. The paper and briefing in the repository have the full '
        f'detail.<ul style="margin: 8px 0 0 0; padding-left: 20px;">{reasons}</ul></div>')

    rows = [("Outcome", f"<code>{_esc(outcome)}</code>: {_esc(headline)}"),
            ("Experiments", _esc(lib.verdict_tally(counts) or "none ran"))]
    if facts["audit"]:
        rows.append(("Results audit", _esc(facts["audit"])))
    if repo_web:
        where = f"{repo_web}/tree/{branch}"
        rows.append(("Repo", _link(where, "GitHub") + (f" (branch {_esc(branch)})" if branch != "main" else "")))
        if facts["paper"]:
            rows.append(("Paper", _link(f"{repo_web}/blob/{branch}/paper/paper.pdf", "paper.pdf")))
    else:
        rows.append(("Repo", "not on GitHub: the results are only in the run directory"))
    table = "".join(f'<tr><td style="{KEY_CELL}">{key}</td><td style="padding: 4px 0;">{value}</td></tr>'
                    for key, value in rows)
    parts.append(
        f'<div style="background: #f8fafc; border: 1px solid #e2e8f0; {BOX}">'
        f'<h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">Bottom Line</h2>'
        f'<table style="border-collapse: collapse; width: 100%; font-size: 14px;">{table}</table></div>')

    for name, path in images:
        alt = f"Headline figure {path.stem}"
        parts.append(
            f'<div style="margin-bottom: 24px;"><img src="cid:{name}" alt="{_esc(alt)}" style="max-width:100%">'
            f'<p style="font-size: 13px; color: #475569; margin: 4px 0 0 0;">A headline figure of the paper '
            f'({_esc(path.relative_to(run_dir.resolve()))}); its caption in the paper says what it shows.</p></div>')

    experiments = facts["experiments"]
    if experiments:
        body = []
        for exp in experiments:
            notes = []
            if exp["preflight_failed"]:
                notes.append("pre-flight checks failed: " + ", ".join(exp["preflight_failed"]))
            if exp["note"]:
                notes.append(exp["note"])
            body.append(
                f'<tr><td style="{CELL}">{_esc(exp["id"])}</td><td style="{CELL}">{_esc(exp["component"])}</td>'
                f'<td style="{CELL}">{_badge(exp["verdict"])}</td><td style="{CELL}">{_esc("; ".join(notes))}</td></tr>')
        head = "".join(f'<th style="{HEAD_CELL}">{h}</th>' for h in ("#", "What was tested", "Result", "Note"))
        parts.append(
            f'<h2 style="{H2}">Results</h2><table style="border-collapse: collapse; width: 100%; font-size: 14px;'
            f' margin-bottom: 24px;"><thead><tr style="background: #f8fafc;">{head}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody></table>')

    caveats = facts["reasons"]
    if caveats:
        items = "".join(f'<li style="margin-bottom: 8px;">{_esc(reason)}</li>' for reason in caveats)
        parts.append(f'<div style="margin-bottom: 24px;"><h2 style="{H2}">Caveats</h2>'
                     f'<ol style="font-size: 14px; padding-left: 20px;">{items}</ol></div>')

    steps = facts["next_step_titles"]
    if steps:
        items = "".join(f'<li style="margin-bottom: 8px;">{_esc(step)}</li>' for step in steps)
        plan = (f' The full plan, with the cost of each step, is {_link(f"{repo_web}/blob/{branch}/next-steps.md", "next-steps.md")}.'
                if repo_web and facts["next_steps"] else "")
        next_steps = f'<ol style="font-size: 14px; padding-left: 20px; margin: 0;">{items}</ol>' \
                     f'<p style="font-size: 14px; margin: 12px 0 0 0;">The run ranks these steps in this order.{plan}</p>'
    else:
        next_steps = '<p style="font-size: 14px; margin: 0;">The run wrote no next-steps.md, so it proposes no next round.</p>'
    parts.append(f'<div style="background: #f0fdf4; border: 1px solid #bbf7d0; {BOX}">'
                 f'<h2 style="margin: 0 0 12px 0; font-size: 16px; color: #166534;">Proposed Next Steps</h2>'
                 f'{next_steps}</div>')

    commands = []
    if host_alias and host_alias != "local":
        commands.append(("Connect to the machine the run lives on:", f"ssh {host_alias}"))
    commands += [("Go to the plugin:", f"cd {plugin_dir}"), ("Start the agent:", agent_bin),
                 ("Run:", f"{continue_command} {run_dir}")]
    items = "".join(f'<li style="margin-bottom: 6px;">{_esc(label)} <code style="{CODE}">{_esc(command)}</code></li>'
                    for label, command in commands)
    parts.append(
        f'<div style="background: #f8fafc; border: 1px solid #e2e8f0; {BOX}">'
        f'<hr style="border: 0; border-top: 2px solid #e2e8f0; margin: 0 0 16px 0;">'
        f'<p style="font-size: 13px; color: #475569; margin: 0 0 8px 0;">Below this line needs no action. It is '
        f'the terminal route to continue the run yourself.</p>'
        f'<h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">How to Continue This Research</h2>'
        f'<ol style="font-size: 14px; padding-left: 20px; margin: 0 0 8px 0;">'
        f'<li style="margin-bottom: 6px;">Open a terminal.</li>{items}</ol>'
        f'<p style="font-size: 13px; color: #475569; margin: 8px 0 0 0;">That loads this run\'s proposed next '
        f'steps, lets you pick or edit one, and queues it as a follow-up run.</p></div>')

    if repo_web:
        links = [_link(f"{repo_web}/tree/{branch}", "GitHub repository") + " (code, paper and records)"]
        if facts["paper"]:
            links.append(_link(f"{repo_web}/blob/{branch}/paper/paper.pdf", "Paper (PDF)"))
        if (run_dir / "briefing.md").is_file():
            links.append(_link(f"{repo_web}/blob/{branch}/briefing.md", "Briefing") + " (the run's own summary)")
        items = "".join(f'<li style="margin-bottom: 4px;">{link}</li>' for link in links)
        parts.append(f'<div style="background: #f8fafc; border: 1px solid #e2e8f0; {BOX}">'
                     f'<h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">Links</h2>'
                     f'<ul style="list-style: none; padding: 0; margin: 0; font-size: 14px;">{items}</ul></div>')

    parts.append(f'<div style="font-size: 12px; color: #94a3b8; border-top: 1px solid #e2e8f0; padding-top: 12px;">'
                 f'Generated by the autonomous AI safety researcher agent · {_esc(agent_label)} · assembled without a'
                 f' model</div></div>')

    subject = f"[Auto-Research] {title} — {headline} — {lib.verdict_tally(counts) or 'none ran'}"
    return {"subject": subject, "html": "\n".join(parts) + "\n", "images": images}


def write_template(run_dir: Path, report: dict) -> None:
    """Write `report` (template_report) as the run's draft: email-draft.html, email-subject.txt and
    email-images.txt (NAME=run-relative path per figure; no file when there is none)."""
    (run_dir / "email-draft.html").write_text(report["html"], encoding="utf-8")
    (run_dir / "email-subject.txt").write_text(report["subject"] + "\n", encoding="utf-8")
    listing = run_dir / "email-images.txt"
    root = run_dir.resolve()
    if report["images"]:
        listing.write_text("".join(f"{name}={path.relative_to(root)}\n" for name, path in report["images"]),
                           encoding="utf-8")
    elif listing.exists():
        listing.unlink()


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_logins = sub.add_parser("logins", help="print the logins a model may write the report on, as JSON")
    p_logins.add_argument("--agent-usage", required=True, type=Path, help="the installed mailroom's agent-usage")

    p_template = sub.add_parser("template", help="write the run's report, assembled with no model, as its draft")
    p_template.add_argument("--run-dir", required=True, type=Path)
    p_template.add_argument("--issue-url", required=True, help="the original issue's address, or empty")
    p_template.add_argument("--host-alias", required=True, help="the run host's SSH alias, or local")
    p_template.add_argument("--plugin-dir", required=True)
    p_template.add_argument("--agent", required=True, help="the agent to start in the plugin directory")
    p_template.add_argument("--continue-command", required=True)
    p_template.add_argument("--agent-label", required=True)
    p_template.add_argument("--why", action="append", required=True, help="why no model wrote it (repeatable)")

    args = parser.parse_args(argv)
    if args.command == "logins":
        print(json.dumps(report_logins(args.agent_usage, dict(os.environ))))
        return 0

    facts = json.loads((args.run_dir / "run-outcome.json").read_text(encoding="utf-8"))
    report = template_report(args.run_dir, facts=facts, issue_url=args.issue_url, host_alias=args.host_alias,
                             plugin_dir=args.plugin_dir, agent_bin=args.agent, continue_command=args.continue_command,
                             agent_label=args.agent_label, why=args.why, today=date.today())
    write_template(args.run_dir, report)
    return 0


if __name__ == "__main__":
    sys.exit(main())

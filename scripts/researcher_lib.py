#!/usr/bin/env python3
"""Pure-logic helpers for the autonomous researcher wrapper (researcher-cron.sh).

The bash wrapper owns every side effect (gh, git, email). This module owns the
decisions that used to be made by ad-hoc grep/jq and got them wrong:

  state-field        one field of a state.md frontmatter
  terminal-statuses  the workflow statuses that end a run
  backends           the agent backends a run can use
  status-label       a backend's researching / processed issue label
  research-ideas-label  the label that queues an issue as a research idea
  pick               which queued issue to run, refusing duplicates
  claimed            whether a freshly read issue is claimed or closed
  find-followup      the oldest issue already filed with a follow-up key
  followup-issue     the title, body, key and label of a new follow-up issue
  followup-meta      the follow-up fields of a picked issue
  slug               a topic as a run-id or repo-name fragment
  outcome            the run's final status, derived from what actually exists:
                     did the workflow finish, are there valid results, did the
                     push land
  issue-comment      the findings comment posted back to the originating issue
  html-text          the plain-text part of the results email, from its HTML
  email-images       the inline plots the email names (email-images.txt), checked

Standard library only: it runs under whatever python3 cron finds.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

# The agent backends a run can use (RESEARCHER_BACKEND). Each one labels the
# issues it works on with status_label(). A backend added here also needs a branch
# in the `case "$BACKEND"` statements of scripts/researcher-cron.sh (its settings)
# and scripts/runner/provider.sh (how it is invoked).
BACKENDS = ("claude", "codex")
LABEL_STATES = ("researching", "processed")


def status_label(backend: str, state: str) -> str:
    """The issue label marking `backend` as researching or having processed an issue."""
    if backend not in BACKENDS or state not in LABEL_STATES:
        raise ValueError(f"no status label for backend {backend!r} in state {state!r}")
    return f"status:{backend}-{state}"


# The label that puts an issue in the queue of research ideas.
RESEARCH_IDEAS_LABEL = "list:research-ideas"
RESEARCHING_LABELS = tuple(status_label(backend, "researching") for backend in BACKENDS)
BUSY_LABELS = RESEARCHING_LABELS + tuple(status_label(backend, "processed") for backend in BACKENDS)
FOLLOWUP_LABEL = "type:follow-up"
FOLLOWUP_KEY_RE = re.compile(r"<!--\s*followup-key:\s*([0-9a-f]{8,64})\s*-->")
FOLLOWUP_TITLE_PREFIX = "[Follow-up] "
FOLLOWUP_TITLE_LENGTH = 70
# The follow-up issue footer: a "---" line, then this line, then the key marker.
FOLLOWUP_FOOTER = "Parent: #{parent} | Repo: {repo} | Run: {run}"
FOLLOWUP_FOOTER_RE = re.compile(r"^Parent:\s*#?(?P<parent>\d*)\s*\|\s*Repo:\s*(?P<repo>\S*)\s*\|\s*Run:\s*(?P<run>\S*)\s*$")

# Workflow statuses after which a run is finished and never auto-resumed.
TERMINAL_STATUSES = ("complete", "failed", "timed_out")

# GitHub repository visibilities; researcher-cron.sh checks RESEARCHER_REPO_VISIBILITY
# against the same list.
REPO_VISIBILITIES = ("private", "internal", "public")

VALID_VERDICTS = ("PASS", "FAIL", "MIXED")
# Final outcomes that count as a finished, usable run (the wrapper exits 0).
SUCCESS_OUTCOMES = ("complete", "complete-local")


def log(message: str) -> None:
    print(message, file=sys.stderr)


# --------------------------------------------------------------------------
# state.md frontmatter
# --------------------------------------------------------------------------

_DOUBLE_QUOTED_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$')
_SINGLE_QUOTED_RE = re.compile(r"^'((?:[^']|'')*)'\s*(?:#.*)?$")


def _scalar(raw: str) -> str:
    """The value of a one-line YAML scalar: quotes removed (with \\" and \\\\
    unescaped inside double quotes) and a trailing comment dropped. Text that is
    not a well-formed quoted scalar is taken as written, without its comment."""
    raw = raw.strip()
    double = _DOUBLE_QUOTED_RE.match(raw)
    if double:
        return re.sub(r'\\(["\\])', r"\1", double.group(1))
    single = _SINGLE_QUOTED_RE.match(raw)
    if single:
        return single.group(1).replace("''", "'")
    return re.sub(r"(^|\s+)#.*$", "", raw)


def read_frontmatter(path: Path) -> dict[str, str]:
    """Return the scalar `key: value` pairs of a state.md YAML frontmatter.

    Values are read as YAML scalars (see _scalar); the first occurrence of a
    key wins, and nothing after the closing `---` is read. Deliberately not a
    YAML parser: state.md is rewritten by models and is not always valid YAML,
    but the scalar keys the wrapper relies on always sit on their own line.
    A file with no frontmatter has no fields; one that cannot be read raises
    OSError.
    """
    fields: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines or lines[0].strip() != "---":
        return fields
    for line in lines[1:]:
        if line.strip() == "---":
            break
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
        if match:
            fields.setdefault(match.group(1), _scalar(match.group(2)))
    return fields


def local_runs(output_dir: Path) -> list[dict[str, str]]:
    """The frontmatter fields of each run under `output_dir` (each `*/state.md`),
    plus `_dir`, the run directory. A state.md with no frontmatter fields is
    reported on stderr: nothing ties it to an issue, so pick_issue cannot count
    it as a duplicate. Raises OSError when a state.md cannot be read."""
    runs = []
    if not output_dir.is_dir():
        return runs
    for state in sorted(output_dir.glob("*/state.md")):
        fields = read_frontmatter(state)
        if not fields:
            log(f"WARN: {state} has no frontmatter; it is not counted when checking for duplicate runs")
        fields["_dir"] = str(state.parent)
        runs.append(fields)
    return runs


# --------------------------------------------------------------------------
# Follow-up identity
# --------------------------------------------------------------------------

def compute_followup_key(body: str) -> str:
    """Hash of a follow-up body with the key marker removed, whitespace-normalised."""
    text = FOLLOWUP_KEY_RE.sub("", body or "")
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    normalised = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()[:16]


def followup_key(body: str) -> str:
    """The key recorded in the body if there is one, else the computed key.

    Preferring the recorded marker keeps the identity stable if someone edits
    the issue text after it was filed.
    """
    match = FOLLOWUP_KEY_RE.search(body or "")
    return match.group(1) if match else compute_followup_key(body)


def followup_issue(feedback: str, *, parent: str, repo_url: str, run_id: str) -> dict[str, str]:
    """The title, body, follow-up key and label (FOLLOWUP_LABEL) of a new follow-up issue.

    The title is the prefix and the first line of `feedback`, cut to
    FOLLOWUP_TITLE_LENGTH characters. The body is the feedback, then (when any of
    parent, repo_url and run_id is given) a `---` line and the footer, then the
    key marker. followup_meta() reads the footer back.
    """
    feedback = feedback.rstrip("\n")
    body = feedback
    if parent or repo_url or run_id:
        body += "\n\n---\n" + FOLLOWUP_FOOTER.format(parent=parent, repo=repo_url, run=run_id)
    key = compute_followup_key(body)
    return {
        "title": FOLLOWUP_TITLE_PREFIX + feedback.split("\n", 1)[0][:FOLLOWUP_TITLE_LENGTH],
        "body": f"{body}\n<!-- followup-key: {key} -->",
        "key": key,
        "label": FOLLOWUP_LABEL,
    }


def followup_meta(issue: dict) -> dict:
    """The follow-up fields of an issue (gh JSON with title, body and labels).

    is_followup is whether it carries FOLLOWUP_LABEL. For a follow-up, title is
    the issue title without FOLLOWUP_TITLE_PREFIX; parent_issue, prior_repo and
    prior_run_id come from the last footer line (empty when there is none); and
    feedback is the body before that footer's `---` line, or the whole body
    without the key marker when there is no footer. A `---` inside the feedback
    stays in it.
    """
    meta = {"is_followup": is_followup(issue), "title": "", "parent_issue": "", "prior_repo": "",
            "prior_run_id": "", "feedback": ""}
    if not meta["is_followup"]:
        return meta
    title = issue.get("title") or ""
    if title.startswith(FOLLOWUP_TITLE_PREFIX.rstrip()):
        title = title[len(FOLLOWUP_TITLE_PREFIX.rstrip()):].lstrip()
    meta["title"] = title
    lines = FOLLOWUP_KEY_RE.sub("", issue.get("body") or "").replace("\r\n", "\n").rstrip().split("\n")
    feedback_end = len(lines)
    for index in range(len(lines) - 1, -1, -1):
        footer = FOLLOWUP_FOOTER_RE.match(lines[index])
        if footer:
            meta.update(parent_issue=footer["parent"], prior_repo=footer["repo"], prior_run_id=footer["run"])
            feedback_end = index - 1 if index > 0 and lines[index - 1].strip() == "---" else index
            break
    meta["feedback"] = "\n".join(lines[:feedback_end]).strip()
    return meta


# --------------------------------------------------------------------------
# Issue picking
# --------------------------------------------------------------------------

def label_names(issue: dict) -> set[str]:
    return {label.get("name", "") for label in issue.get("labels") or []}


def is_followup(issue: dict) -> bool:
    return FOLLOWUP_LABEL in label_names(issue)


def claim_labels(*, explicit: bool) -> tuple[str, ...]:
    """The labels that keep an issue from being claimed for a new run.

    Any backend researching it always does. In queue mode a backend having
    processed it does too; an explicit request (RESEARCHER_ISSUE) may re-run a
    finished issue.
    """
    return RESEARCHING_LABELS if explicit else BUSY_LABELS


def claimed_reason(issue: dict, *, explicit: bool) -> str:
    """Why `issue` (gh JSON with state and labels) may not be claimed, or "" when it may.

    Raises KeyError when the JSON has no state.
    """
    if issue["state"] != "OPEN":
        return issue["state"].lower()
    held = sorted(label_names(issue) & set(claim_labels(explicit=explicit)))
    return f"labelled {', '.join(held)}" if held else ""


def pick_issue(issues: list[dict], runs: list[dict[str, str]], *,
               explicit: bool = False, allow_rerun: bool = False) -> dict | None:
    """Return the first issue that is safe to run, or None.

    Queue mode (explicit=False) skips anything claimed or processed by any
    backend, anything that already has a run directory on this machine, and any
    follow-up whose request (follow-up key) is already claimed, processed, run
    locally, or filed again under a lower issue number.

    Explicit mode (RESEARCHER_ISSUE) is a deliberate request: it refuses only an
    issue that some backend is researching right now, or one with a run already
    in progress here, and otherwise allows a re-run.
    """
    runs_by_issue: dict[str, list[dict[str, str]]] = {}
    runs_by_key: dict[str, list[dict[str, str]]] = {}
    for run in runs:
        runs_by_issue.setdefault(run.get("issue_number", ""), []).append(run)
        if run.get("followup_key"):
            runs_by_key.setdefault(run["followup_key"], []).append(run)

    keys = {issue["number"]: followup_key(issue.get("body") or "")
            for issue in issues if is_followup(issue)}

    for issue in issues:
        number = issue["number"]
        held = sorted(label_names(issue) & set(claim_labels(explicit=explicit)))
        prior = runs_by_issue.get(str(number), [])

        if explicit:
            if held:
                log(f"skip #{number}: already being researched ({', '.join(held)})")
                continue
            active = [r for r in prior if r.get("status") not in TERMINAL_STATUSES]
            if active:
                log(f"skip #{number}: a run is already in progress in {active[0]['_dir']}")
                continue
            if prior:
                log(f"WARN: #{number} was already run here ({', '.join(r['_dir'] for r in prior)}); re-running because it was requested explicitly")
        else:
            if held:
                continue
            if prior and not allow_rerun:
                log(f"skip #{number}: already has a local run ({prior[0]['_dir']}, status {prior[0].get('status', '?')}). "
                    f"Re-run deliberately with RESEARCHER_ISSUE={number}.")
                continue

        if number in keys and not (explicit or allow_rerun):
            key = keys[number]
            duplicate = None
            for other in issues:
                other_number = other["number"]
                if other_number == number or keys.get(other_number) != key:
                    continue
                if label_names(other) & set(BUSY_LABELS):
                    duplicate = f"same follow-up request as #{other_number}, which is already claimed or processed"
                    break
                if other_number < number:
                    duplicate = f"same follow-up request as earlier issue #{other_number}"
                    break
            if duplicate is None and key in runs_by_key:
                duplicate = f"same follow-up request already run locally in {runs_by_key[key][0]['_dir']}"
            if duplicate:
                log(f"skip #{number}: duplicate follow-up ({duplicate})")
                continue

        picked = dict(issue)
        if number in keys:
            picked["followup_key"] = keys[number]
        return picked
    return None


# --------------------------------------------------------------------------
# Run and repo names
# --------------------------------------------------------------------------

def slugify(text: str, max_length: int, *, word_boundary: bool) -> str:
    """`text` lower-cased, with each run of characters other than a-z and 0-9
    turned into one hyphen, no hyphen at either end, and at most `max_length`
    characters. With word_boundary, a cut also drops the partial word it leaves."""
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(slug) <= max_length:
        return slug
    cut = slug[:max_length]
    if word_boundary and slug[max_length] != "-" and "-" in cut:
        cut = cut[:cut.rindex("-")]
    return cut.rstrip("-")


# --------------------------------------------------------------------------
# Results and outcome
# --------------------------------------------------------------------------

def _section(text: str, heading: str) -> str:
    """Body of the first markdown section whose heading starts with `heading`."""
    pattern = re.compile(rf"^#+\s*{re.escape(heading)}\b.*$", re.IGNORECASE | re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return ""
    rest = text[match.end():]
    end = re.search(r"^#+\s", rest, re.MULTILINE)
    return (rest[:end.start()] if end else rest).strip()


_VERDICT_LINE_RE = re.compile(r"^\s*(?:#+\s*|\*\*)?Verdict\b[^\S\n]*:?[^\S\n]*\**[^\S\n]*(.*)$", re.IGNORECASE | re.MULTILINE)


def _classify_verdict_line(line: str) -> str:
    if line.lstrip("*` ").startswith("<"):
        return "UNKNOWN"  # an unfilled template placeholder, e.g. "<PASS | FAIL>"
    upper = line.upper()
    words = re.findall(r"[A-Z]+", upper)
    if not words:
        return "UNKNOWN"
    first = words[0]
    if first == "FAIL" and "AFFORDAB" in upper:
        # FAIL-on-affordability: the experiment could not run under the
        # compute profile. That is not evidence about the hypothesis.
        return "INCONCLUSIVE"
    if first in ("INCONCLUSIVE", "INVALID"):
        return "INCONCLUSIVE"
    if first in ("PARTIAL", "MIXED"):
        return "MIXED"
    if first in ("PASS", "FAIL"):
        return first
    return "UNKNOWN"


def parse_verdict(text: str) -> str:
    """Normalise a results.md verdict to PASS / FAIL / MIXED / INCONCLUSIVE / UNKNOWN.

    Takes the first "Verdict" line that carries a recognisable verdict, so a
    heading such as "### Verdict rationale" before the real line is skipped.
    """
    for match in _VERDICT_LINE_RE.finditer(text):
        line = match.group(1).strip()
        if not line:
            # "## Verdict" heading with the verdict on the next non-empty line
            after = text[match.end():].lstrip().splitlines()
            line = after[0] if after else ""
        verdict = _classify_verdict_line(line)
        if verdict != "UNKNOWN" or line.lstrip("*` ").startswith("<"):
            return verdict
    return "UNKNOWN"


def parse_preflight(path: Path) -> dict[str, str]:
    """Map check name -> PASS/FAIL/WARN/N/A from a preflight.md table. Raises
    OSError when the file cannot be read."""
    checks: dict[str, str] = {}
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        cells = [cell.strip().strip("`*") for cell in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        status = cells[1].upper().replace(" ", "")
        if status in ("PASS", "FAIL", "WARN", "N/A", "NA"):
            checks[cells[0].lower()] = "N/A" if status == "NA" else status
    return checks


def scan_experiments(run_dir: Path) -> list[dict]:
    """This run's experiments (never prior/), with verdict and pre-flight state."""
    experiments = []
    for exp_dir in sorted((run_dir / "experiments").glob("exp-*")):
        if not exp_dir.is_dir():
            continue
        results = exp_dir / "results.md"
        if not results.is_file():
            continue
        text = results.read_text(encoding="utf-8", errors="replace")
        component = _section(text, "Component Tested").splitlines()
        stated = parse_verdict(text)
        preflight_file = exp_dir / "preflight.md"
        preflight = parse_preflight(preflight_file) if preflight_file.is_file() else None
        failed_checks = sorted(k for k, v in (preflight or {}).items() if v == "FAIL")
        if preflight is None:
            preflight_state = "missing"
        elif not preflight:
            # A file with no readable check rows proves nothing; do not let it
            # pass as a clean pre-flight.
            preflight_state = "unreadable"
        else:
            preflight_state = "fail" if failed_checks else "ok"
        verdict = stated
        note = ""
        if failed_checks and stated in VALID_VERDICTS:
            # A verdict produced by a pipeline that failed its own pre-flight
            # gate says nothing about the hypothesis (tasks#1863).
            verdict = "INCONCLUSIVE"
            note = f"stated {stated}, but pre-flight failed: {', '.join(failed_checks)}"
        experiments.append({
            "id": exp_dir.name,
            "component": component[0].strip() if component else "",
            "stated_verdict": stated,
            "verdict": verdict,
            "preflight": preflight_state,
            "preflight_failed": failed_checks,
            "note": note,
        })
    return experiments


def first_bold_field(text: str, field: str) -> str:
    match = re.search(rf"^\*\*{re.escape(field)}\*\*\s*:\s*(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def next_step_titles(run_dir: Path, limit: int = 4) -> list[str]:
    path = run_dir / "next-steps.md"
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    ranked = _section(text, "Ranked Next Steps") or text
    titles = re.findall(r"^###\s*\d+\.\s*(.+)$", ranked, re.MULTILINE)
    return [t.strip() for t in titles[:limit]]


def audit_summary(run_dir: Path) -> str:
    path = run_dir / "audit" / "results-audit.md"
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace")
    disposition = re.search(r"Overall disposition\s*:\s*([A-Z_-]+)", text)
    reason = re.search(r"audit_exit_reason\s*:\s*([^\n]+)", text)
    if not disposition:
        return ""
    summary = disposition.group(1)
    if reason:
        summary += f" ({reason.group(1).strip().strip('#').strip()})"
    return summary


def compute_outcome(run_dir: Path, *, status: str, timed_out: bool, publish_state: str,
                    publish_error: str = "", paused: bool = False, notes: list[str] | None = None) -> dict:
    """Decide the run's final outcome from what actually exists on disk.

    complete        workflow finished, valid results, pushed and verified
    complete-local  as complete, but publishing was deliberately skipped
    unpublished     workflow finished with valid results, but the push failed
    no-results      workflow finished, but no experiment produced a valid verdict
    partial         workflow stopped early (timeout / failure) with some valid results
    failed          workflow stopped early with no valid results
    paused          provider usage limit; resumable, nothing published

    `success` is whether the outcome is one of SUCCESS_OUTCOMES. The result also
    carries what the reports quote from the run directory: the `**Outcome**`
    line of next-steps.md (`findings`), its ranked step titles and the results
    audit's disposition (`audit`), each empty when the file is missing. Reads
    the run directory; writes nothing.
    """
    experiments = scan_experiments(run_dir)
    counts: dict[str, int] = {}
    for exp in experiments:
        counts[exp["verdict"]] = counts.get(exp["verdict"], 0) + 1
    valid = sum(counts.get(v, 0) for v in VALID_VERDICTS)
    theory_only = not experiments and (run_dir / "rethink-rationale.md").is_file()
    has_results = valid > 0 or (theory_only and status == "complete")
    finished = status == "complete"

    reasons: list[str] = []
    if paused:
        outcome = "paused"
        reasons.append("provider usage limit reached; the run is resumable")
    elif not has_results:
        outcome = "no-results" if finished else "failed"
        if not experiments:
            reasons.append("no experiment produced a results.md")
        else:
            reasons.append(f"none of {len(experiments)} experiment(s) produced a valid PASS/FAIL verdict")
    elif not finished:
        outcome = "partial"
    elif publish_state == "pushed":
        outcome = "complete"
    elif publish_state == "skipped":
        outcome = "complete-local"
    else:
        outcome = "unpublished"

    if timed_out:
        if finished:
            reasons.append("hit the run timeout after experiments; the results audit was skipped")
        else:
            reasons.append("hit the run timeout before the workflow finished")
    elif not finished and not paused:
        reasons.append(f"workflow stopped with status '{status}'")
    if publish_state == "failed" and not paused:
        reasons.append(f"not on GitHub: {publish_error or 'push failed'}")
    if counts.get("INCONCLUSIVE"):
        reasons.append(f"{counts['INCONCLUSIVE']} experiment(s) inconclusive (pre-flight failed or invalid measurement)")
    if counts.get("UNKNOWN"):
        reasons.append(f"{counts['UNKNOWN']} experiment(s) without a '## Verdict: PASS|FAIL|INCONCLUSIVE' line")
    unchecked = [e["id"] for e in experiments if e["preflight"] == "missing"]
    if unchecked:
        reasons.append(f"no pre-flight record for {', '.join(unchecked)}")
    unreadable = [e["id"] for e in experiments if e["preflight"] == "unreadable"]
    if unreadable:
        reasons.append(f"pre-flight record has no readable check table for {', '.join(unreadable)}")
    if theory_only and has_results:
        reasons.append("theory-only negative result (no experiments were run)")
    reasons.extend(notes or [])

    next_steps_file = run_dir / "next-steps.md"
    findings = ""
    if next_steps_file.is_file():
        findings = first_bold_field(next_steps_file.read_text(encoding="utf-8", errors="replace"), "Outcome")

    return {
        "outcome": outcome,
        "success": outcome in SUCCESS_OUTCOMES,
        "reasons": reasons,
        "has_results": has_results,
        "workflow_finished": finished,
        "status": status,
        "timed_out": timed_out,
        "publish_state": publish_state,
        "counts": counts,
        "experiments": experiments,
        "paper": (run_dir / "paper" / "paper.pdf").is_file(),
        "next_steps": next_steps_file.is_file(),
        "findings": findings,
        "next_step_titles": next_step_titles(run_dir),
        "audit": audit_summary(run_dir),
    }


OUTCOME_HEADLINES = {
    "complete": "complete",
    "complete-local": "complete (not published by request)",
    "unpublished": "finished but NOT PUBLISHED",
    "no-results": "finished with NO VALID RESULTS",
    "partial": "stopped early (partial results)",
    "failed": "FAILED",
    "paused": "paused",
}


def issue_comment(facts: dict, *, run_dir: Path, run_id: str, repo_web: str, branch: str,
                  agent_label: str, host: str, is_followup: bool, visibility: str) -> str:
    """The findings comment for the run's issue, in Markdown, formatted from
    `facts` (compute_outcome's result) and the publication details alone; it
    reads no files. `run_dir` is named as the results' location when nothing was
    published."""
    outcome = facts["outcome"]
    lines = [
        f"<!-- researcher-run: {run_id} outcome: {outcome} -->",
        f"### Autonomous research run: {OUTCOME_HEADLINES.get(outcome, outcome)}",
        "",
    ]
    counts = facts["counts"]
    tally = ", ".join(f"{counts[v]} {v.lower()}" for v in ("PASS", "FAIL", "MIXED", "INCONCLUSIVE", "UNKNOWN") if counts.get(v))
    lines.append(f"**Outcome:** `{outcome}`" + (f" — experiments: {tally}" if tally else ""))
    for reason in facts["reasons"]:
        lines.append(f"- {reason}")
    lines.append("")

    lines.append("| | |")
    lines.append("|---|---|")
    if repo_web:
        label = "Branch" if is_followup else "Repo"
        lines.append(f"| {label} | {repo_web}/tree/{branch} ({visibility}) |")
        if facts["paper"]:
            lines.append(f"| Paper | {repo_web}/blob/{branch}/paper/paper.pdf |")
        if facts["next_steps"]:
            lines.append(f"| Next steps | {repo_web}/blob/{branch}/next-steps.md |")
    else:
        where = f"`{host}:{run_dir}`" if host and host != "local" else f"`{run_dir}`"
        lines.append(f"| Results | not on GitHub; local only at {where} |")
    lines.append(f"| Run | `{run_id}` ({agent_label}) |")
    lines.append("")

    if facts["findings"] or facts["experiments"]:
        lines.append("**Findings**")
        if facts["findings"]:
            lines.append("")
            lines.append(facts["findings"])
        if facts["experiments"]:
            lines.append("")
            lines.append("| Experiment | Component | Verdict |")
            lines.append("|---|---|---|")
            for exp in facts["experiments"][:12]:
                component = (exp["component"] or "—").replace("|", "/")
                if len(component) > 90:
                    component = component[:87] + "..."
                verdict = exp["verdict"]
                if exp["note"]:
                    verdict += f" ({exp['note']})"
                lines.append(f"| {exp['id']} | {component} | {verdict} |")
        if facts["audit"]:
            lines.append("")
            lines.append(f"Results audit: {facts['audit']}")
        lines.append("")

    if facts["next_step_titles"]:
        lines.append("**Proposed next steps**")
        for index, title in enumerate(facts["next_step_titles"], 1):
            lines.append(f"{index}. {title}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


# --------------------------------------------------------------------------
# The results email (sent by send-results-email.sh through agent-mail)
# --------------------------------------------------------------------------

class _Text(HTMLParser):
    BLOCK = {"p", "div", "br", "table", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote",
             "hr", "section"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script", "head", "title"):
            self.skip += 1
        elif tag == "li":
            self.parts.append("\n- ")
        elif tag == "tr":
            self.parts.append("\n")
        elif tag in ("td", "th"):
            self.parts.append(" | ")
        elif tag == "img":
            alt = dict(attrs).get("alt")
            if alt:
                self.parts.append("[%s]" % alt)
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("style", "script", "head", "title"):
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(re.sub(r"\s+", " ", data))


def html_to_text(markup: str) -> str:
    """A readable plain-text alternative of an HTML email: blocks on their own lines, list items as bullets,
    table cells separated by |, blank runs collapsed."""
    parser = _Text()
    parser.feed(markup)
    parser.close()
    lines = [line.strip(" |").strip() for line in html.unescape("".join(parser.parts)).splitlines()]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return text + "\n"


IMAGE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".webp")


def email_images(run_dir: Path) -> tuple[list[str], list[str]]:
    """(NAME=PATH arguments for agent-mail --image, problems) from <run>/email-images.txt, one NAME=relative/path
    per line. A line is dropped, with the reason, unless the name is plain, the file is an image inside the run
    directory, and the HTML places it (src="cid:NAME")."""
    listing = run_dir / "email-images.txt"
    if not listing.is_file():
        return [], []
    root = run_dir.resolve()
    draft = run_dir / "email-draft.html"
    markup = draft.read_text(encoding="utf-8", errors="replace") if draft.is_file() else ""
    out, problems, seen = [], [], set()
    for raw in listing.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, sep, rel = line.partition("=")
        name, rel = name.strip(), rel.strip()
        path = (run_dir / rel).resolve() if sep and rel else None
        if not sep or not IMAGE_NAME.match(name):
            problems.append(f"{line!r}: not NAME=relative/path.png with a plain name")
        elif name in seen:
            problems.append(f"{name}: listed twice")
        elif path is None or not path.is_relative_to(root) or not path.is_file():
            problems.append(f"{name}: {rel} is not a file in the run directory")
        elif path.suffix.lower() not in IMAGE_SUFFIXES:
            problems.append(f"{name}: {rel} is not a PNG, JPEG, GIF or WebP image")
        elif f"cid:{name}" not in markup:
            problems.append(f"{name}: email-draft.html does not place it (<img src=\"cid:{name}\">)")
        else:
            seen.add(name)
            out.append(f"{name}={path}")
    return out, problems


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_field = sub.add_parser("state-field", help="print one frontmatter field of a state.md (an empty line if absent)")
    p_field.add_argument("file", type=Path)
    p_field.add_argument("key")

    sub.add_parser("terminal-statuses", help="print the workflow statuses that end a run, space-separated")
    sub.add_parser("backends", help="print the agent backends, space-separated")
    sub.add_parser("research-ideas-label", help="print the label that queues an issue as a research idea")

    p_label = sub.add_parser("status-label", help="print a backend's issue status label")
    p_label.add_argument("backend", choices=BACKENDS)
    p_label.add_argument("state", choices=LABEL_STATES)

    p_pick = sub.add_parser("pick", help="read issues JSON on stdin, print the issue to run (or nothing)")
    p_pick.add_argument("--output-dir", required=True, type=Path)
    p_pick.add_argument("--explicit", action="store_true")
    p_pick.add_argument("--allow-rerun", action="store_true")

    p_claimed = sub.add_parser("claimed", help="read one issue's JSON (state, labels) on stdin, print why it may "
                                               "not be claimed, or nothing when it may")
    p_claimed.add_argument("--explicit", action="store_true", help="an explicit request (RESEARCHER_ISSUE)")

    p_new = sub.add_parser("followup-issue", help="print the title, body, key and label of a new follow-up issue as JSON")
    p_new.add_argument("--feedback-file", required=True, type=Path)
    p_new.add_argument("--parent", required=True, help="parent issue number, or empty")
    p_new.add_argument("--repo-url", required=True, help="the prior run's repo URL, or empty")
    p_new.add_argument("--run-id", required=True, help="the prior run's id, or empty")

    sub.add_parser("followup-meta", help="read one issue's JSON on stdin, print its follow-up fields as JSON")

    p_slug = sub.add_parser("slug", help="print TEXT as a slug of at most --max-length characters")
    p_slug.add_argument("--max-length", required=True, type=int)
    p_slug.add_argument("--word-boundary", action="store_true", help="drop a partial word left by the cut")
    p_slug.add_argument("text")

    p_find = sub.add_parser("find-followup", help="read issues JSON on stdin, print '<number> <url>' of the oldest with this key")
    p_find.add_argument("--key", required=True)

    p_text = sub.add_parser("html-text", help="print the plain-text version of an HTML file")
    p_text.add_argument("file", type=Path)

    p_img = sub.add_parser("email-images", help="print checked NAME=PATH lines from <run>/email-images.txt; exit 1, listing "
                           "the problems on stderr, when any line is invalid")
    p_img.add_argument("--run-dir", required=True, type=Path)

    for name in ("outcome", "issue-comment"):
        p = sub.add_parser(name)
        p.add_argument("--run-dir", required=True, type=Path)
        p.add_argument("--status", required=True)
        p.add_argument("--timed-out", default="false")
        p.add_argument("--publish-state", required=True, choices=("pushed", "failed", "skipped"))
        p.add_argument("--publish-error", default="")
        p.add_argument("--paused", default="false")
        p.add_argument("--note", action="append", default=[], help="a wrapper caveat to report (repeatable)")
        if name == "issue-comment":
            p.add_argument("--run-id", required=True)
            p.add_argument("--repo-web", default="")
            p.add_argument("--branch", required=True, help="the branch the results were pushed to")
            p.add_argument("--agent-label", default="")
            p.add_argument("--host", default="")
            p.add_argument("--followup", default="false")
            p.add_argument("--visibility", required=True, choices=REPO_VISIBILITIES)

    args = parser.parse_args(argv)
    truthy = ("1", "true", "yes", "on")

    if args.command == "state-field":
        if not args.file.is_file():
            parser.error(f"no such state file: {args.file}")
        print(read_frontmatter(args.file).get(args.key, ""))
        return 0

    if args.command == "terminal-statuses":
        print(" ".join(TERMINAL_STATUSES))
        return 0

    if args.command == "backends":
        print(" ".join(BACKENDS))
        return 0

    if args.command == "research-ideas-label":
        print(RESEARCH_IDEAS_LABEL)
        return 0

    if args.command == "status-label":
        print(status_label(args.backend, args.state))
        return 0

    if args.command == "claimed":
        reason = claimed_reason(json.load(sys.stdin), explicit=args.explicit)
        if reason:
            print(reason)
        return 0

    if args.command == "followup-issue":
        print(json.dumps(followup_issue(args.feedback_file.read_text(encoding="utf-8"), parent=args.parent,
                                        repo_url=args.repo_url, run_id=args.run_id)))
        return 0

    if args.command == "followup-meta":
        print(json.dumps(followup_meta(json.load(sys.stdin))))
        return 0

    if args.command == "slug":
        print(slugify(args.text, args.max_length, word_boundary=args.word_boundary))
        return 0

    if args.command == "pick":
        payload = json.load(sys.stdin)
        issues = payload if isinstance(payload, list) else [payload]
        picked = pick_issue(issues, local_runs(args.output_dir),
                            explicit=args.explicit, allow_rerun=args.allow_rerun)
        if picked is not None:
            print(json.dumps(picked))
        return 0

    if args.command == "find-followup":
        raw = sys.stdin.read().strip()
        matches = sorted((issue for issue in (json.loads(raw) if raw else [])
                          if followup_key(issue.get("body") or "") == args.key),
                         key=lambda issue: issue["number"])
        if matches:
            print(f"{matches[0]['number']} {matches[0].get('url', '')}".rstrip())
        return 0

    if args.command == "html-text":
        print(html_to_text(args.file.read_text(encoding="utf-8", errors="replace")), end="")
        return 0

    if args.command == "email-images":
        images, problems = email_images(args.run_dir)
        if problems:
            for problem in problems:
                print(f"error: email-images.txt: {problem}", file=sys.stderr)
            return 1
        for image in images:
            print(image)
        return 0

    facts = compute_outcome(args.run_dir, status=args.status,
                            timed_out=args.timed_out.lower() in truthy,
                            publish_state=args.publish_state,
                            publish_error=args.publish_error,
                            paused=args.paused.lower() in truthy,
                            notes=args.note)
    if args.command == "outcome":
        print(json.dumps(facts))
        return 0

    print(issue_comment(facts, run_dir=args.run_dir, run_id=args.run_id, repo_web=args.repo_web,
                        branch=args.branch, agent_label=args.agent_label, host=args.host,
                        is_followup=args.followup.lower() in truthy, visibility=args.visibility), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())

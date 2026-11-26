#!/usr/bin/env python3
"""Independent scientific review and verification of versioned research plans.

Usage:
  methods_review.py plan|presentation RUN [--new-cycle REASON]
  methods_review.py evidence|approve-auto|verify|verify-evidence|verify-presentation RUN
  methods_review.py approve-human RUN REVISION
  methods_review.py respond RUN STAGE FINDING fixed|limit|declined NOTE

The hub calls the review actions; verify actions are offline. Decisions use exit 0
(approved), 3 (revision requested), or 4 (stop); a review asks for revision only
for an open blocking finding. Exit 5 means a capped stage (plan, presentation) has
had RESEARCHER_MAX_REVIEW_ROUNDS rounds in its current cycle: no review ran, and
the last reviewed revision is printed. Errors use exit 1. Each stage keeps a
review ledger (review_ledger.py) that every later round of it sees; respond
records the hub's answer to one finding. All completed design critiques are
returned to the approver, including objections. Evidence objections are returned
to the auditor for disposition.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from researcher_files import digest, file_digest, write_json
from researcher_lib import RUN_CONFIG_FILE, log, read_frontmatter
from review_ledger import DISPOSITIONS, RECEIPT_FINDING_KEYS, STAGES, Ledger

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "templates" / "review"
ROLES = ("assumption-challenger", "mentor-review", "pre-mortem")
EXIT = {"approve": 0, "revise": 3, "stop": 4}
ROUND_CAP_EXIT = 5
MODEL_KEY = "RESEARCHER_REVIEW_MODEL"
EFFORT_KEY = "RESEARCHER_REVIEW_REASONING"
ROUNDS_KEY = "RESEARCHER_MAX_REVIEW_ROUNDS"
# Stages whose loop only the hub ends get a round cap per cycle. The evidence
# critic runs once per audit round, which RESEARCHER_MAX_AUDIT_ROUNDS caps, and
# the automatic approver allows one design revision (WORKFLOW.md Step 8).
CAPPED_STAGES = ("plan", "presentation")
# The ledgers each stage's reviewers see: their own, and the one the stage builds on.
CONTEXT_STAGES = {"plan": ("plan",), "approval": ("plan", "approval"),
                  "evidence": ("evidence",), "presentation": ("evidence", "presentation")}
# A reviewer gets both ends of a long log, with the omission explicitly marked.
# The receipt fingerprints all its bytes. Active re-execution belongs to the auditor.
LOG_EXCERPT_BYTES = 32768


def json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode()


def string_list(value, label: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
        raise ValueError(f"{label}: expected an array of nonempty strings")
    return value


@dataclass
class Packet:
    """The exact evidence shown to one review, plus full source fingerprints."""
    documents: dict[str, str]
    hashes: dict[str, str]
    figures: list[Path]

    def add(self, run: Path, name: str) -> None:
        path = run / name
        if not path.resolve().is_relative_to(run) or not path.is_file():
            raise ValueError(f"missing or external review input: {name}")
        with path.open("rb") as source:
            if path.suffix.lower() in {".png", ".jpg", ".jpeg"} or path.name == "run.log":
                self.hashes[name] = file_digest(source)
                if path.name != "run.log":
                    self.figures.append(path)
                    return
                source.seek(0)
                data = source.read(LOG_EXCERPT_BYTES)
                size = path.stat().st_size
                if size > len(data):
                    n = LOG_EXCERPT_BYTES // 2
                    source.seek(-n, os.SEEK_END)
                    omitted = size - 2 * n
                    data = data[:n] + f"\n[{omitted} middle bytes omitted from reviewer input]\n".encode() + source.read(n)
            else:
                data = source.read()
                self.hashes[name] = digest(data)
        text = data.decode("utf-8", errors="replace" if path.name == "run.log" else "strict")
        if not text.strip():
            if path.name in {"preflight.md", "run.log", "results.md"}:
                text = "[This file is empty. It supplies no evidence.]"
            else:
                raise ValueError(f"empty review input: {name}")
        self.documents[name] = text

    def revision(self) -> str:
        return digest(json_bytes(self.hashes))


def packet(run: Path, phase: str) -> Packet:
    state = read_frontmatter(run / "state.md")
    mode = state.get("mode")
    if mode is None and phase in {"evidence", "presentation"}:
        state["mode"] = "unknown (historical run)"
    elif mode not in {"interactive", "autonomous"}:
        raise ValueError("state.md must record mode interactive or autonomous")
    identity = {k: state[k] for k in ("run_id", "mode", "topic", "compute_profile") if k in state}
    identity.setdefault("run_id", run.name)
    p = Packet({"study": json_bytes(identity).decode()}, {"study": digest(json_bytes(identity))}, [])
    optional = ["topic.txt", "followup-context.md", "prior/success-criteria.md"]
    required = []
    dirs = sorted(d for d in (run / "experiments").glob("exp-*") if d.is_dir())
    completed = [d for d in dirs if (d / "results.md").is_file()]
    if phase == "plan":
        required.extend(["method-spec.md", "success-criteria.md"])
        p.add(run, "methods-order.json")
        order = string_list(json.loads(p.documents["methods-order.json"]), "methods-order.json")
        if (not order or len(set(order)) != len(order) or
                set(order) != {d.name for d in dirs} or
                any(not re.fullmatch(r"exp-[A-Za-z0-9_-]+", item) for item in order)):
            raise ValueError("methods-order.json must name every current experiment directory exactly once in execution order")
        required.extend(f"experiments/{item}/plan.md" for item in order)
        optional.extend(["literature/synthesis.md", "novelty-assessment.md", "challenge/kb-lessons.md"])
    if phase == "evidence":
        if not completed:
            raise ValueError("no completed experiment to review")
        optional.extend(["method-spec.md", "success-criteria.md", "methods-order.json"])
        optional.extend(str((d / "plan.md").relative_to(run)) for d in dirs)
        # A missing or stale design precludes new execution. The same condition
        # is a finding for a retrospective audit of existing observations.
        try:
            plan_revision = packet(run, "plan").revision()
            approval_path = receipt_path(run, "approval", plan_revision)
            approval = checked_approval(run, plan_revision, "human" if mode == "interactive" else "auto")
            provenance = f"Recorded methods decision: {approval['reviews'][0]['decision']}."
            p.add(run, str(approval_path.relative_to(run)))
        except (FileNotFoundError, ValueError) as error:
            provenance = f"Prospective agreement cannot be verified: {error}"
        p.documents["design provenance"] = provenance
        p.hashes["design provenance"] = digest(provenance.encode())
        for d in completed:
            for name in ("results.md", "preflight.md", "run.log"):
                relative = str((d / name).relative_to(run))
                if (run / relative).is_file():
                    required.append(relative)
                else:
                    p.documents[relative] = "[Missing from this run; the corresponding checks cannot be verified.]"
        optional.extend(str(f.relative_to(run)) for f in sorted(run.glob("prior/experiments/exp-*/results.md")))
    if phase == "presentation":
        if completed:
            p = packet(run, "evidence")
            critique = receipt_path(run, "evidence", p.revision())
            if critique.exists():
                p.add(run, str(critique.relative_to(run)))
            else:
                p.documents["evidence review"] = "[No independent critique is recorded for these exact evidence inputs.]"
        drafts = ["briefing.md", "next-steps.md", "paper/paper.tex"]
        if not any((run / name).is_file() for name in drafts):
            raise ValueError("no briefing, next steps or paper to review")
        optional.extend([*drafts, "rethink-rationale.md", "methods-stop.md", "audit/results-audit.md", "success-criteria.md"])
        optional.extend(str(path.relative_to(run)) for path in sorted(run.glob("paper/sections/*.tex")))
        if (run / "briefing.md").is_file() or (run / "paper/paper.tex").is_file() or (run / "review-figures.json").exists():
            p.add(run, "review-figures.json")
            manifest = json.loads(p.documents["review-figures.json"])
            if not isinstance(manifest, dict):
                raise ValueError("review-figures.json must contain figures and reason")
            figures = string_list(manifest.get("figures"), "review-figures.json figures")
            if not figures and not (isinstance(manifest.get("reason"), str) and manifest["reason"].strip()):
                raise ValueError("give a reason for omitting a headline figure in review-figures.json")
            for name in figures:
                if Path(name).is_absolute() or Path(name).suffix.lower() not in {".jpg", ".jpeg", ".png"}:
                    raise ValueError(f"expected a run-relative PNG/JPEG figure: {name}")
                p.add(run, name)
    for name in required + [n for n in optional if (run / n).is_file()]:
        if name not in p.hashes:
            p.add(run, name)
    return p


@dataclass
class ReviewSettings:
    """The reviewer CLI and model, and the round cap of a capped stage's cycle."""
    binary: str
    model: str
    effort: str
    max_rounds: int


def settings(run: Path) -> ReviewSettings:
    keys = ["RESEARCHER_CODEX_BIN", MODEL_KEY, EFFORT_KEY, ROUNDS_KEY]
    environment = os.environ.copy()
    if (run / RUN_CONFIG_FILE).is_file():
        saved = json.loads((run / RUN_CONFIG_FILE).read_text())["settings"]
        for key in (MODEL_KEY, EFFORT_KEY, ROUNDS_KEY):
            if saved.get(key):
                environment[key] = saved[key]
    result = subprocess.run([ROOT / "scripts/config.sh", *keys], env=environment, text=True,
                            stdout=subprocess.PIPE, check=True)
    binary, model, effort, rounds = result.stdout.splitlines()
    if not re.fullmatch(r"[1-9][0-9]*", rounds):
        raise ValueError(f"{ROUNDS_KEY} must be a whole number of at least 1, got {rounds!r}")
    return ReviewSettings(binary, model, effort, int(rounds))


def check_report(report: dict) -> None:
    """A stored review's decision, summary and findings. Receipts recorded before the
    review ledger give findings as plain text; verify still reads them."""
    if report.get("decision") not in EXIT or not isinstance(report.get("summary"), str) or not report["summary"].strip():
        raise ValueError("invalid review decision or missing summary")
    findings = report.get("findings")
    if not isinstance(findings, list) or not all(
            (isinstance(f, str) and f.strip()) or (isinstance(f, dict) and RECEIPT_FINDING_KEYS <= set(f))
            for f in findings):
        raise ValueError("review findings: expected ledger findings, or text in a receipt that predates them")


def review(prompt_name: str, p: Packet, config: ReviewSettings, schema: dict, context: list[str]) -> dict:
    """One reviewer's raw response to packet `p`, with the call's model, time and usage.
    `context` holds the prompt's review stage, round and ledger sections."""
    role_dir = ROOT / "agents" if prompt_name in ROLES else TEMPLATES
    prompt = "\n\n".join([(role_dir / f"{prompt_name}.md").read_text(), (TEMPLATES / "instructions.md").read_text(),
                          (ROOT / "docs/SCIENTIFIC-REPORTING.md").read_text(), *context,
                          "Study materials (JSON keyed by source path):", json_bytes(p.documents).decode()])
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="researcher-review-") as temp:
        work = Path(temp)
        answer = work / "answer.json"
        schema_file = work / "verdict.schema.json"
        schema_file.write_text(json.dumps(schema))
        args = [config.binary, "--ask-for-approval", "never", "exec", "--ephemeral", "--ignore-user-config",
                "--skip-git-repo-check", "--cd", str(work), "--sandbox", "read-only",
                "--model", config.model, "-c", f"model_reasoning_effort={json.dumps(config.effort)}",
                "-c", 'web_search="disabled"', "--json",
                "--output-schema", str(schema_file), "--output-last-message", str(answer)]
        for feature in ("multi_agent", "multi_agent_v2", "shell_tool", "unified_exec",
                        "apps", "plugins", "hooks", "goals", "view_image"):
            args.extend(["--disable", feature])
        for figure in p.figures:
            args.extend(["--image", str(figure)])
        log(f"Reviewing {prompt_name} with {config.model} ({config.effort})")
        # Only the last message and usage totals are retained; no tool transcript is published.
        with tempfile.TemporaryFile(mode="w+") as events:
            subprocess.run([*args, "-"], input=prompt, text=True, cwd=work, stdout=events, check=True)
            events.seek(0)
            usage = [event["usage"] for line in events if line.strip()
                     for event in [json.loads(line)] if event.get("type") == "turn.completed" and "usage" in event]
        response = json.loads(answer.read_text())
    return {"model": config.model, "reasoning": config.effort, "elapsed_seconds": round(time.monotonic() - start, 2),
            "usage": usage, "response": response}


def input_changes(run: Path, stage: str, ledger: Ledger, hashes: dict[str, str]) -> str | None:
    """Which reviewed inputs changed since the stage's last round, for its next reviewer."""
    if not ledger.rounds:
        return None
    last = ledger.rounds[-1]
    before = json.loads(receipt_path(run, stage, last["revision"]).read_text())["inputs"]
    changes = {"changed": sorted(name for name in hashes if name in before and before[name] != hashes[name]),
               "added": sorted(set(hashes) - set(before)), "removed": sorted(set(before) - set(hashes))}
    return f"Reviewed inputs changed since ledger round {last['round']} (JSON): {json.dumps(changes)}"


def commission(stage: str, actor: str, run: Path, p: Packet, config: ReviewSettings, ledger: Ledger,
               new_cycle: str | None) -> list[dict]:
    """Run one review round of `stage` on `p`, record it in `ledger`, and return its reports."""
    roles = ROLES if stage == "plan" else (actor if stage == "approval" else stage,)
    prompt_names = dict(zip(roles, ROLES if stage == "plan" else (stage,)))
    unanswered = ledger.unanswered()
    if unanswered:
        log(f"WARNING: no hub response recorded for open blocking findings: {', '.join(unanswered)}")
    in_cycle = 1 if new_cycle else ledger.rounds_in_cycle() + 1
    header = f"Review stage: {stage}. Ledger round {len(ledger.rounds) + 1}."
    if stage in CAPPED_STAGES:
        header += f" Round {in_cycle} of at most {config.max_rounds} in this review cycle."
    context = [header]
    for name in CONTEXT_STAGES[stage]:
        shown = ledger if name == stage else Ledger.load(run, name)
        if shown.findings:
            context.append(f"Review ledger of the {name} stage (JSON):\n{shown.context()}")
    changes = input_changes(run, stage, ledger, p.hashes)
    if changes:
        context.append(changes)
    template = json.loads((TEMPLATES / "verdict.schema.json").read_text())

    def one(role: str) -> dict:
        return review(prompt_names[role], p, config, ledger.response_schema(template, role), context)

    if stage == "plan":
        with ThreadPoolExecutor(max_workers=len(ROLES)) as workers:
            calls = list(workers.map(one, roles))
    else:
        calls = [one(roles[0])]
    responses = [(role, ledger.check_response(role, call.pop("response"))) for role, call in zip(roles, calls)]
    reports = []
    for (role, response), call, (findings, decided) in zip(
            responses, calls, ledger.record_round(p.revision(), responses, new_cycle)):
        report = {"role": role, **call, "decision": decided, "summary": response["summary"], "findings": findings}
        if decided != response["decision"]:
            report["stated_decision"] = response["decision"]
        reports.append(report)
    blocking = [f["id"] for f in ledger.open_blocking()]
    log(f"{stage} ledger round {len(ledger.rounds)}: "
        + ", ".join(f"{r['role']} {r['decision']}" + (f" (stated {r['stated_decision']})" if "stated_decision" in r else "")
                    for r in reports)
        + f"; open blocking findings: {', '.join(blocking) or 'none'}")
    return reports


def round_cap_reached(ledger: Ledger, cap: int) -> int:
    last = ledger.rounds[-1]["revision"]
    listing = "; ".join(f"{f['id']} ({f['title']})" for f in ledger.open_blocking()) or "none"
    log(f"{ledger.stage} review: round cap reached ({cap} rounds in cycle {ledger.cycle()}), so no review ran. "
        f"Open blocking findings: {listing}. Last reviewed revision: {last}. Take this stage's exit "
        "(docs/WORKFLOW.md, Review ledger); start a new cycle with --new-cycle REASON only on a decision "
        "by Titus or the automatic approver.")
    print(last)
    return ROUND_CAP_EXIT


def receipt_path(run: Path, phase: str, revision: str) -> Path:
    return run / "reviews" / phase / f"{revision}.json"


def checked_approval(run: Path, revision: str, actor: str) -> dict:
    panel = receipt_path(run, "plan", revision)
    load_receipt(panel, revision, ROLES)
    saved = load_receipt(receipt_path(run, "approval", revision), revision, (actor,))
    if saved.get("panel_digest") != digest(panel.read_bytes()):
        raise ValueError("approval does not match the recorded independent critiques")
    return saved


def run_action(action: str, run: Path, approved_revision: str | None, new_cycle: str | None) -> int:
    phase = {"approve-auto": "approval", "approve-human": "approval", "verify": "approval"}.get(
        action, action.removeprefix("verify-"))
    source_phase = "plan" if phase == "approval" else phase
    p = packet(run, source_phase)
    rev = p.revision()
    path = receipt_path(run, phase, rev)
    mode = json.loads(p.documents["study"])["mode"]
    actor = "human" if mode == "interactive" else "auto"
    if action == "approve-human" and (actor != "human" or approved_revision != rev):
        raise ValueError("explicit human approval must name the current interactive revision")
    if action == "approve-auto" and actor != "auto":
        raise ValueError("auto approval requires autonomous mode")

    if phase == "approval":
        panel_file = receipt_path(run, "plan", rev)
        panel = load_receipt(panel_file, rev, ROLES)
        p.documents["independent critiques"] = json_bytes(panel["reviews"]).decode()
    if action.startswith("verify") or path.is_file():
        saved = (checked_approval(run, rev, actor) if phase == "approval"
                 else load_receipt(path, rev, ROLES if phase == "plan" else (phase,)))
        decision = saved["reviews"][0]["decision"]
        if not action.startswith("verify") and action != "approve-human":
            note_cached(run, phase, rev, new_cycle)
    else:
        ledger = None
        if action == "approve-human":
            reviews = [{"role": "human", "decision": "approve", "summary": "Explicit approval of this revision.", "findings": []}]
        else:
            config = settings(run)
            ledger = Ledger.load(run, phase)
            if phase in CAPPED_STAGES and not new_cycle and ledger.rounds_in_cycle() >= config.max_rounds:
                return round_cap_reached(ledger, config.max_rounds)
            reviews = commission(phase, actor, run, p, config, ledger, new_cycle)
        if packet(run, source_phase).revision() != rev:
            raise ValueError("review inputs changed during review; rerun on the current revision")
        record = {"revision": rev, "inputs": p.hashes, "reviews": reviews,
                  "recorded_at": datetime.now(timezone.utc).isoformat()}
        if phase == "plan":
            # Preserve the version Titus or the automatic approver could authorize.
            # Literature, wiki lessons and prior discussions are fingerprinted only.
            bound = {"methods-order.json", "method-spec.md", "success-criteria.md", "prior/success-criteria.md"}
            record["methods"] = {name: text for name, text in p.documents.items()
                                 if name in bound or name.endswith("/plan.md")}
        if phase == "approval":
            record["panel_digest"] = digest(panel_file.read_bytes())
            record["results_already_present"] = sorted(
                path.parent.name for path in (run / "experiments").glob("exp-*/results.md") if path.is_file()
            )
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, record)
        if ledger is not None:
            ledger.save()
        decision = reviews[0]["decision"]
    log(f"{phase} review: {path}")
    if action == "verify-evidence":
        print(f"{decision} {path}")
        return 0
    print(rev)
    return 0 if phase == "plan" else EXIT[decision]


def note_cached(run: Path, stage: str, revision: str, new_cycle: str | None) -> None:
    """Say why a repeated review call reused its receipt instead of running a round."""
    ledger = Ledger.load(run, stage)
    reviewed = ledger.round_of(revision)
    if new_cycle:
        log(f"NOTE: a receipt already covers revision {revision}, so no new review cycle started.")
    if reviewed is not None and ledger.responses_after(reviewed):
        log(f"NOTE: the responses recorded after ledger round {reviewed} change no reviewed input, so its review "
            "stands. State a limit or the reason for a declined finding in the reviewed material itself.")


def load_receipt(path: Path, revision: str, roles) -> dict:
    saved = json.loads(path.read_text())
    if (not isinstance(saved, dict) or saved.get("revision") != revision
            or digest(json_bytes(saved.get("inputs"))) != revision
            or not isinstance(saved.get("reviews"), list)
            or [r.get("role") for r in saved["reviews"] if isinstance(r, dict)] != list(roles)):
        raise ValueError(f"invalid review receipt: {path}")
    for report in saved["reviews"]:
        check_report(report)
    return saved


def respond(run: Path, stage: str, finding: str, disposition: str, note: str) -> int:
    ledger = Ledger.load(run, stage)
    ledger.respond(finding, disposition, note)
    ledger.save()
    log(f"Recorded the response {disposition} to {finding} in the {stage} review ledger")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    actions = parser.add_subparsers(dest="action", required=True)
    for name in ("plan", "presentation", "evidence", "approve-auto", "verify", "verify-evidence", "verify-presentation"):
        action = actions.add_parser(name)
        action.add_argument("run", type=Path)
        if name in CAPPED_STAGES:
            action.add_argument("--new-cycle", metavar="REASON",
                                help="start a new review cycle, giving the decision that warrants it")
    human = actions.add_parser("approve-human")
    human.add_argument("run", type=Path)
    human.add_argument("revision")
    answer = actions.add_parser("respond", help="record the hub's response to one finding of a review ledger")
    answer.add_argument("run", type=Path)
    answer.add_argument("stage", choices=STAGES)
    answer.add_argument("finding")
    answer.add_argument("disposition", choices=DISPOSITIONS)
    answer.add_argument("note")
    args = parser.parse_args()
    new_cycle = getattr(args, "new_cycle", None)
    if new_cycle is not None and not new_cycle.strip():
        parser.error("--new-cycle needs the decision that warrants the new cycle")
    try:
        run = args.run.resolve(strict=True)
        with (run / ".methods-review.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.action == "respond":
                return respond(run, args.stage, args.finding, args.disposition, args.note)
            return run_action(args.action, run, getattr(args, "revision", None), new_cycle)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        log(f"Review failed ({args.action}): {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

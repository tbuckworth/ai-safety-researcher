#!/usr/bin/env python3
"""Independent scientific review and verification of versioned research plans.

Usage:
  methods_review.py plan|presentation RUN [--new-cycle REASON]
  methods_review.py evidence|approve-auto|verify|verify-evidence|verify-presentation RUN
  methods_review.py approve-human RUN REVISION
  methods_review.py respond RUN STAGE FINDING fixed|limit|declined NOTE
  methods_review.py cap-findings|reopen-declined RUN

The hub calls the review actions; verify actions are offline. Decisions use exit 0
(approved), 3 (revision requested), or 4 (stop); a review asks for revision only
for an open blocking finding. A capped stage (plan, approval, presentation) has at
most RESEARCHER_MAX_REVIEW_ROUNDS rounds in a cycle. Exit 5 means the cap is
reached: a further call on a new revision runs no review and prints the last
reviewed revision; and the approval or presentation of the revision reviewed at
the cap, when its reviewer still asks for revision, exits 5 too, for the stage's
exit at the cap (docs/WORKFLOW.md, Review Ledger): the experiments run on that
revision, or the draft is released, with the open blocking findings reported
(cap-findings lists them). `verify` admits such an approval (exit 0). Errors use
exit 1. Each stage keeps a review ledger (review_ledger.py) that every later round
of it sees; a later round's new blocking finding must concern an input changed
since the round that last reviewed it (the certified range). respond records the
hub's answer to one finding. All completed design critiques are returned to the
approver, including objections. Evidence objections are returned to the auditor
for disposition. reopen-declined supersedes a methods-stop.md that only the
automatic approver's former one-revision limit wrote, so that a resumed run
re-enters approval (docs/AUTONOMOUS.md, Resuming a run).
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
# critic runs once per audit round, which RESEARCHER_MAX_AUDIT_ROUNDS caps. The
# automatic approver's rounds form one cycle, so its revisions are capped per run.
CAPPED_STAGES = ("plan", "approval", "presentation")
# The stages a decision may start a new cycle of (--new-cycle).
CYCLE_STAGES = ("plan", "presentation")
# The stages whose decision on the revision reviewed at the cap is itself the
# stage's exit (exit 5) when its reviewer still asks for revision, and what their
# reviewer is told in its last round.
LAST_ROUND = {
    "approval": "This is the last approval round: if you still ask for revision, the experiments run on this "
                "revision and your open blocking findings are reported with the results as limitations.",
    "presentation": "This is the last round: if you still ask for revision, the draft may be released with your "
                    "open blocking findings listed beside it.",
}
CAP_EXIT_STAGES = tuple(LAST_ROUND)
# The drafts a final reader reads; any one of them makes a presentation packet.
DRAFTS = ("briefing.md", "next-steps.md", "paper/paper.tex")
# What a resumed run moves into superseded/<time>/ when reopen-declined supersedes
# a methods-stop.md: the stop and the deliverables written after it.
SUPERSEDED = ("methods-stop.md", "briefing.md", "next-steps.md", "review-figures.json", "paper",
              "audit/results-audit.md")
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
            actor = "human" if mode == "interactive" else "auto"
            plan, approval_path = approval_target(run, packet(run, "plan"))
            plan_revision = plan.revision()
            approval = checked_approval(run, plan_revision, actor, approval_path)
            provenance = f"Recorded methods decision: {approval['reviews'][0]['decision']}."
            if approval["reviews"][0]["decision"] == "revise" and at_round_cap(run, "approval", plan_revision):
                provenance += (" The automatic approver still asked for revision in its last round (the round cap), "
                               "so the experiments ran on this revision as reviewed, its open blocking approval "
                               "findings to be reported as limitations (docs/WORKFLOW.md, Step 8).")
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
        if not any((run / name).is_file() for name in DRAFTS):
            raise ValueError("no briefing, next steps or paper to review")
        optional.extend([*DRAFTS, "rethink-rationale.md", "methods-stop.md", "audit/results-audit.md", "success-criteria.md"])
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


def input_changes(run: Path, stage: str, ledger: Ledger, hashes: dict[str, str]) -> tuple[str | None, set[str] | None]:
    """The certified range of the stage's next round: for its reviewer, which reviewed
    inputs changed since the round of this stage (in any cycle) that last reviewed
    them; and the set of inputs a new blocking finding may concern, those changed or
    not yet reviewed at this stage (None on the stage's first round)."""
    seen: dict[str, str] = {}
    last: dict[str, str] = {}
    for entry in ledger.rounds:   # run_action writes each round's receipt before the ledger records it
        last = json.loads(receipt_path(run, stage, entry["revision"]).read_text())["inputs"]
        seen.update(last)
    if not seen:
        return None, None
    changes = {"changed": sorted(name for name in hashes if name in seen and seen[name] != hashes[name]),
               "added": sorted(set(hashes) - set(seen)), "removed": sorted(set(last) - set(hashes)),
               "unchanged": sorted(name for name in hashes if seen.get(name) == hashes[name])}
    text = (f"Reviewed inputs compared with the round of this stage that last reviewed each (JSON): "
            f"{json.dumps(changes)}. An earlier round reviewed the unchanged ones: a new finding blocks only when "
            "one of its sources is changed or added, or when it reopens a settled finding.")
    return text, set(changes["changed"]) | set(changes["added"])


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
        if stage in LAST_ROUND and in_cycle >= config.max_rounds:
            header += " " + LAST_ROUND[stage]
    context = [header]
    settled_elsewhere = []
    for name in CONTEXT_STAGES[stage]:
        shown = ledger if name == stage else Ledger.load(run, name)
        if name != stage:
            settled_elsewhere.extend(shown.settled_ids())
        if shown.findings:
            context.append(f"Review ledger of the {name} stage (JSON):\n{shown.context()}")
    changes, changed = input_changes(run, stage, ledger, p.hashes)
    if changes:
        context.append(changes)
    sources = sorted(p.hashes)
    template = json.loads((TEMPLATES / "verdict.schema.json").read_text())

    def one(role: str) -> dict:
        return review(prompt_names[role], p, config,
                      ledger.response_schema(template, role, sources, settled_elsewhere), context)

    if stage == "plan":
        with ThreadPoolExecutor(max_workers=len(ROLES)) as workers:
            calls = list(workers.map(one, roles))
    else:
        calls = [one(roles[0])]
    responses = [(role, ledger.check_response(role, call.pop("response"), sources, settled_elsewhere))
                 for role, call in zip(roles, calls)]
    reports = []
    for (role, response), call, (findings, decided) in zip(
            responses, calls, ledger.record_round(p.revision(), responses, new_cycle, changed)):
        report = {"role": role, **call, "decision": decided, "summary": response["summary"], "findings": findings}
        if decided != response["decision"]:
            report["stated_decision"] = response["decision"]
        reports.append(report)
    blocking = [f["id"] for f in ledger.open_blocking()]
    certified = [f["id"] for r in reports for f in r["findings"] if f.get("certified")]
    log(f"{stage} ledger round {len(ledger.rounds)}: "
        + ", ".join(f"{r['role']} {r['decision']}" + (f" (stated {r['stated_decision']})" if "stated_decision" in r else "")
                    for r in reports)
        + f"; open blocking findings: {', '.join(blocking) or 'none'}")
    if certified:
        log(f"Recorded as non-blocking, on inputs an earlier {stage} round reviewed unchanged (the certified "
            f"range): {', '.join(certified)}")
    if stage in CAPPED_STAGES and in_cycle >= config.max_rounds:
        log(f"NOTE: this was the last round of the {stage} review cycle. Take the stage's exit on this revision "
            "without editing its inputs (docs/WORKFLOW.md, Review Ledger).")
    return reports


def named(findings: list[dict]) -> str:
    """Findings as "id (title); ...", or "none"."""
    return "; ".join(f"{f['id']} ({f['title']})" for f in findings) or "none"


def round_cap_reached(ledger: Ledger, cap: int) -> int:
    last = ledger.rounds[-1]["revision"]
    listing = named(ledger.open_blocking())
    if ledger.stage == "approval":
        then = (f"Restore the plan to that revision from the methods of reviews/plan/{last}.json and run "
                "approve-auto again: it returns that round's decision (docs/WORKFLOW.md, Step 8).")
    else:
        then = ("Take this stage's exit (docs/WORKFLOW.md, Review ledger); start a new cycle with --new-cycle "
                "REASON only on a decision by Titus or the automatic approver.")
    log(f"{ledger.stage} review: round cap reached ({cap} rounds in cycle {ledger.cycle()}), so no review ran. "
        f"Open blocking findings: {listing}. Last reviewed revision: {last}. {then}")
    print(last)
    return ROUND_CAP_EXIT


def approver_cycle_reason(approval_round: int) -> str:
    """Why the plan's next review cycle starts when the automatic approver asks for a revision."""
    return f"the automatic approver requested a revision (approval round {approval_round})"


def at_round_cap(run: Path, stage: str, revision: str) -> bool:
    """Whether `revision` is the one the last round of `stage` reviewed, in a cycle
    that has had RESEARCHER_MAX_REVIEW_ROUNDS rounds."""
    ledger = Ledger.load(run, stage)
    return (bool(ledger.rounds) and ledger.rounds[-1]["revision"] == revision
            and ledger.rounds_in_cycle() >= settings(run).max_rounds)


def receipt_path(run: Path, phase: str, revision: str) -> Path:
    return run / "reviews" / phase / f"{revision}.json"


def approval_target(run: Path, plan: Packet, requested: str | None = None) -> tuple[Packet, Path]:
    revision = plan.revision()
    path = receipt_path(run, "approval", revision)
    study = json.loads(plan.documents["study"])
    if study["mode"] != "interactive" or requested == revision or (requested is None and path.is_file()):
        return plan, path

    # An automatic-to-human handoff may name the existing panel. Recompute
    # its revision from the current plan with only the workflow mode changed.
    study["mode"] = "autonomous"
    data = json_bytes(study)
    offered = Packet({**plan.documents, "study": data.decode()},
                     {**plan.hashes, "study": digest(data)}, plan.figures)
    offered_revision = offered.revision()
    handoff = receipt_path(run, "approval", offered_revision).with_suffix(".human.json")
    if requested == offered_revision or (requested is None and handoff.is_file()):
        return offered, handoff
    return plan, path


def checked_approval(run: Path, revision: str, actor: str, path: Path) -> dict:
    panel = receipt_path(run, "plan", revision)
    load_receipt(panel, revision, ROLES)
    saved = load_receipt(path, revision, (actor,))
    if saved.get("panel_digest") != digest(panel.read_bytes()):
        raise ValueError("approval does not match the recorded independent critiques")
    return saved


def run_action(action: str, run: Path, approved_revision: str | None, new_cycle: str | None) -> int:
    phase = {"approve-auto": "approval", "approve-human": "approval", "verify": "approval"}.get(
        action, action.removeprefix("verify-"))
    source_phase = "plan" if phase == "approval" else phase
    p = packet(run, source_phase)
    source_revision = p.revision()
    mode = json.loads(p.documents["study"])["mode"]
    actor = "human" if mode == "interactive" else "auto"
    if phase == "approval":
        p, path = approval_target(run, p, approved_revision)
    else:
        path = receipt_path(run, phase, source_revision)
    rev = p.revision()
    if action == "approve-human" and (actor != "human" or approved_revision != rev):
        raise ValueError("explicit human approval must name the current reviewed revision in interactive mode")
    if action == "approve-auto" and actor != "auto":
        raise ValueError("auto approval requires autonomous mode")

    if phase == "approval":
        panel_file = receipt_path(run, "plan", rev)
        panel = load_receipt(panel_file, rev, ROLES)
        p.documents["independent critiques"] = json_bytes(panel["reviews"]).decode()
    if action.startswith("verify") or path.is_file():
        saved = (checked_approval(run, rev, actor, path) if phase == "approval"
                 else load_receipt(path, rev, ROLES if phase == "plan" else (phase,)))
        decision = saved["reviews"][0]["decision"]
        if new_cycle:
            raise ValueError(f"a receipt already covers revision {rev}; a new cycle starts on a revision not yet reviewed")
        if not action.startswith("verify") and action != "approve-human":
            note_cached(run, phase, rev)
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
            if (phase == "approval" and reviews[0]["decision"] == "revise"
                    and ledger.rounds_in_cycle() < config.max_rounds):
                # The approver's request for a revision is the decision that starts the plan's next cycle.
                plan = Ledger.load(run, "plan")
                plan.arm_cycle(approver_cycle_reason(len(ledger.rounds)))
                plan.save()
        if packet(run, source_phase).revision() != source_revision:
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
    capped = phase in CAP_EXIT_STAGES and decision == "revise" and at_round_cap(run, phase, rev)
    if capped:
        log(f"{phase} review: revision {rev} was reviewed in the last round of its cycle and its reviewer still "
            f"asks for revision. Take the stage's exit at the round cap (docs/WORKFLOW.md, Review Ledger): "
            + ("the experiments run on this revision, its open blocking findings reported as limitations."
               if phase == "approval" else "release this draft with its open blocking findings listed.")
            + " cap-findings lists them.")
    print(rev)
    if phase == "plan":
        return 0
    if capped:
        return 0 if action == "verify" else ROUND_CAP_EXIT
    return EXIT[decision]


def note_cached(run: Path, stage: str, revision: str) -> None:
    """Say why a repeated review call reused its receipt instead of running a round."""
    ledger = Ledger.load(run, stage)
    reviewed = ledger.round_of(revision)
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


def cap_findings(run: Path) -> int:
    """Print, as JSON, the blocking findings the run went past at a round cap: the
    automatic approver's (and the plan critics' open ones) when the experiments ran
    on a revision the approver still asked to revise in its last round, and the
    final reader's when its last round left the current draft with blocking
    findings open. `markdown` lists them for the report and the run directory,
    `notes` gives one line per stage for the run's outcome, and `ids` names them."""
    sections, notes, ids = [], [], []

    def listing(findings: list[dict]) -> list[str]:
        return [f"- **{f['id']}** ({f['title']}): {Ledger.current(f)['text']}" for f in findings]

    # The approver's capped round is its last one, whatever the plan files hold now
    # (a report step may have edited one since); the reader's is the current draft's.
    stages = []
    approval = Ledger.load(run, "approval")
    if approval.rounds:
        stages.append(("approval", approval.rounds[-1]["revision"]))
    if any((run / name).is_file() for name in DRAFTS):
        stages.append(("presentation", packet(run, "presentation").revision()))
    for stage, revision in stages:
        ledger = Ledger.load(run, stage)
        receipt = receipt_path(run, stage, revision)
        # the current draft may not have been reviewed yet; every approval round has its receipt
        if (stage == "presentation" and not receipt.is_file()) or not at_round_cap(run, stage, revision):
            continue
        if json.loads(receipt.read_text())["reviews"][0]["decision"] != "revise":
            continue
        open_findings = ledger.open_blocking()
        rounds = ledger.rounds_in_cycle()
        listed = named(open_findings)
        ids.extend(f["id"] for f in open_findings)
        if stage == "approval":
            plan_open = Ledger.load(run, "plan").open_blocking()
            ids.extend(f["id"] for f in plan_open)
            sections.append("\n".join([
                "## Methods approval at its round cap", "",
                f"The automatic approver still asked for revision in its last round ({rounds} rounds, the cap), so "
                f"the experiments ran on revision {revision} as reviewed. Its open blocking findings:", "",
                *listing(open_findings),
                *(["", "The plan critics' blocking findings open at that revision:", "", *listing(plan_open)]
                  if plan_open else [])]))
            notes.append(f"The experiments ran on a design the automatic approver still asked to revise at its "
                         f"round cap ({rounds} rounds); open blocking findings: {listed} (open-review-findings.md)")
        else:
            sections.append("\n".join([
                "## Final reading at its round cap", "",
                f"The final reader still asked for revision in its last round ({rounds} rounds, the cap), so this "
                f"draft (revision {revision}) was released as reviewed, with these blocking findings open:", "",
                *listing(open_findings)]))
            notes.append(f"Released at the final reader's round cap ({rounds} rounds) with blocking findings open: "
                         f"{listed} (open-review-findings.md)")
    markdown = ""
    if sections:
        markdown = "# Review findings left open at a round cap\n\n" + "\n\n".join(sections) + "\n"
    print(json.dumps({"markdown": markdown, "notes": notes, "ids": ids}))
    return 0


def reopen_declined(run: Path) -> int:
    """Supersede a methods-stop.md that only the automatic approver's former
    one-revision limit wrote, for a resumed run: the approver's last round asked
    for revision (it did not stop), on the revision the plan critics reviewed
    last (no plan was revised and reviewed after it, as one is when the hub stops
    a revised plan for want of a feasible comparison), and no experiment has
    started. Restores the
    plan files edited since that round from its plan receipt, moves the stop and
    the deliverables written after it into superseded/<time>/ (kept as history,
    never deleted), and arms a new presentation cycle for the new draft and, below
    the round cap, the plan cycle the approver's request starts. Step 8 then
    takes the approver's decision under the current rule. Prints, as JSON,
    `reopened` and either `why` not or what it did; writes nothing when not."""
    def stays(why: str) -> int:
        print(json.dumps({"reopened": False, "why": why}))
        return 0

    if not (run / "methods-stop.md").is_file():
        return stays("there is no methods-stop.md")
    if read_frontmatter(run / "state.md").get("mode") != "autonomous":
        return stays("the run is not autonomous")
    started = sorted(d.name for d in (run / "experiments").glob("exp-*")
                     if (d / "started").exists() or (d / "results.md").exists())
    if started:
        return stays(f"experiments already started ({', '.join(started)})")
    approval = Ledger.load(run, "approval")
    if not approval.rounds:
        return stays("no round of the automatic approver is recorded")
    last = approval.rounds[-1]
    decided = sorted(set(last["decisions"].values()))
    if decided != ["revise"]:
        return stays(f"the approver's last round decided {', '.join(decided) or 'nothing'}, not revise")
    revision = last["revision"]
    plan_rounds = Ledger.load(run, "plan").rounds
    if plan_rounds and plan_rounds[-1]["revision"] != revision:
        return stays(f"the plan was revised and reviewed again after approval round {last['round']}, so the stop "
                     "came after that revision, not from the approver's revision limit")
    receipt = json.loads(receipt_path(run, "plan", revision).read_text())
    methods, reviewed = receipt["methods"], receipt["inputs"]
    current = packet(run, "plan").hashes
    differ = sorted(name for name in set(current) | set(reviewed) if current.get(name) != reviewed.get(name))
    kept = [name for name in differ if name not in methods]
    if kept:
        return stays(f"inputs changed since approval round {last['round']} that its plan receipt does not keep "
                     f"({', '.join(kept)}), so the reviewed revision cannot be restored")
    config = settings(run)
    rounds = approval.rounds_in_cycle()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    history = run / "superseded" / stamp
    moved = []
    for name in SUPERSEDED:
        if (run / name).exists():
            (history / name).parent.mkdir(parents=True, exist_ok=True)
            (run / name).rename(history / name)
            moved.append(name)
    for name in differ:
        (run / name).parent.mkdir(parents=True, exist_ok=True)
        (run / name).write_text(methods[name], encoding="utf-8")
    if packet(run, "plan").revision() != revision:
        raise ValueError(f"restoring {', '.join(differ)} did not give back revision {revision}")
    reason = (f"methods-stop.md came only from the automatic approver's former one-revision limit: its round "
              f"{last['round']} asked for revision, and approval now allows {config.max_rounds} rounds")
    (history / "README.md").write_text(
        f"# Superseded on {stamp}\n\n{reason}. These files were written after that stop and are kept as "
        f"history: {', '.join(moved)}. The resumed run re-entered Step 8 on revision {revision}"
        + (f"; restored from reviews/plan/{revision}.json: {', '.join(differ)}." if differ else ".") + "\n",
        encoding="utf-8")
    if rounds < config.max_rounds:
        plan = Ledger.load(run, "plan")
        plan.arm_cycle(f"{approver_cycle_reason(last['round'])}; {reason}")
        plan.save()
    presentation = Ledger.load(run, "presentation")
    if presentation.rounds:
        presentation.arm_cycle(f"{reason}: the draft it led to is superseded, and a new draft follows")
        presentation.save()
    log(f"Reopened the methods decision: {reason}. Moved to {history.relative_to(run)}: {', '.join(moved)}"
        + (f"; restored {', '.join(differ)}" if differ else ""))
    print(json.dumps({"reopened": True, "revision": revision, "approval_rounds": rounds, "cap": config.max_rounds,
                      "at_cap": rounds >= config.max_rounds, "moved_to": str(history.relative_to(run)),
                      "moved": moved, "restored": differ, "reason": reason}))
    return 0


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
        if name in CYCLE_STAGES:
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
    for name, text in (("cap-findings", "print the blocking findings the run went past at a round cap"),
                       ("reopen-declined", "supersede a methods-stop.md from the former one-revision limit")):
        actions.add_parser(name, help=text).add_argument("run", type=Path)
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
            if args.action == "cap-findings":
                return cap_findings(run)
            if args.action == "reopen-declined":
                return reopen_declined(run)
            return run_action(args.action, run, getattr(args, "revision", None), new_cycle)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        log(f"Review failed ({args.action}): {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

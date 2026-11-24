#!/usr/bin/env python3
"""Independent scientific review and verification of versioned research plans.

Usage: methods_review.py ACTION RUN [REVISION] (REVISION only for approve-human).
The hub calls the review actions; verify actions are offline. Decisions use exit 0
(approved), 3 (revision requested), or 4 (stop). Errors use exit 1. All completed
design critiques are returned to the approver, including objections. Evidence
objections are returned to the auditor for disposition.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
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

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "templates" / "review"
ROLES = ("assumption-challenger", "mentor-review", "pre-mortem")
EXIT = {"approve": 0, "revise": 3, "stop": 4}
TASK = {
    "approval": "Act as the independent methodology approver. Read each critic's findings. Resolve material disagreements and name the exact control, revision or reason to stop. Decide whether these specific experiments should start.",
    "evidence": "Check the main experiment claims against the approved comparison, preflights and raw observations. Identify measurement failures, dependence, selection, alternative explanations, deviations and untested endpoints. Say what the auditor must resolve or downgrade.",
    "presentation": "Read the draft as a scientist deciding what to do next. Compare its headline, quantitative claims and any supplied figures with the evidence and audit. Check the actual images, axes, denominators, uncertainty and readability. Require an accurate account of pilot-only, unrun or unaudited work. Specify exact repairs where necessary.",
}
MODEL_KEY = "RESEARCHER_REVIEW_MODEL"
EFFORT_KEY = "RESEARCHER_REVIEW_REASONING"
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
    if phase == "plan" or (phase == "evidence" and (run / "methods-order.json").exists()):
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
        if "methods-order.json" not in p.hashes:
            p.documents["design provenance"] = "No versioned methods order is available. Prospective agreement cannot be verified."
            optional.extend(["method-spec.md", "success-criteria.md"])
            optional.extend(str((d / "plan.md").relative_to(run)) for d in dirs)
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
        optional.extend([*drafts, "rethink-rationale.md", "audit/results-audit.md", "success-criteria.md"])
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


def settings(run: Path) -> tuple[str, str, str]:
    keys = ["RESEARCHER_CODEX_BIN", MODEL_KEY, EFFORT_KEY]
    environment = os.environ.copy()
    if (run / RUN_CONFIG_FILE).is_file():
        saved = json.loads((run / RUN_CONFIG_FILE).read_text())["settings"]
        for key in (MODEL_KEY, EFFORT_KEY):
            if saved.get(key):
                environment[key] = saved[key]
    result = subprocess.run([ROOT / "scripts/config.sh", *keys], env=environment, text=True,
                            stdout=subprocess.PIPE, check=True)
    binary, model, effort = result.stdout.splitlines()
    return binary, model, effort



def validate(report: dict) -> dict:
    if not isinstance(report, dict) or set(report) != {"decision", "summary", "findings"}:
        raise ValueError("review response must contain decision, summary and findings")
    if report["decision"] not in EXIT or not isinstance(report["summary"], str) or not report["summary"].strip():
        raise ValueError("invalid review decision or missing summary")
    string_list(report["findings"], "review findings")
    return report


def review(role: str, p: Packet, config: tuple[str, str, str]) -> dict:
    binary, model, effort = config
    if role in ROLES:
        task = ("Use the scientific questions in this role description. Use the JSON review format for your reply.\n"
                + (ROOT / "agents" / f"{role}.md").read_text())
    else:
        task = TASK[role]
    prompt = "\n\n".join([task, (TEMPLATES / "instructions.md").read_text(),
                          (ROOT / "docs/SCIENTIFIC-REPORTING.md").read_text(),
                          "Study materials (JSON keyed by source path):", json_bytes(p.documents).decode()])
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="researcher-review-") as temp:
        work = Path(temp)
        answer = work / "answer.json"
        args = [binary, "--ask-for-approval", "never", "exec", "--ephemeral", "--ignore-user-config",
                "--skip-git-repo-check", "--cd", str(work), "--sandbox", "read-only",
                "--model", model, "-c", f"model_reasoning_effort={json.dumps(effort)}",
                "-c", 'web_search="disabled"', "--json",
                "--output-schema", str(TEMPLATES / "verdict.schema.json"), "--output-last-message", str(answer)]
        for feature in ("multi_agent", "multi_agent_v2", "shell_tool", "unified_exec",
                        "apps", "plugins", "hooks", "goals", "view_image"):
            args.extend(["--disable", feature])
        for figure in p.figures:
            args.extend(["--image", str(figure)])
        log(f"Reviewing {role} with {model} ({effort})")
        # Only the last message and usage totals are retained; no tool transcript is published.
        with tempfile.TemporaryFile(mode="w+") as events:
            subprocess.run([*args, "-"], input=prompt, text=True, cwd=work, stdout=events, check=True)
            events.seek(0)
            usage = [event["usage"] for line in events if line.strip()
                     for event in [json.loads(line)] if event.get("type") == "turn.completed" and "usage" in event]
        response = validate(json.loads(answer.read_text()))
    return {"role": role, "model": model, "reasoning": effort, "elapsed_seconds": round(time.monotonic() - start, 2),
            "usage": usage, **response}


def receipt_path(run: Path, phase: str, revision: str) -> Path:
    return run / "reviews" / phase / f"{revision}.json"


def run_action(action: str, run: Path, approved_revision: str | None) -> int:
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
        expected = ROLES if phase == "plan" else (actor,) if phase == "approval" else (phase,)
        saved = load_receipt(path, rev, expected)
        if phase == "approval" and saved.get("panel_digest") != digest(panel_file.read_bytes()):
            raise ValueError("approval does not match the recorded independent critiques")
        decision = saved["reviews"][0]["decision"]
    else:
        if action == "approve-human":
            reviews = [{"role": "human", "decision": "approve", "summary": "Explicit approval of this revision.", "findings": []}]
        else:
            config = settings(run)
            if phase == "plan":
                with ThreadPoolExecutor(max_workers=len(ROLES)) as workers:
                    reviews = list(workers.map(lambda role: review(role, p, config), ROLES))
            else:
                report = review(phase, p, config)
                if phase == "approval":
                    report["role"] = actor
                reviews = [report]
        if packet(run, source_phase).revision() != rev:
            raise ValueError("review inputs changed during review; rerun on the current revision")
        record = {"revision": rev, "inputs": p.hashes, "reviews": reviews}
        if phase == "plan":
            # Preserve the version Titus or the automatic approver could authorize.
            # Literature, wiki lessons and prior discussions are fingerprinted only.
            bound = {"methods-order.json", "method-spec.md", "success-criteria.md", "prior/success-criteria.md"}
            record["methods"] = {name: text for name, text in p.documents.items()
                                 if name in bound or name.endswith("/plan.md")}
        if phase == "approval":
            record["panel_digest"] = digest(panel_file.read_bytes())
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, record)
        decision = reviews[0]["decision"]
    log(f"{phase} review: {path}")
    if action == "verify-evidence":
        print(f"{decision} {path}")
        return 0
    print(rev)
    return 0 if phase == "plan" else EXIT[decision]


def load_receipt(path: Path, revision: str, roles) -> dict:
    saved = json.loads(path.read_text())
    if (not isinstance(saved, dict) or saved.get("revision") != revision
            or digest(json_bytes(saved.get("inputs"))) != revision
            or not isinstance(saved.get("reviews"), list)
            or [r.get("role") for r in saved["reviews"] if isinstance(r, dict)] != list(roles)):
        raise ValueError(f"invalid review receipt: {path}")
    for report in saved["reviews"]:
        validate({key: report[key] for key in ("decision", "summary", "findings")})
    return saved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "approve-auto", "approve-human", "verify",
                                           "evidence", "verify-evidence", "presentation", "verify-presentation"))
    parser.add_argument("run", type=Path)
    parser.add_argument("revision", nargs="?")
    args = parser.parse_args()
    if (args.action == "approve-human") != bool(args.revision):
        parser.error("only approve-human requires a revision argument")
    try:
        run = args.run.resolve(strict=True)
        with (run / ".methods-review.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return run_action(args.action, run, args.revision)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        log(f"Review failed ({args.action}): {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

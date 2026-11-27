"""Reserve one measurement repair and install its independently reviewed results."""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

from methods_review import approval_target, checked_approval, load_receipt, packet, receipt_path
from researcher_files import atomic_write
from researcher_lib import parse_preflight, parse_verdict, scan_experiments
REPAIR = Path("audit/measurement-repair")


def experiment_dir(run: Path, experiment: str) -> Path:
    path = run / "experiments" / experiment
    if not re.fullmatch(r"exp-[A-Za-z0-9_-]+", experiment) or path.resolve() != path or not path.is_dir():
        raise ValueError(f"invalid experiment: {experiment}")
    return path


def approved_revision(run: Path, experiment: str) -> str:
    plan = packet(run, "plan")
    actor = "human" if json.loads(plan.documents["study"])["mode"] == "interactive" else "auto"
    target, path = approval_target(run, plan)
    revision = target.revision()
    approval = checked_approval(run, revision, actor, path)
    if approval["reviews"][0]["decision"] != "approve" or experiment in approval.get("results_already_present", []):
        raise ValueError("the original experiment lacks prospective approval")
    return revision


def reserve(run: Path, experiment: str) -> None:
    source = experiment_dir(run, experiment)
    if not any(item["id"] == experiment and item["verdict"] == "INCONCLUSIVE" for item in scan_experiments(run)):
        raise ValueError("only an inconclusive result can receive a measurement repair")
    repair = run / REPAIR
    if repair.parent.resolve() != repair.parent:
        raise ValueError("expected the audit directory inside this run")
    revision = approved_revision(run, experiment)
    repair.mkdir()  # Exclusive. A partial reservation also prevents redispatch.
    atomic_write(repair / "methods-revision", revision + "\n")
    for name in ("results.md", "preflight.md", "run.log"):
        original = source / name
        if original.is_symlink():
            raise ValueError(f"cannot archive symlinked experiment record: {original}")
        if original.is_file():
            shutil.copy2(original, repair / f"original-{name}")
    shutil.copy2(run / "audit/results-audit.md", repair / "original-audit.md")
    anchor = repair.parent / f"claim-anchor-{experiment}.md"
    if not anchor.exists():
        atomic_write(anchor, (repair / "original-results.md").read_text())
    atomic_write(repair / "experiment", experiment + "\n")


def publish(run: Path) -> str:
    repair = run / REPAIR
    if repair.resolve() != repair:
        raise ValueError("expected a repair directory inside this run")
    target = experiment_dir(run, (repair / "experiment").read_text().strip())
    if approved_revision(run, target.name) != (repair / "methods-revision").read_text().strip():
        raise ValueError("approved methods changed after the repair was reserved")
    results = (repair / "results.md").read_text()
    checks = parse_preflight(repair / "preflight.md")
    original = repair / "original-preflight.md"
    old_checks = parse_preflight(original) if original.is_file() else {}
    verdict = parse_verdict(results)
    if (verdict not in {"PASS", "FAIL"} or not checks or "FAIL" in checks.values()
            or any(checks.get(check) != "PASS" for check, status in old_checks.items() if status == "FAIL")):
        raise ValueError("corrected measurement is still inconclusive")
    revision = packet(run, "evidence").revision()
    receipt = load_receipt(receipt_path(run, "evidence", revision), revision, ("evidence",))
    if receipt["reviews"][0]["decision"] != "approve":
        raise ValueError("independent evidence review has open objections")
    shutil.copy2(run / "audit/results-audit.md", repair / "re-audit.md")
    log = repair / "run.log"
    if log.is_file():
        atomic_write(target / "run.log", log.read_text(encoding="utf-8", errors="replace"))
    # Keep the old failing pre-flight until the reviewed verdict is in place.
    atomic_write(target / "results.md", results)
    atomic_write(target / "preflight.md", (repair / "preflight.md").read_text())
    return verdict


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--reserve", metavar="EXPERIMENT")
    args = parser.parse_args()
    try:
        run = args.run.resolve()
        if args.reserve:
            reserve(run, args.reserve)
        else:
            print(publish(run))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Measurement repair: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

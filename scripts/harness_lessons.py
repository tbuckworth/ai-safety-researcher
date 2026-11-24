#!/usr/bin/env python3
"""Capture verified harness failures and review them across a local archive of research runs.

See docs/KNOWLEDGE-BASE.md#harness-lessons for the record formats and maintenance loop.
Commands take a run directory. record, decide and integrate read one JSON object from stdin.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
from pathlib import Path
import re
import subprocess
import sys
from uuid import uuid4

from researcher_files import atomic_write, digest, file_digest, write_json


def required(obj, field):
    value = obj.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} requires non-empty text")
    return value.strip()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def record_name(row):
    return digest(json.dumps(row, sort_keys=True).encode()) + ".json"


def record(run, data):
    row = {field: required(data, field) for field in
           ("key", "failure", "why_missed", "check", "evidence")}
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", row["key"]):
        raise ValueError("key must be a stable lowercase hyphenated failure class")
    evidence = Path(row["evidence"])
    if evidence.is_absolute() or ".." in evidence.parts:
        raise ValueError("evidence must name a file within this run")
    source = (run / evidence).resolve(strict=True)
    source.relative_to(run)
    if not source.is_file():
        raise ValueError("evidence must be a file")
    row["locator"] = required(data, "locator")
    # Store a fingerprint, so a later audit can distinguish revisions to the source.
    with source.open("rb") as stream:
        row["sha256"] = file_digest(stream)
    folder = run / ".harness"
    folder.mkdir(mode=0o700, exist_ok=True)
    if folder.resolve() != folder:
        raise ValueError(f"unexpected symlink: {folder}")
    atomic_write(folder / ".gitignore", "*\n")
    path = folder / record_name(row)
    write_json(path, row)
    return {"recorded": str(path)}


def observations(archive, state):
    """Collect current records and retain reviewed classes whose runs have been archived."""
    groups = {key: {} for key in state["history"]}
    for path in sorted(archive.glob("*/.harness/*.json")):
        run = path.parents[1]
        if not (run / "state.md").is_file():
            continue
        if run.is_symlink() or path.resolve() != path:
            raise ValueError(f"unexpected symlink in harness record {path}")
        row = read_json(path)
        if path.name != record_name(row):
            raise ValueError(f"harness record fingerprint differs from its filename: {path}")
        groups.setdefault(row["key"], {})[f"{run.name}/{path.name}"] = row
    return groups


@contextmanager
def locked_state(archive):
    folder = archive / ".harness-reviews"
    folder.mkdir(mode=0o700, exist_ok=True)
    if folder.resolve() != folder:
        raise ValueError(f"unexpected symlink: {folder}")
    path = folder / "ledger.json"
    for entry in (folder / "lock", path):
        if entry.is_symlink():
            raise ValueError(f"unexpected symlink: {entry}")
    with (folder / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_json(path) if path.exists() else {"history": {}, "week": "", "claim": None}
        yield folder, state
        write_json(path, state)


def latest(state, key):
    entries = state["history"].get(key)
    return entries[-1] if entries else {}


def weekly(run, now):
    week = now.strftime("%G-W%V")
    with locked_state(run.parent) as (folder, state):
        if state["week"] == week:
            return {"review": None, "reason": "review complete this week"}
        claim = state["claim"]
        if claim and claim["week"] == week and now.timestamp() < claim["expires"]:
            if claim["owner"] == run.name:
                return {"review": str(folder / claim["packet"])}
            return {"review": None, "reason": "another run holds the weekly review"}
        groups = observations(run.parent, state)
        pending = {}
        for key, rows in groups.items():
            prior = latest(state, key)
            if set(rows).difference(prior.get("seen", [])) or prior.get("status") == "deferred":
                if prior:
                    snapshot = read_json(folder / prior["packet"])["candidates"][key]
                    rows = {**snapshot["observations"], **rows}
                pending[key] = {"observations": rows, "previous": prior}
        if not pending:
            state.update(week=week, claim=None)
            return {"review": None, "reason": "no pending lessons"}
        # A caller can fail after taking the packet. Its successor may take over
        # after an hour, or immediately when the owner explicitly releases it.
        name = f"{week}-{uuid4().hex}.json"
        write_json(folder / name, {"week": week, "candidates": pending})
        state["claim"] = {"week": week, "owner": run.name, "packet": name,
                          "expires": (now + timedelta(hours=1)).timestamp()}
        return {"review": str(folder / name)}


def review(run, data, now):
    with locked_state(run.parent) as (folder, state):
        claim = state["claim"]
        if not claim or claim["owner"] != run.name or required(data, "packet") != claim["packet"]:
            raise ValueError("run does not hold this weekly review packet")
        candidates = read_json(folder / claim["packet"])["candidates"]
        decisions = data.get("decisions")
        if not isinstance(decisions, dict) or decisions.keys() != candidates.keys():
            raise ValueError("provide one decision for every candidate in this packet")
        for key, candidate in candidates.items():
            if latest(state, key) != candidate["previous"]:
                raise ValueError(f"{key} changed during review; release and request a fresh packet")
            decision = decisions[key]
            if not isinstance(decision, dict):
                raise ValueError(f"{key} requires a review decision")
            status = required(decision, "status")
            if status not in ("accepted", "deferred", "rejected"):
                raise ValueError(f"unknown review status for {key}: {status}")
            entry = {"status": status, "reason": required(decision, "reason"),
                     "seen": sorted(candidate["observations"]), "at": now.isoformat(), "packet": claim["packet"]}
            if status == "accepted":
                entry.update(check=required(decision, "check"), change=required(decision, "change"),
                             regression=required(decision, "regression"))
            state["history"].setdefault(key, []).append(entry)
        state.update(week=claim["week"], claim=None)
        return {"reviewed": sorted(candidates), "week": claim["week"]}


def release(run):
    with locked_state(run.parent) as (_, state):
        claim = state["claim"]
        if claim and claim["owner"] == run.name:
            state["claim"] = None
            return {"released": True}
        return {"released": False}


def checks(run):
    with locked_state(run.parent) as (_, state):
        result = []
        pending = []
        for key, rows in observations(run.parent, state).items():
            prior = latest(state, key)
            status = prior.get("status")
            if status in ("accepted", "integrated"):
                result.append({"key": key, "status": status, "check": prior["check"]})
            if status == "accepted":
                pending.append({"key": key, "change": prior["change"], "regression": prior["regression"]})
            # Surface newly filed observations immediately. Only the weekly
            # reviewer can promote the proposed check into an accepted one.
            seen = set(prior.get("seen", []))
            for check in sorted({row["check"] for ident, row in rows.items() if ident not in seen}):
                result.append({"key": key, "status": "candidate", "check": check})
        return {"checks": result, "pending_pr": pending}


def integrate(run, data, now, source_repo):
    key, url = required(data, "key"), required(data, "pr")
    match = re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/pull/([1-9][0-9]*)", url)
    if not match:
        raise ValueError("pr must be the full URL of the reviewed plugin pull request")
    validation = required(data, "validation")
    if not (source_repo / ".git").exists():
        raise ValueError("integrate must run from the plugin source checkout")
    remote = subprocess.run(["git", "remote", "get-url", "origin"], cwd=source_repo,
                            text=True, stdout=subprocess.PIPE, check=True).stdout.strip()
    slug = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                        r"([\w.-]+/[\w.-]+)", remote.removesuffix(".git"))
    if not slug or url != f"https://github.com/{slug[1]}/pull/{match[1]}":
        raise ValueError("the pull request belongs to a different repository")
    pr = json.loads(subprocess.check_output(
        ["gh", "pr", "view", match.group(1), "--repo", slug[1], "--json", "state,mergeCommit"],
        cwd=source_repo, text=True))
    if pr["state"] != "MERGED" or not (pr.get("mergeCommit") or {}).get("oid"):
        raise ValueError("the pull request has not merged")
    with locked_state(run.parent) as (_, state):
        prior = latest(state, key)
        if prior.get("status") == "integrated" and prior["pr"] == url:
            return {"integrated": key, "pr": url}
        if prior.get("status") != "accepted":
            raise ValueError(f"{key} must have an accepted improvement")
        state["history"][key].append({**prior, "status": "integrated", "at": now.isoformat(),
                                     "pr": url, "commit": pr["mergeCommit"]["oid"],
                                     "validation": validation})
        return {"integrated": key, "pr": url}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("record", "weekly", "decide", "release", "checks", "integrate"))
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()
    run = args.run_dir.resolve(strict=True)
    if not (run / "state.md").is_file():
        raise ValueError("expected a research run directory containing state.md")
    now = datetime.now(timezone.utc)
    if args.operation in ("record", "decide", "integrate"):
        data = json.load(sys.stdin)
        if not isinstance(data, dict):
            raise ValueError("expected a JSON object")
        if args.operation == "record":
            result = record(run, data)
        elif args.operation == "decide":
            result = review(run, data, now)
        else:
            result = integrate(run, data, now, Path(__file__).resolve().parents[1])
    elif args.operation == "weekly":
        result = weekly(run, now)
    elif args.operation == "release":
        result = release(run)
    else:
        result = checks(run)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        sys.exit(f"harness lessons: {exc}")

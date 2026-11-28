"""The review ledger of one review stage of a run: reviews/<stage>/ledger.json.

A stage (plan, approval, evidence or presentation) is reviewed in rounds, one per
revision of its inputs. The ledger records every finding a reviewer raised at that
stage under a stable id (``presentation-3``), each later re-check of it by the
reviewer that raised it, and each response of the hub. Every later round is shown
the ledger, so a reviewer sees what was raised, how the hub answered and what is
already settled, and must re-check each of its own open findings rather than
re-derive the review from scratch. docs/WORKFLOW.md (Review ledger) gives the
protocol; templates/review/instructions.md tells the reviewers.

A finding's current status and blocking flag are those of its latest re-check.
Only open blocking findings make a review ask for revision (``decision``).
Rounds are grouped into cycles: methods_review.py caps the rounds in one cycle of
a capped stage, and a new cycle starts only with a recorded reason, given with the
round that starts it or armed beforehand (``pending_cycle``) by the decision that
warrants it.

A round certifies what it reviewed (docs/WORKFLOW.md, the certified range): a
new finding in a later round of a stage (in any cycle) blocks only when one of
its sources (the reviewed inputs it concerns) changed since the round that last
reviewed it, or when it reopens a settled finding. Otherwise it is recorded as
non-blocking (``certified``), and so is a re-check that would turn a
non-blocking finding into a blocking one on unchanged material.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path

from researcher_files import write_json

REVIEWS = "reviews"   # the run folder holding each stage's ledger and receipts: reviews/<stage>/
STAGES = ("plan", "approval", "evidence", "presentation")
STATUSES = ("open", "resolved")
DISPOSITIONS = ("fixed", "limit", "declined")
FIRST_CYCLE_REASON = "first review of this stage"
# Each finding a receipt records (Ledger.record_round) has these keys and "reopens";
# a new finding also names its "sources".
RECEIPT_FINDING_KEYS = frozenset({"id", "status", "blocking", "title", "text"})
NEW_FINDING_KEYS = frozenset({"blocking", "title", "text", "reopens", "sources"})
# Why a finding a reviewer marked blocking was recorded as non-blocking.
CERTIFIED = ("its sources were all reviewed unchanged in an earlier round of this stage, and it reopens no "
             "settled finding: a later round blocks only on material changed since it was reviewed (certified range)")


def _text(value, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}: expected nonempty text")
    return value.strip()


def _flag(value, label: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{label}: expected true or false")
    return value


def _status(value, label: str) -> str:
    if value not in STATUSES:
        raise ValueError(f"{label}: expected one of {', '.join(STATUSES)}")
    return value


def decision(stated: str, findings: list[dict]) -> str:
    """The decision a review records: a stated stop stands, and otherwise the
    review asks for revision exactly when one of its findings is open and blocking."""
    if stated == "stop":
        return "stop"
    return "revise" if any(f["status"] == "open" and f["blocking"] for f in findings) else "approve"


@dataclass
class Ledger:
    """One stage's findings, rounds and responses, as stored in its ledger file."""
    path: Path
    stage: str
    rounds: list[dict]
    findings: list[dict]
    # The reason for a new cycle that the stage's next round starts, armed by the
    # decision that warrants it before that round runs.
    pending_cycle: str | None = None

    @classmethod
    def load(cls, run: Path, stage: str) -> "Ledger":
        """The stage's ledger, or an empty one if the stage has no recorded round.
        Raises ValueError for a file that is not a ledger of this stage."""
        if stage not in STAGES:
            raise ValueError(f"unknown review stage: {stage}")
        path = run / REVIEWS / stage / "ledger.json"
        if not path.is_file():
            return cls(path, stage, [], [])
        data = json.loads(path.read_text(encoding="utf-8"))
        if (not isinstance(data, dict) or data.get("stage") != stage
                or not isinstance(data.get("rounds"), list) or not isinstance(data.get("findings"), list)):
            raise ValueError(f"invalid review ledger: {path}")
        for finding in data["findings"]:
            if (not isinstance(finding, dict) or not isinstance(finding.get("events"), list)
                    or not any(event.get("by") == "reviewer" for event in finding["events"])):
                raise ValueError(f"invalid finding in review ledger: {path}")
        pending = data.get("pending_cycle")
        if pending is not None and not (isinstance(pending, str) and pending.strip()):
            raise ValueError(f"invalid pending cycle in review ledger: {path}")
        return cls(path, stage, data["rounds"], data["findings"], pending)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {"stage": self.stage, "rounds": self.rounds, "findings": self.findings}
        if self.pending_cycle:
            data["pending_cycle"] = self.pending_cycle
        write_json(self.path, data)

    def arm_cycle(self, reason: str) -> None:
        """Have the stage's next round start a new cycle, for `reason`."""
        self.pending_cycle = _text(reason, "cycle reason")

    @staticmethod
    def current(finding: dict) -> dict:
        """A finding's latest re-check by its reviewer."""
        return [event for event in finding["events"] if event["by"] == "reviewer"][-1]

    def status(self, finding: dict) -> tuple[str, bool]:
        latest = self.current(finding)
        return latest["status"], latest["blocking"]

    def find(self, finding_id: str) -> dict:
        for finding in self.findings:
            if finding["id"] == finding_id:
                return finding
        raise ValueError(f"no finding {finding_id} in the {self.stage} review ledger")

    def open_ids(self, role: str) -> list[str]:
        """The open findings `role` raised, which its next review must re-check."""
        return [f["id"] for f in self.findings if f["role"] == role and self.status(f)[0] == "open"]

    def settled_ids(self) -> list[str]:
        """Findings a reviewer has resolved, which a new finding may reopen."""
        return [f["id"] for f in self.findings if self.status(f)[0] == "resolved"]

    def open_blocking(self) -> list[dict]:
        return [f for f in self.findings if self.status(f) == ("open", True)]

    def unanswered(self) -> list[str]:
        """Open blocking findings with no hub response since their latest re-check."""
        return [f["id"] for f in self.open_blocking() if f["events"][-1]["by"] == "reviewer"]

    def cycle(self) -> int:
        return self.rounds[-1]["cycle"] if self.rounds else 0

    def rounds_in_cycle(self) -> int:
        """Rounds in the current cycle; none once a new cycle is armed."""
        if self.pending_cycle:
            return 0
        return sum(1 for entry in self.rounds if entry["cycle"] == self.cycle())

    def round_of(self, revision: str) -> int | None:
        """The latest round that reviewed `revision`, if any."""
        rounds = [entry["round"] for entry in self.rounds if entry["revision"] == revision]
        return rounds[-1] if rounds else None

    def responses_after(self, round_number: int) -> list[str]:
        """Findings the hub responded to after round `round_number`."""
        return [f["id"] for f in self.findings
                if any(e["by"] == "hub" and e["after_round"] >= round_number for e in f["events"])]

    def response_schema(self, template: dict, role: str, sources: list[str], settled_elsewhere: list[str]) -> dict:
        """The verdict schema for `role`'s next review: it must re-check each of its
        open findings by id, a new finding names its sources among the reviewed
        inputs `sources`, and it may reopen only a settled finding, of this stage
        or of a stage it builds on (`settled_elsewhere`)."""
        schema = json.loads(json.dumps(template))
        rechecks = schema["properties"]["rechecks"]
        item = rechecks.pop("additionalProperties")
        open_ids = self.open_ids(role)
        rechecks.update(properties={finding: item for finding in open_ids}, required=open_ids,
                        additionalProperties=False)
        new = schema["properties"]["new_findings"]["items"]["properties"]
        new["reopens"]["enum"] = ["", *self.settled_ids(), *settled_elsewhere]
        new["sources"]["items"]["enum"] = list(sources)
        return schema

    def context(self) -> str:
        """The ledger as a reviewer sees it: each finding with its current state and history."""
        shown = []
        for finding in self.findings:
            status, blocking = self.status(finding)
            shown.append({"id": finding["id"], "raised_by": finding["role"], "title": finding["title"],
                          "reopens": finding["reopens"], "status": status, "blocking": blocking,
                          "history": finding["events"]})
        return json.dumps(shown, ensure_ascii=False, indent=1)

    def check_response(self, role: str, response: dict, sources: list[str], settled_elsewhere: list[str]) -> dict:
        """Validate a reviewer's structured response against this ledger, the
        reviewed inputs `sources` and the settled findings of the stages it builds on."""
        if not isinstance(response, dict) or set(response) != {"decision", "summary", "rechecks", "new_findings"}:
            raise ValueError("review response must contain decision, summary, rechecks and new_findings")
        if response["decision"] not in ("approve", "revise", "stop"):
            raise ValueError("invalid review decision")
        _text(response["summary"], "review summary")
        rechecks, new = response["rechecks"], response["new_findings"]
        if not isinstance(rechecks, dict) or sorted(rechecks) != sorted(self.open_ids(role)):
            raise ValueError(f"the review must re-check exactly its open findings: {self.open_ids(role)}")
        for finding_id, check in rechecks.items():
            if not isinstance(check, dict) or set(check) != {"status", "blocking", "text"}:
                raise ValueError(f"re-check of {finding_id} must give status, blocking and text")
            _status(check["status"], f"re-check of {finding_id}")
            _flag(check["blocking"], f"re-check of {finding_id}")
            _text(check["text"], f"re-check of {finding_id}")
        if not isinstance(new, list):
            raise ValueError("new_findings must be an array")
        settled = [*self.settled_ids(), *settled_elsewhere]
        for index, finding in enumerate(new):
            if not isinstance(finding, dict) or set(finding) != NEW_FINDING_KEYS:
                raise ValueError(f"new finding {index + 1} must give blocking, title, text, reopens and sources")
            _flag(finding["blocking"], f"new finding {index + 1}")
            _text(finding["title"], f"new finding {index + 1} title")
            _text(finding["text"], f"new finding {index + 1}")
            if finding["reopens"] and finding["reopens"] not in settled:
                raise ValueError(f"new finding {index + 1} reopens {finding['reopens']}, which is not settled")
            if (not isinstance(finding["sources"], list)
                    or not all(isinstance(name, str) and name in sources for name in finding["sources"])):
                raise ValueError(f"new finding {index + 1}: sources must name reviewed inputs")
        return response

    def record_round(self, revision: str, reports: list[tuple[str, dict]], cycle_reason: str | None,
                     changed: set[str] | None = None) -> list[tuple[list[dict], str]]:
        """Record one round's checked responses, (role, response) in order, under the
        next round number. Return, for each review, its findings as its receipt states
        them (its re-checks and its new findings, each with its id) and its decision.
        A cycle reason, or else an armed one, starts a new cycle with this round.

        `changed` holds the reviewed inputs that changed since the round of this
        stage that last reviewed them, or that none reviewed (None on the stage's
        first round: nothing is certified yet). A new blocking finding that reopens
        no settled finding and names none of them among its sources is recorded as
        non-blocking, as is a re-check that would make a non-blocking finding
        blocking when none of its sources changed (the certified range)."""
        number = len(self.rounds) + 1
        reason = cycle_reason or self.pending_cycle or (FIRST_CYCLE_REASON if not self.rounds else None)
        self.pending_cycle = None
        entry = {"round": number, "cycle": self.cycle() + (1 if reason else 0), "revision": revision,
                 "recorded_at": datetime.now(timezone.utc).isoformat(), "decisions": {}}
        if reason:
            entry["cycle_reason"] = reason

        def certified(blocking: bool, sources: list[str]) -> dict:
            """What a reviewer's blocking flag records: blocking stays blocking only on changed material."""
            if blocking and changed is not None and not set(sources) & changed:
                return {"blocking": False, "stated_blocking": True, "certified": CERTIFIED}
            return {"blocking": blocking}

        stated = []
        for role, response in reports:
            findings = []
            for finding_id, check in response["rechecks"].items():
                finding = self.find(finding_id)
                flag = {"blocking": check["blocking"]}
                if check["status"] == "open" and not self.status(finding)[1]:
                    flag = certified(check["blocking"], finding.get("sources", []))
                event = {"by": "reviewer", "round": number, **check, **flag}
                finding["events"].append(event)
                findings.append({"id": finding_id, "title": finding["title"], "reopens": finding["reopens"],
                                 **{k: v for k, v in event.items() if k not in ("by", "round")}})
            for new in response["new_findings"]:
                finding_id = f"{self.stage}-{len(self.findings) + 1}"
                flag = {"blocking": new["blocking"]} if new["reopens"] else certified(new["blocking"], new["sources"])
                self.findings.append({"id": finding_id, "role": role, "title": new["title"], "reopens": new["reopens"],
                                      "sources": new["sources"],
                                      "events": [{"by": "reviewer", "round": number, "status": "open",
                                                  "text": new["text"], **flag}]})
                findings.append({"id": finding_id, "status": "open", **new, **flag})
            entry["decisions"][role] = decision(response["decision"], findings)
            stated.append((findings, entry["decisions"][role]))
        self.rounds.append(entry)
        return stated

    def respond(self, finding_id: str, disposition: str, note: str) -> None:
        """Record the hub's response to an open finding."""
        if disposition not in DISPOSITIONS:
            raise ValueError(f"disposition must be one of {', '.join(DISPOSITIONS)}")
        finding = self.find(finding_id)
        if self.status(finding)[0] != "open":
            raise ValueError(f"{finding_id} is already resolved")
        finding["events"].append({"by": "hub", "after_round": self.rounds[-1]["round"], "response": disposition,
                                  "note": _text(note, "response note"),
                                  "recorded_at": datetime.now(timezone.utc).isoformat()})

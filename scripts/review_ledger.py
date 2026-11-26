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
a capped stage, and a new cycle starts only with a recorded reason.
"""
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path

from researcher_files import write_json

STAGES = ("plan", "approval", "evidence", "presentation")
STATUSES = ("open", "resolved")
DISPOSITIONS = ("fixed", "limit", "declined")
FIRST_CYCLE_REASON = "first review of this stage"
# Each finding a receipt records (Ledger.record_round) has these keys and "reopens".
RECEIPT_FINDING_KEYS = frozenset({"id", "status", "blocking", "title", "text"})


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

    @classmethod
    def load(cls, run: Path, stage: str) -> "Ledger":
        """The stage's ledger, or an empty one if the stage has no recorded round.
        Raises ValueError for a file that is not a ledger of this stage."""
        if stage not in STAGES:
            raise ValueError(f"unknown review stage: {stage}")
        path = run / "reviews" / stage / "ledger.json"
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
        return cls(path, stage, data["rounds"], data["findings"])

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_json(self.path, {"stage": self.stage, "rounds": self.rounds, "findings": self.findings})

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
        return sum(1 for entry in self.rounds if entry["cycle"] == self.cycle())

    def round_of(self, revision: str) -> int | None:
        """The latest round that reviewed `revision`, if any."""
        rounds = [entry["round"] for entry in self.rounds if entry["revision"] == revision]
        return rounds[-1] if rounds else None

    def responses_after(self, round_number: int) -> list[str]:
        """Findings the hub responded to after round `round_number`."""
        return [f["id"] for f in self.findings
                if any(e["by"] == "hub" and e["after_round"] >= round_number for e in f["events"])]

    def response_schema(self, template: dict, role: str) -> dict:
        """The verdict schema for `role`'s next review: it must re-check each of its
        open findings by id, and a new finding may reopen only a settled one."""
        schema = json.loads(json.dumps(template))
        rechecks = schema["properties"]["rechecks"]
        item = rechecks.pop("additionalProperties")
        open_ids = self.open_ids(role)
        rechecks.update(properties={finding: item for finding in open_ids}, required=open_ids,
                        additionalProperties=False)
        schema["properties"]["new_findings"]["items"]["properties"]["reopens"]["enum"] = ["", *self.settled_ids()]
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

    def check_response(self, role: str, response: dict) -> dict:
        """Validate a reviewer's structured response against this ledger."""
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
        settled = self.settled_ids()
        for index, finding in enumerate(new):
            if not isinstance(finding, dict) or set(finding) != {"blocking", "title", "text", "reopens"}:
                raise ValueError(f"new finding {index + 1} must give blocking, title, text and reopens")
            _flag(finding["blocking"], f"new finding {index + 1}")
            _text(finding["title"], f"new finding {index + 1} title")
            _text(finding["text"], f"new finding {index + 1}")
            if finding["reopens"] and finding["reopens"] not in settled:
                raise ValueError(f"new finding {index + 1} reopens {finding['reopens']}, which is not settled")
        return response

    def record_round(self, revision: str, reports: list[tuple[str, dict]],
                     cycle_reason: str | None) -> list[tuple[list[dict], str]]:
        """Record one round's checked responses, (role, response) in order, under the
        next round number. Return, for each review, its findings as its receipt states
        them (its re-checks and its new findings, each with its id) and its decision.
        A cycle reason starts a new cycle with this round."""
        number = len(self.rounds) + 1
        reason = cycle_reason or (FIRST_CYCLE_REASON if not self.rounds else None)
        entry = {"round": number, "cycle": self.cycle() + (1 if reason else 0), "revision": revision,
                 "recorded_at": datetime.now(timezone.utc).isoformat(), "decisions": {}}
        if reason:
            entry["cycle_reason"] = reason
        stated = []
        for role, response in reports:
            findings = []
            for finding_id, check in response["rechecks"].items():
                finding = self.find(finding_id)
                finding["events"].append({"by": "reviewer", "round": number, **check})
                findings.append({"id": finding_id, "title": finding["title"], "reopens": finding["reopens"], **check})
            for new in response["new_findings"]:
                finding_id = f"{self.stage}-{len(self.findings) + 1}"
                self.findings.append({"id": finding_id, "role": role, "title": new["title"], "reopens": new["reopens"],
                                      "events": [{"by": "reviewer", "round": number, "status": "open",
                                                  "blocking": new["blocking"], "text": new["text"]}]})
                findings.append({"id": finding_id, "status": "open", **new})
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

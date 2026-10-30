#!/usr/bin/env python3
"""Pre-flight sanity checks for researcher experiments.

Each check exists because a past autonomous run reported a conclusion that the
pipeline could not support:

  degeneracy   Generated text is fluent, not collapsed. Three fine-tunes that
               only emitted "QuestionQuestion..." passed the old check, and the
               run concluded scheming cannot be induced at 3-8B (tasks#1863).
  training     A loss curve is finite and moved in the right direction.
  separation   A metric separates known-positive from known-negative examples
               before it is used to measure an effect. #1898's "localisation"
               score was ~0.98 for the routed model AND the unrouted control.
  compare      A treatment-vs-control comparison with the right unit of
               analysis: repeated samples of one prompt are not independent
               (clustered by prompt/scenario), seeds are counted, intervals are
               reported (tasks#1859 treated 5 repeats x 20 scenarios as n=100).

Usage (each prints a JSON report on stdout and a summary on stderr):

  preflight_checks.py degeneracy outputs.json [--field text] [--reference base_outputs.json]
                                 [--max-degenerate-frac 0.1]
  preflight_checks.py training losses.json|train.log
  preflight_checks.py separation --positive pos.json --negative neg.json [--value score]
                                 [--cluster prompt_id] [--min-auroc 0.8] [--lo 0 --hi 1] [--lower-is-positive]
  preflight_checks.py compare records.jsonl --a control --b treatment [--cluster prompt_id]
                              [--n-comparisons 3]

Inputs are JSON lists, JSONL, or plain text (one item per line). Items may be
objects; name the field to read with --field (texts) or --value (numbers), or
leave it out to read the first of the usual field names an object has. An
object without that field is bad input. --cluster names the field holding each
record's prompt, scenario or item id, and every record must have one.

training reads a JSON list of losses (numbers, or objects with a "loss" field),
an object holding one (such as {"losses": [...]}), or JSONL. A null loss counts
as non-finite, so the check fails; an object without "loss" is bad input. A
file that is not JSON is a text log, and every "loss: X" or "loss=X" in it is
read.

compare's p_adjusted is the Bonferroni-adjusted p for a family of
--n-comparisons tests. Without that flag p_adjusted is null and the status is
WARN.

Every report has "params": the settings that decided its result, defaults
included (thresholds, saturation bounds, the fields read, the family size, the
resampling iterations and seed). separation and compare also give the "design":
"paired" when both groups have exactly the same units, else "independent".

Exit status: 0 PASS (or WARN), 1 FAIL, 2 bad input. Standard library only, so
it runs in any experiment environment; it can also be imported.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
import statistics
import sys
import zlib
from collections import Counter, defaultdict
from collections.abc import Callable
from pathlib import Path

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
_SEVERITY = (PASS, WARN, FAIL)


def worse(status: str, other: str) -> str:
    """The more severe of two statuses (PASS < WARN < FAIL)."""
    return max(status, other, key=_SEVERITY.index)


# --------------------------------------------------------------------------
# Input loading
# --------------------------------------------------------------------------

# Keys under which a JSON object can hold the list of items.
LIST_KEYS = ("outputs", "samples", "generations", "records", "values", "scores", "losses", "data")
# The fields read from an object item when no field is named: the first one present.
TEXT_FIELDS = ("text", "output", "completion", "response", "generation")
NUMBER_FIELDS = ("value", "score", "loss")


def load_items(path: str | Path) -> list:
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    stripped = text.strip()
    if not stripped:
        return []
    if stripped[0] in "[{":
        return json_items(stripped)
    return [line for line in text.splitlines() if line.strip()]


def json_items(text: str) -> list:
    """The items of a JSON document or of JSONL; json.JSONDecodeError if the text is neither.

    An object holding a list under one of LIST_KEYS gives that list; any other
    single value is one item.
    """
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    if isinstance(data, dict):
        for key in LIST_KEYS:
            if isinstance(data.get(key), list):
                return data[key]
    return data if isinstance(data, list) else [data]


def field_values(items: list, field: str | None, defaults: tuple[str, ...], convert: Callable) -> list:
    """`convert` applied to each item, or to the field it reads from an object item.

    That field is `field`, or with none named the first of `defaults` the object
    has. An object without it is an error, and so is a value `convert` rejects.
    """
    values = []
    for index, item in enumerate(items):
        if isinstance(item, dict):
            key = field or next((k for k in defaults if k in item), None)
            if key is None:
                raise ValueError(f"item {index} has none of the fields {', '.join(defaults)} "
                                 f"(it has {sorted(item)}); name the one to read")
            if key not in item:
                raise ValueError(f"item {index} has no {key!r} field (it has {sorted(item)})")
            item = item[key]
        try:
            values.append(convert(item))
        except (TypeError, ValueError) as error:
            raise ValueError(f"item {index}: {error}") from error
    return values


def as_text(value: object) -> str:
    """A generation as text; a null generation is empty, which the degeneracy check flags."""
    return "" if value is None else str(value)


def as_loss(value: object) -> float:
    """A loss as a float. JSON has no NaN, so loggers write a NaN loss as null."""
    return math.nan if value is None else float(value)


def cluster_ids(records: list, cluster: str) -> list:
    """Each record's `cluster` id.

    A record without one is an error: counting it as its own unit would quietly
    change the unit of analysis.
    """
    missing = [r for r in records if not isinstance(r, dict) or r.get(cluster) is None]
    if missing:
        raise ValueError(f"{len(missing)} of {len(records)} records have no {cluster!r} id, "
                         f"e.g. {str(missing[0])[:120]}")
    return [r[cluster] for r in records]


# --------------------------------------------------------------------------
# Degeneracy
# --------------------------------------------------------------------------

_REPEAT_RE = re.compile(r"(.{1,50}?)\1{3,}", re.DOTALL)
_WORD_RE = re.compile(r"\w+", re.UNICODE)


def repeat_coverage(text: str) -> float:
    """Fraction of characters inside a unit repeated 4+ times back to back."""
    if not text:
        return 0.0
    covered = 0
    for match in _REPEAT_RE.finditer(text):
        if match.group(1).strip():
            covered += match.end() - match.start()
    return covered / len(text)


def compression_ratio(text: str) -> float:
    raw = text.encode("utf-8")
    return len(zlib.compress(raw, 9)) / len(raw) if raw else 1.0


def duplicate_line_fraction(text: str) -> float:
    lines = [line.strip() for line in text.splitlines() if len(line.strip()) >= 20]
    if len(lines) < 4:
        return 0.0
    counts = Counter(lines)
    return sum(c for c in counts.values() if c > 1) / len(lines)


def distinct_1(text: str) -> float | None:
    words = [w.lower() for w in _WORD_RE.findall(text)]
    if len(words) < 30:
        return None
    return len(set(words)) / len(words)


def non_text_fraction(text: str) -> float:
    if not text:
        return 0.0
    bad = sum(1 for ch in text if ch == "�" or (ord(ch) < 32 and ch not in "\n\r\t"))
    return bad / len(text)


def sample_report(text: str) -> dict:
    stripped = text.strip()
    report = {
        "chars": len(text),
        "repeat_coverage": round(repeat_coverage(stripped), 3),
        "compression_ratio": round(compression_ratio(stripped), 3),
        "duplicate_line_fraction": round(duplicate_line_fraction(stripped), 3),
        "distinct_1": distinct_1(stripped),
        "non_text_fraction": round(non_text_fraction(stripped), 3),
    }
    reasons = []
    if not stripped:
        reasons.append("empty")
    if report["repeat_coverage"] >= 0.3:
        reasons.append("repeated-substring loop")
    if len(stripped) >= 300 and report["compression_ratio"] < 0.2:
        reasons.append("highly compressible (looping)")
    if report["duplicate_line_fraction"] >= 0.5:
        reasons.append("repeated lines")
    if report["distinct_1"] is not None and report["distinct_1"] < 0.2:
        reasons.append("tiny vocabulary")
    if report["non_text_fraction"] > 0.05:
        reasons.append("garbage characters")
    report["degenerate"] = bool(reasons)
    report["reasons"] = reasons
    return report


def check_degeneracy(texts: list[str], *, max_degenerate_frac: float = 0.1,
                     reference: list[str] | None = None) -> dict:
    params = {"max_degenerate_frac": max_degenerate_frac, "reference": reference is not None}
    if not texts:
        return {"check": "degeneracy", "status": FAIL, "params": params, "messages": ["no samples to check"]}
    samples = [sample_report(t) for t in texts]
    degenerate = [i for i, s in enumerate(samples) if s["degenerate"]]
    frac = len(degenerate) / len(texts)
    status, messages = PASS, []
    if frac > max_degenerate_frac:
        status = FAIL
        messages.append(f"{len(degenerate)}/{len(texts)} samples degenerate ({frac:.0%} > {max_degenerate_frac:.0%})")
    long_texts = [t.strip() for t in texts if len(t.strip()) >= 20]
    if len(long_texts) >= 5:
        top, count = Counter(long_texts).most_common(1)[0]
        if count / len(long_texts) > 0.5:
            status = worse(status, WARN)
            messages.append(f"mode collapse: {count}/{len(long_texts)} outputs are identical ({top[:60]!r}...)")
    report = {
        "check": "degeneracy",
        "params": params,
        "n": len(texts),
        "degenerate_fraction": round(frac, 3),
        "examples": [{"index": i, "reasons": samples[i]["reasons"], "text": texts[i][:200]} for i in degenerate[:5]],
    }
    if reference is not None:
        ref = check_degeneracy(reference, max_degenerate_frac=1.0)
        report["reference_degenerate_fraction"] = ref["degenerate_fraction"]
        if frac - ref["degenerate_fraction"] > 0.1:
            status = FAIL
            messages.append(f"degenerate fraction rose from {ref['degenerate_fraction']:.0%} (reference) to {frac:.0%}")
        ref_len = statistics.mean(len(t) for t in reference) if reference else 0
        cur_len = statistics.mean(len(t) for t in texts)
        if ref_len and not 0.2 <= cur_len / ref_len <= 5:
            status = worse(status, WARN)
            messages.append(f"mean output length changed {cur_len / ref_len:.1f}x vs reference")
    report["status"] = status
    report["messages"] = messages or [f"{len(texts)} samples look fluent"]
    return report


# --------------------------------------------------------------------------
# Training curve
# --------------------------------------------------------------------------

_LOSS_RE = re.compile(r"""['"]?\b(?:train_)?loss['"]?\s*[:=]\s*['"]?(-?[0-9.]+(?:[eE][-+]?\d+)?|nan|inf|-inf)""", re.IGNORECASE)


def losses_from_file(path: str | Path) -> tuple[list[float], str]:
    """The losses in a file, and how it was read: "json" or "text log".

    JSON and JSONL are read by json_items, like every other input, and each
    item is a loss or an object with a "loss" field. Only a file that is
    neither is a text log, scraped with _LOSS_RE.
    """
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        items = json_items(text.strip())
    except json.JSONDecodeError:
        return [float(m.group(1)) for m in _LOSS_RE.finditer(text)], "text log"
    return field_values(items, "loss", (), as_loss), "json"


def check_training(losses: list[float]) -> dict:
    status, messages, params = PASS, [], {}
    if len(losses) < 4:
        return {"check": "training", "status": FAIL, "params": params, "n": len(losses),
                "messages": [f"only {len(losses)} loss values found; log the loss every few steps"]}
    if any(not math.isfinite(x) for x in losses):
        return {"check": "training", "status": FAIL, "params": params, "n": len(losses),
                "messages": ["non-finite loss (nan, inf, or null in JSON)"]}
    k = max(1, len(losses) // 10)
    start, end = statistics.mean(losses[:k]), statistics.mean(losses[-k:])
    scale = abs(start) or 1e-12  # sign-aware: some objectives are negative
    if end > start + 0.1 * scale:
        status = FAIL
        messages.append(f"loss diverged: {start:.4g} -> {end:.4g}")
    elif end > start - 0.02 * scale:
        status = WARN
        messages.append(f"loss barely moved: {start:.4g} -> {end:.4g}")
    if min(losses) >= 0 and end < 0.01:
        status = worse(status, WARN)
        messages.append(f"near-zero final loss {end:.3g}: likely memorisation; evaluate on held-out data")
    window = losses[: max(5, k)]
    for i in range(len(window), len(losses)):
        median = statistics.median(losses[max(0, i - 20):i])
        if median > 0 and losses[i] > 3 * median:
            status = worse(status, WARN)
            messages.append(f"loss spike at step index {i}: {losses[i]:.4g} vs running median {median:.4g}")
            break
    return {"check": "training", "status": status, "params": params, "n": len(losses),
            "start": round(start, 6), "end": round(end, 6),
            "messages": messages or [f"loss decreased {start:.4g} -> {end:.4g}"]}


# --------------------------------------------------------------------------
# Statistics helpers
# --------------------------------------------------------------------------

def auroc(positive: list[float], negative: list[float]) -> float:
    """P(score of a random positive > a random negative), ties count half."""
    pooled = sorted([(v, 1) for v in positive] + [(v, 0) for v in negative])
    ranks, i = [0.0] * len(pooled), 0
    while i < len(pooled):
        j = i
        while j + 1 < len(pooled) and pooled[j + 1][0] == pooled[i][0]:
            j += 1
        for r in range(i, j + 1):
            ranks[r] = (i + j) / 2 + 1
        i = j + 1
    rank_sum = sum(rank for rank, (_, is_pos) in zip(ranks, pooled) if is_pos)
    n_pos, n_neg = len(positive), len(negative)
    return (rank_sum - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)


def cluster_means(values: list[float], clusters: list | None, group: str) -> dict:
    """Mean per independent unit, keyed by cluster id.

    Without cluster ids (`clusters` is None) each value is its own unit, keyed
    uniquely to `group`, so two groups are only ever paired on cluster ids they
    explicitly share — never by row position (which made sorted inputs look
    hugely significant). Callers take the ids from cluster_ids, which refuses
    a record without one.
    """
    grouped = defaultdict(list)
    for index, value in enumerate(values):
        cid = clusters[index] if clusters is not None else None
        grouped[("_row", group, index) if cid is None else cid].append(value)
    return {c: statistics.mean(vs) for c, vs in grouped.items()}


# Resampling settings for the bootstrap interval and the permutation p-value.
BOOTSTRAP_ITERS, PERMUTATION_ITERS, RESAMPLING_SEED = 2000, 5000, 0


def _paired_diffs(a: dict, b: dict) -> list[float] | None:
    """Per-unit differences b - a when both groups have the same 2+ units (a paired design), else None."""
    shared = sorted(set(a) & set(b), key=str)
    if len(shared) >= 2 and len(shared) == len(a) == len(b):
        return [b[c] - a[c] for c in shared]
    return None


def design(a: dict, b: dict) -> str:
    """How the two groups are compared: "paired" or "independent"."""
    return "independent" if _paired_diffs(a, b) is None else "paired"


def bootstrap_diff_ci(a: dict, b: dict, *, iters: int = BOOTSTRAP_ITERS, seed: int = RESAMPLING_SEED,
                      level: float = 0.95) -> tuple[float, float]:
    """CI for mean(b) - mean(a), resampling clusters (paired when clusters are shared)."""
    rng = random.Random(seed)
    d = _paired_diffs(a, b)
    diffs = []
    if d is not None:
        for _ in range(iters):
            diffs.append(statistics.mean(rng.choice(d) for _ in d))
    else:
        av, bv = list(a.values()), list(b.values())
        for _ in range(iters):
            diffs.append(statistics.mean(rng.choice(bv) for _ in bv) - statistics.mean(rng.choice(av) for _ in av))
    diffs.sort()
    lo = diffs[int((1 - level) / 2 * iters)]
    hi = diffs[min(iters - 1, int((1 + level) / 2 * iters))]
    return lo, hi


def permutation_p(a: dict, b: dict, *, iters: int = PERMUTATION_ITERS, seed: int = RESAMPLING_SEED) -> float:
    rng = random.Random(seed)
    d = _paired_diffs(a, b)
    if d is not None:
        observed = abs(statistics.mean(d))
        hits = sum(abs(statistics.mean(x if rng.random() < 0.5 else -x for x in d)) >= observed - 1e-12
                   for _ in range(iters))
    else:
        av, bv = list(a.values()), list(b.values())
        observed = abs(statistics.mean(bv) - statistics.mean(av))
        pooled = av + bv
        hits = 0
        for _ in range(iters):
            rng.shuffle(pooled)
            if abs(statistics.mean(pooled[len(av):]) - statistics.mean(pooled[:len(av)])) >= observed - 1e-12:
                hits += 1
    return (hits + 1) / (iters + 1)


# --------------------------------------------------------------------------
# Metric separation
# --------------------------------------------------------------------------

def check_separation(positive: list[float], negative: list[float], *,
                     pos_clusters: list | None = None, neg_clusters: list | None = None,
                     min_auroc: float = 0.8, lo: float | None = None, hi: float | None = None,
                     higher_is_positive: bool = True) -> dict:
    """Does the metric tell known positives from known negatives?

    Given the metric's range (both lo and hi), it also fails a metric that has
    both groups at its ceiling or its floor.
    """
    if (lo is None) != (hi is None) or (lo is not None and hi <= lo):
        raise ValueError(f"the saturation check needs both bounds with lo < hi (got lo={lo}, hi={hi})")
    params = {"min_auroc": min_auroc, "lo": lo, "hi": hi, "saturation_checked": lo is not None,
              "higher_is_positive": higher_is_positive, "bootstrap_iters": BOOTSTRAP_ITERS, "seed": RESAMPLING_SEED}
    if not higher_is_positive:
        positive, negative = [-v for v in positive], [-v for v in negative]
        lo, hi = (-hi if hi is not None else None), (-lo if lo is not None else None)
    a = cluster_means(negative, neg_clusters, "negative")
    b = cluster_means(positive, pos_clusters, "positive")
    report = {"check": "separation", "params": params, "design": design(a, b),
              "n_positive": len(positive), "n_negative": len(negative),
              "independent_positive": len(b), "independent_negative": len(a)}
    if len(a) < 3 or len(b) < 3:
        report.update(status=FAIL, messages=[
            f"only {len(b)} positive / {len(a)} negative independent measurements; separation cannot be "
            "established from fewer than 3 per group (score items or seeds individually)"])
        return report
    mean_pos, mean_neg = statistics.mean(b.values()), statistics.mean(a.values())
    area = auroc(list(b.values()), list(a.values()))
    ci = bootstrap_diff_ci(a, b)
    report.update(mean_positive=round(mean_pos, 6), mean_negative=round(mean_neg, 6),
                  auroc=round(area, 3), diff_ci95=[round(ci[0], 6), round(ci[1], 6)])
    status, messages = PASS, []
    if area < min_auroc:
        status = FAIL
        messages.append(f"AUROC {area:.2f} < {min_auroc}: the metric does not separate positives from negatives")
    if ci[0] <= 0:
        status = FAIL
        messages.append(f"95% CI of the difference {ci[0]:.4g}..{ci[1]:.4g} includes zero or is negative")
    if params["saturation_checked"]:
        span = hi - lo
        near_hi = all(m >= hi - 0.05 * span for m in (mean_pos, mean_neg))
        near_lo = all(m <= lo + 0.05 * span for m in (mean_pos, mean_neg))
        if near_hi or near_lo:
            status = FAIL
            messages.append("saturated: both groups sit within 5% of the metric's "
                            f"{'ceiling' if near_hi else 'floor'}, so it cannot show a difference")
    report["status"] = status
    report["messages"] = messages or [f"separates: AUROC {area:.2f}, diff CI {ci[0]:.4g}..{ci[1]:.4g}"]
    return report


# --------------------------------------------------------------------------
# Treatment vs control comparison
# --------------------------------------------------------------------------

# Fields that usually identify the prompt/item a record was generated from.
ITEM_KEYS = ("prompt_id", "item_id", "scenario_id", "question_id", "prompt", "scenario", "item", "question")


def compare(records: list[dict], *, a: str, b: str, condition: str = "condition", value: str = "value",
            cluster: str | None = None, seed_field: str = "seed", n_comparisons: int | None = None) -> dict:
    """Treatment `b` against control `a`, over the independent units of each.

    p_adjusted is Bonferroni over a family of `n_comparisons` tests; it is null,
    with a warning, when the family size is not given.
    """
    not_objects = [r for r in records if not isinstance(r, dict)]
    if not_objects:
        raise ValueError(f"{len(not_objects)} of {len(records)} records are not JSON objects, "
                         f"e.g. {str(not_objects[0])[:120]}")
    if n_comparisons is not None and n_comparisons < 1:
        raise ValueError(f"n_comparisons must be at least 1 (got {n_comparisons})")
    groups = {name: [r for r in records if str(r.get(condition)) == name] for name in (a, b)}
    for name, rows in groups.items():
        if not rows:
            raise ValueError(f"no records with {condition}={name!r}")
    means, warnings, notes, detail = {}, [], [], {}
    for name, rows in groups.items():
        values = [float(r[value]) for r in rows]
        clusters = cluster_ids(rows, cluster) if cluster else None
        means[name] = cluster_means(values, clusters, name)
        seeds = sorted({str(r[seed_field]) for r in rows if seed_field in r})
        detail[name] = {"n_records": len(rows), "n_independent": len(means[name]),
                        "n_seeds": len(seeds) or None, "mean": round(statistics.mean(values), 6)}
        if seeds:
            per_seed = [statistics.mean(float(r[value]) for r in rows if str(r.get(seed_field)) == s) for s in seeds]
            detail[name]["seed_means"] = [round(x, 6) for x in per_seed]
            if len(seeds) < 3:
                warnings.append(f"{name}: {len(seeds)} seed(s); report as preliminary, a seed change may flip it")
        if cluster is None:
            for key in ITEM_KEYS:
                ids = [r[key] for r in rows if key in r]
                if ids and len(set(map(str, ids))) < len(ids):
                    warnings.append(f"{name}: {len(ids)} records share {len(set(map(str, ids)))} distinct {key} values; "
                                    f"pass --cluster {key} so repeated samples are not counted as independent")
                    break
        if cluster and len(rows) > len(means[name]):
            notes.append(f"{name}: {len(rows)} records but {len(means[name])} independent {cluster} clusters; "
                            "intervals and p-values use the clusters")
    lo, hi = bootstrap_diff_ci(means[a], means[b])
    p = permutation_p(means[a], means[b])
    if n_comparisons is None:
        p_adjusted = None
        warnings.append("family size not given, so p_adjusted is null: pass --n-comparisons with the number of "
                        "tests in the family (1 if this is the only one)")
    else:
        p_adjusted = round(min(1.0, p * n_comparisons), 5)
    params = {"a": a, "b": b, "condition": condition, "value": value, "cluster": cluster, "seed_field": seed_field,
              "n_comparisons": n_comparisons, "bootstrap_iters": BOOTSTRAP_ITERS,
              "permutation_iters": PERMUTATION_ITERS, "seed": RESAMPLING_SEED}
    return {"check": "compare", "status": WARN if warnings else PASS, "params": params,
            "design": design(means[a], means[b]),
            "conditions": detail,
            "difference": round(statistics.mean(means[b].values()) - statistics.mean(means[a].values()), 6),
            "diff_ci95": [round(lo, 6), round(hi, 6)],
            "p_value": round(p, 5), "p_adjusted": p_adjusted,
            "messages": warnings + notes or ["unit of analysis is explicit; interval and p-value reported"]}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def emit(report: dict) -> int:
    print(json.dumps(report, indent=2, default=str))
    print(f"[{report['status']}] {report['check']}: " + "; ".join(report.get("messages", [])), file=sys.stderr)
    return 1 if report["status"] == FAIL else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("degeneracy")
    p.add_argument("outputs")
    p.add_argument("--field")
    p.add_argument("--reference", help="outputs of the untrained/base model on the same prompts")
    p.add_argument("--max-degenerate-frac", type=float, default=0.1)

    p = sub.add_parser("training")
    p.add_argument("losses")

    p = sub.add_parser("separation")
    p.add_argument("--positive", required=True, help="scores on examples known to have the property")
    p.add_argument("--negative", required=True, help="scores on examples known not to have it")
    p.add_argument("--value")
    p.add_argument("--cluster")
    p.add_argument("--min-auroc", type=float, default=0.8)
    p.add_argument("--lo", type=float)
    p.add_argument("--hi", type=float)
    p.add_argument("--lower-is-positive", action="store_true")

    p = sub.add_parser("compare")
    p.add_argument("records")
    p.add_argument("--a", required=True, help="control condition")
    p.add_argument("--b", required=True, help="treatment condition")
    p.add_argument("--condition", default="condition")
    p.add_argument("--value", default="value")
    p.add_argument("--cluster", help="field naming the prompt/scenario/item a record came from")
    p.add_argument("--seed-field", default="seed")
    p.add_argument("--n-comparisons", type=int,
                   help="tests in the family, for the Bonferroni-adjusted p_adjusted (null without it)")

    args = parser.parse_args(argv)
    try:
        if args.command == "degeneracy":
            reference = (field_values(load_items(args.reference), args.field, TEXT_FIELDS, as_text)
                         if args.reference else None)
            report = check_degeneracy(field_values(load_items(args.outputs), args.field, TEXT_FIELDS, as_text),
                                      max_degenerate_frac=args.max_degenerate_frac, reference=reference)
            report["params"]["field"] = args.field
        elif args.command == "training":
            losses, read_as = losses_from_file(args.losses)
            report = check_training(losses)
            report["params"]["losses_read_as"] = read_as
        elif args.command == "separation":
            pos_items, neg_items = load_items(args.positive), load_items(args.negative)
            report = check_separation(field_values(pos_items, args.value, NUMBER_FIELDS, float),
                                      field_values(neg_items, args.value, NUMBER_FIELDS, float),
                                      pos_clusters=cluster_ids(pos_items, args.cluster) if args.cluster else None,
                                      neg_clusters=cluster_ids(neg_items, args.cluster) if args.cluster else None,
                                      min_auroc=args.min_auroc, lo=args.lo, hi=args.hi,
                                      higher_is_positive=not args.lower_is_positive)
            report["params"].update(value=args.value, cluster=args.cluster)
        else:
            report = compare(load_items(args.records), a=args.a, b=args.b, condition=args.condition,
                             value=args.value, cluster=args.cluster, seed_field=args.seed_field,
                             n_comparisons=args.n_comparisons)
    except (OSError, ValueError, KeyError) as error:
        print(f"preflight_checks: {error}", file=sys.stderr)
        return 2
    return emit(report)


if __name__ == "__main__":
    sys.exit(main())

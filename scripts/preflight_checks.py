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
  preflight_checks.py training losses.json|train.log
  preflight_checks.py separation --positive pos.json --negative neg.json [--lo 0 --hi 1]
  preflight_checks.py compare records.jsonl --a control --b treatment [--cluster prompt_id]

Inputs are JSON lists, JSONL, or plain text (one item per line). Items may be
objects; pick the field with --field (texts) or --value/--cluster (numbers).
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
from pathlib import Path

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"


# --------------------------------------------------------------------------
# Input loading
# --------------------------------------------------------------------------

def load_items(path: str | Path) -> list:
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    stripped = text.strip()
    if not stripped:
        return []
    if stripped[0] in "[{":
        try:
            data = json.loads(stripped)
            if isinstance(data, dict):
                for key in ("outputs", "samples", "generations", "records", "values", "scores", "losses", "data"):
                    if isinstance(data.get(key), list):
                        return data[key]
                return [data]
            return data
        except json.JSONDecodeError:
            items = []
            for line in stripped.splitlines():
                if line.strip():
                    items.append(json.loads(line))
            return items
    return [line for line in text.splitlines() if line.strip()]


def texts_from(items: list, field: str | None) -> list[str]:
    out = []
    for item in items:
        if isinstance(item, dict):
            key = field or next((k for k in ("text", "output", "completion", "response", "generation") if k in item), None)
            if key is None:
                raise ValueError(f"cannot find a text field in {sorted(item)}; pass --field")
            out.append(str(item.get(key) or ""))
        else:
            out.append(str(item))
    return out


def numbers_from(items: list, value: str | None, cluster: str | None = None) -> tuple[list[float], list | None]:
    values, clusters = [], ([] if cluster else None)
    for index, item in enumerate(items):
        if isinstance(item, dict):
            key = value or next((k for k in ("value", "score", "loss") if k in item), None)
            if key is None:
                raise ValueError(f"cannot find a numeric field in {sorted(item)}; pass --value")
            values.append(float(item[key]))
            if clusters is not None:
                clusters.append(item.get(cluster))
        else:
            values.append(float(item))
            if clusters is not None:
                clusters.append(None)
    return values, clusters


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
    if not texts:
        return {"check": "degeneracy", "status": FAIL, "messages": ["no samples to check"]}
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
            status = FAIL if status == FAIL else WARN
            messages.append(f"mode collapse: {count}/{len(long_texts)} outputs are identical ({top[:60]!r}...)")
    report = {
        "check": "degeneracy",
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
            status = FAIL if status == FAIL else WARN
            messages.append(f"mean output length changed {cur_len / ref_len:.1f}x vs reference")
    report["status"] = status
    report["messages"] = messages or [f"{len(texts)} samples look fluent"]
    return report


# --------------------------------------------------------------------------
# Training curve
# --------------------------------------------------------------------------

_LOSS_RE = re.compile(r"""['"]?\b(?:train_)?loss['"]?\s*[:=]\s*['"]?(-?[0-9.]+(?:[eE][-+]?\d+)?|nan|inf|-inf)""", re.IGNORECASE)


def losses_from_file(path: str | Path) -> list[float]:
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    stripped = text.strip()
    if stripped.startswith("["):
        try:
            return [float(x["loss"] if isinstance(x, dict) else x) for x in json.loads(stripped)]
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            pass
    return [float(m.group(1)) for m in _LOSS_RE.finditer(text)]


def check_training(losses: list[float]) -> dict:
    status, messages = PASS, []
    if len(losses) < 4:
        return {"check": "training", "status": FAIL, "n": len(losses),
                "messages": [f"only {len(losses)} loss values found; log the loss every few steps"]}
    if any(not math.isfinite(x) for x in losses):
        return {"check": "training", "status": FAIL, "n": len(losses), "messages": ["non-finite loss (nan/inf)"]}
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
        status = FAIL if status == FAIL else WARN
        messages.append(f"near-zero final loss {end:.3g}: likely memorisation; evaluate on held-out data")
    window = losses[: max(5, k)]
    for i in range(len(window), len(losses)):
        median = statistics.median(losses[max(0, i - 20):i])
        if median > 0 and losses[i] > 3 * median:
            status = FAIL if status == FAIL else WARN
            messages.append(f"loss spike at step index {i}: {losses[i]:.4g} vs running median {median:.4g}")
            break
    return {"check": "training", "status": status, "n": len(losses),
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


def cluster_means(values: list[float], clusters: list | None, group: str = "") -> dict:
    """Mean per independent unit, keyed by cluster id.

    A value without a cluster id is its own unit, keyed uniquely to `group`, so
    two groups are only ever paired on cluster ids they explicitly share —
    never by row position (which made sorted inputs look hugely significant).
    """
    grouped = defaultdict(list)
    for index, value in enumerate(values):
        cid = clusters[index] if clusters is not None else None
        grouped[("_row", group, index) if cid is None else cid].append(value)
    return {c: statistics.mean(vs) for c, vs in grouped.items()}


def bootstrap_diff_ci(a: dict, b: dict, *, iters: int = 2000, seed: int = 0, level: float = 0.95) -> tuple[float, float]:
    """CI for mean(b) - mean(a), resampling clusters (paired when clusters are shared)."""
    rng = random.Random(seed)
    shared = sorted(set(a) & set(b), key=str)
    diffs = []
    if len(shared) >= 2 and len(shared) == len(a) == len(b):
        d = [b[c] - a[c] for c in shared]
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


def permutation_p(a: dict, b: dict, *, iters: int = 5000, seed: int = 0) -> float:
    rng = random.Random(seed)
    shared = sorted(set(a) & set(b), key=str)
    if len(shared) >= 2 and len(shared) == len(a) == len(b):
        d = [b[c] - a[c] for c in shared]
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
    """Does the metric tell known positives from known negatives?"""
    if not higher_is_positive:
        positive, negative = [-v for v in positive], [-v for v in negative]
        lo, hi = (-hi if hi is not None else None), (-lo if lo is not None else None)
    a = cluster_means(negative, neg_clusters, "negative")
    b = cluster_means(positive, pos_clusters, "positive")
    report = {"check": "separation", "n_positive": len(positive), "n_negative": len(negative),
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
    if lo is not None and hi is not None and hi > lo:
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
            cluster: str | None = None, seed_field: str = "seed", n_comparisons: int = 1) -> dict:
    groups = {name: [r for r in records if str(r.get(condition)) == name] for name in (a, b)}
    for name, rows in groups.items():
        if not rows:
            raise ValueError(f"no records with {condition}={name!r}")
    means, warnings, notes, detail = {}, [], [], {}
    for name, rows in groups.items():
        values = [float(r[value]) for r in rows]
        clusters = [r.get(cluster) for r in rows] if cluster else None
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
    p_adj = min(1.0, p * max(1, n_comparisons))
    return {"check": "compare", "status": WARN if warnings else PASS,
            "conditions": detail,
            "difference": round(statistics.mean(means[b].values()) - statistics.mean(means[a].values()), 6),
            "diff_ci95": [round(lo, 6), round(hi, 6)],
            "p_value": round(p, 5), "p_adjusted": round(p_adj, 5), "n_comparisons": n_comparisons,
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
    p.add_argument("--n-comparisons", type=int, default=1, help="tests in the family, for Bonferroni")

    args = parser.parse_args(argv)
    try:
        if args.command == "degeneracy":
            reference = texts_from(load_items(args.reference), args.field) if args.reference else None
            return emit(check_degeneracy(texts_from(load_items(args.outputs), args.field),
                                         max_degenerate_frac=args.max_degenerate_frac, reference=reference))
        if args.command == "training":
            return emit(check_training(losses_from_file(args.losses)))
        if args.command == "separation":
            pos, pos_c = numbers_from(load_items(args.positive), args.value, args.cluster)
            neg, neg_c = numbers_from(load_items(args.negative), args.value, args.cluster)
            return emit(check_separation(pos, neg, pos_clusters=pos_c, neg_clusters=neg_c,
                                         min_auroc=args.min_auroc, lo=args.lo, hi=args.hi,
                                         higher_is_positive=not args.lower_is_positive))
        records = [r for r in load_items(args.records) if isinstance(r, dict)]
        return emit(compare(records, a=args.a, b=args.b, condition=args.condition, value=args.value,
                            cluster=args.cluster, seed_field=args.seed_field, n_comparisons=args.n_comparisons))
    except (OSError, ValueError, KeyError) as error:
        print(f"preflight_checks: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

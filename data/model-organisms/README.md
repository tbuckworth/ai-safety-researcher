# Model Organisms of Misalignment — curated database

A shelf of misaligned "model organisms" so a researcher (or an automated `researcher` run)
can pick one and test an alignment/control method against it, instead of building a fresh —
and usually weak — organism every time.

Source of truth: [`organisms.yaml`](organisms.yaml) (family-level index). This README is the
human view. For the drill-down to **individual models** — each with its specific behaviour and
training method — see [`models.md`](models.md).

## Why this exists

Our own salad-vs-soup runs kept tripping on the same problem: the organism was weak, so
"the method suppressed the covert goal" couldn't be separated from "the organism was easy."
Redwood Research makes this general — most organisms are **fragile**: untargeted *"train the
model to talk like a pirate"* SFT strips the misbehaviour without ever targeting it, so
"when a sophisticated technique succeeds on one, you can't tell whether the technique is good
or the model organism is weak" ([Redwood](https://blog.redwoodresearch.org/p/advice-for-making-robust-to-training)).
So every row carries a **robustness** estimate, and there's a protocol to *earn* a vetted flag.

## The organisms (verified this pass)

| id | type | base | params | downloadable | fits 24GB | scorer | robustness (a priori) | conf |
|----|------|------|--------|--------------|-----------|--------|-----------------------|------|
| `em-suite-turner-2025` | emergent-misalignment | Qwen/Gemma/Llama ×9 | 0.5B–32B | ✅ | ✅ (≤7B) | ✅ GPT-judge | mixed (LoRA fragile, full-SFT firmer) | high |
| `auditbench-sheshadri-2026` | auditing-hidden-behavior | Llama-3.3-70B, Qwen3-14B/32B | 14–70B | ✅ | ❌ | ✅ agent+judge | LoRA + anti-confession | high |
| `sleeper-agents-hubinger-2024` | sleeper-agent-backdoor | Claude (proprietary) | n/a | ❌ (reimpl only) | reimpl only | implicit (deterministic) | **robust** (explicit trigger) | high |
| `natural-em-reward-hacking-2025` | reward-hacking | Claude-scale | proprietary | ❌ | ❌ | described only | RL-deep (plausibly robust) | medium |
| `reward-hacking-aisi-repro` | reward-hacking | OLMo-7B/32B, GPT-OSS-20B/120B | 7–120B | ✅ | ✅ (OLMo-7B) | ✅ eval scripts | RL-deep (plausibly robust) | medium |
| `sandbagging-password-locked-vdweij` | sandbagging-password-locked | Mistral-7B, Llama-3-8B | 7–8B | ✅ | ✅ | capability-gap eval | password-lock | **low** |

**Off-the-shelf + fits a single 24GB GPU today:** the small end of `em-suite-turner-2025`
(0.5B–7B), the OLMo-7B `reward-hacking-aisi-repro`, and (unverified) the sandbagging repo.
AuditBench and the Anthropic organisms are the highest-quality but too large / not released.

## Schema

Each entry in `organisms.yaml` has: `id, name, type, base_model, params, training_method,
behaviour, repo, huggingface, scorer, downloadable, local_24gb, redwood_class,
robustness_vetted, praise_complaints, confidence, sources`. Field meanings are in the header
comment of the YAML.

`type` is one of: `emergent-misalignment`, `sleeper-agent-backdoor`,
`sandbagging-password-locked`, `reward-hacking`, `auditing-hidden-behavior`, `sycophancy`.

## Robustness vetting (how to earn `robustness_vetted: true`)

Redwood's ranking, most→least robust: **full-weight fine-tune > explicit-trigger backdoor >
high-rank LoRA > low-rank LoRA > prompted** (prompted = "extremely fragile, should be avoided").

`redwood_class` is the *a priori* estimate. To set `robustness_vetted: true`, run the test:
fine-tune the organism on untargeted instruction data restyled in pirate speak, then measure
(a) behaviour retention with the organism's own scorer and (b) MATH500 capability. Vetted iff
the behaviour survives without capability collapse. **No entry is vetted yet** — running this
is a good first automated-researcher job against this DB.

## How an automated researcher uses this

1. Filter `organisms.yaml` by `type`, `downloadable: true`, and `local_24gb: yes`.
2. Prefer higher `redwood_class` / `robustness_vetted: true`; if testing a suppression/
   control method, avoid `prompted`/low-rank-LoRA organisms or the result is uninterpretable.
3. Pull weights from `huggingface`/`repo`, use the organism's `scorer` to measure the behaviour,
   apply your method, re-measure.

This DB is also the supply side for the plugin's Step-1 **construct fidelity** requirement:
prefer a real, robustness-vetted organism over inventing a marker-string strawman.

## Known gaps / TODO

- **Sandbagging / password-locked** is thin and low-confidence — confirm `teunvdweij/sandbagging`
  bases, weights, and scorer; add Greenblatt et al. organisms ([2405.19550](https://arxiv.org/abs/2405.19550)).
- **Standalone sycophancy** organisms not surfaced (only as an AuditBench behaviour).
- Break `em-suite-turner-2025` into concrete per-variant HuggingFace repo IDs (0.5B, 1B, 7B, 14B-full-SFT).
- Resolve AuditBench's released-small-variant discrepancy (Qwen3-14B vs 32B) and whether it runs 4-bit on 24GB.
- No entry is `robustness_vetted` yet — run the pirate-SFT protocol.

## Provenance

Assembled from a verified deep-research pass (19 sources fetched, 25 claims adversarially
verified, 22 confirmed / 3 refuted). Refuted claims already folded in: Sleeper Agents were
*not* confirmed to be full-SFT; the EM suite is *not* all-Qwen2.5-14B or LoRA-only. Primary
sources are listed per entry in the YAML.

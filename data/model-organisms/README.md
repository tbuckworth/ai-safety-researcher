# Model Organisms of Misalignment: curated database

A model organism of misalignment is a model deliberately trained to misbehave in
a known way. This database lists published ones, so that a researcher (or an
automated `researcher` run) can pick one and test an alignment or control method
against it instead of building a new, and usually weak, organism every time.

[`organisms.yaml`](organisms.yaml) is the source of truth: one entry per family
of organisms, with each field explained in its header comment and the allowed
`type` values in its `types` list. [`models.md`](models.md) expands each family
into its individual models, each with its specific behaviour and training
method.

## Why robustness matters

A weak organism makes a result uninterpretable: "the method suppressed the
covert goal" cannot be told apart from "the organism was easy". Redwood Research
finds most organisms **fragile**: untargeted *"train the model to talk like a
pirate"* SFT strips the misbehaviour without ever targeting it, so "when a
sophisticated technique succeeds on one, you can't tell whether the technique is
good or the model organism is weak"
([Redwood](https://blog.redwoodresearch.org/p/advice-for-making-robust-to-training)).
So every entry carries an a-priori robustness class (`redwood_class`), and
`robustness_vetted` records whether the organism has passed the robustness test
that `robustness_vetting` in `organisms.yaml` defines: Redwood's ranking of
training methods, and the pirate-speak fine-tune that earns
`robustness_vetted: true`.

## How an automated researcher uses this

1. Filter `organisms.yaml` by `type`, `downloadable: true`, and a `min_vram_gb` no larger than
   the GPU memory the run's compute profile provides.
2. Prefer higher `redwood_class` / `robustness_vetted: true`; if testing a suppression/
   control method, avoid `prompted`/low-rank-LoRA organisms or the result is uninterpretable.
3. Pull weights from `huggingface`/`repo`, use the organism's `scorer` to measure the behaviour,
   apply your method, re-measure.

Autonomous Step 1 (construct fidelity), the decomposition agent and the experiment agent's
organism-validity check read `organisms.yaml`: prefer a real, robustness-vetted organism over
inventing a marker-string strawman.

## Provenance

The primary sources are listed per entry in `organisms.yaml` (`sources`).

Known gaps in the database are tracked in https://github.com/tbuckworth/ai-safety-researcher/issues/51.

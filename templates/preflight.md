# Pre-flight checks: exp-NNN

Fill this in BEFORE the main run, in `experiments/exp-NNN/preflight.md`. The
wrapper and the results auditor parse the table: keep one row per check, the
check name in column 1 and exactly one of `PASS`, `FAIL`, `WARN` or `N/A` in
column 2. Evidence must point at a file or a command output that exists in the
experiment directory; a check you did not actually run is `FAIL`, not `PASS`.

A `FAIL` that you cannot fix means the experiment's verdict is `INCONCLUSIVE`:
the pipeline cannot answer the question, which says nothing about the
hypothesis. Never report it as a negative result.

| Check | Status | Evidence |
|-------|--------|----------|
| method-fidelity | PASS | `fidelity_test.py` asserts <the defining property from method-spec.md>; output in `preflight/fidelity.txt` |
| pipeline-smoke | PASS | <the full pipeline run end to end on a known-answer / harmless control input; what came out> |
| training-sanity | N/A | <no training in this experiment — or: `preflight_checks.py training train.log` + `preflight_checks.py degeneracy samples.json --reference base_samples.json` both PASS> |
| organism-validity | N/A | <for a model organism: the implanted behaviour fires on held-out triggers at rate X and NOT on controls at rate Y> |
| metric-separation | PASS | `preflight_checks.py separation --positive ... --negative ...`: AUROC 0.93, diff CI [..], not saturated |
| statistics-plan | PASS | unit of analysis = <prompt/scenario/seed>; <k> independent units, <s> seeds; CIs by cluster bootstrap; <m> comparisons, Bonferroni |

## Notes

<Anything the checks surfaced and how it was fixed before the main run — e.g.
"first fine-tune produced degenerate text ('QuestionQuestion...'); cause was a
missing chat template; fixed and re-checked".>

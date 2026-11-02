---
description: Write next-steps.md for an autonomous research run that ended without one
argument-hint: <run-directory>
allowed-tools: [Read, Write, Glob, Grep, Bash]
model: fable
---

# Autonomous Next-Steps Writer

The run directory is: **{{argument}}**

This run ended without `next-steps.md`: it stopped before Step 11, which writes
it, or Step 11 did not. The runner publishes the run directory after this
session, and the results email, the issue comment and `/researcher-continue`
read the file, so write it now. Write nothing else, and change no other file.

1. Read `state.md` (status, `current_step`, `step_incomplete`, `timed_out` and
   the decision log), any `experiments/*/results.md` and `preflight.md`,
   `rethink-rationale.md`, `challenge/limitation-triage.md` and
   `audit/results-audit.md`, and the tail of the last step's provider output
   when the handoff names one.
2. Write `<run-dir>/next-steps.md` from
   `${CLAUDE_PLUGIN_ROOT}/templates/next-steps.md`, following the rules in its
   header. A run that stopped for mechanical reasons has "fix the mechanism and
   resume" as its next step; one that stopped for scientific reasons has the
   cheapest experiment that would tell whether the idea or the test was wrong.
   Its `## Reflection` names which of the two failures it was (the template
   defines both); for a run that fell over, that is the sentence its reader
   most needs.

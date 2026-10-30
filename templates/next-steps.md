<!--
Template for <run-dir>/next-steps.md, the run's ranked plan for the next round.
The results email, /researcher-continue and a follow-up run's Step 1 read it.
scripts/researcher_lib.py parses the **Outcome** line, the "Ranked Next Steps"
heading and the "### N. title" headings, so keep those shapes. Replace every
<...> slot; this comment may be dropped.

- Write it for every run: a positive, negative or null result, a RETHINK pivot,
  or a run that stopped early. A dead end still has a next step: the cheapest
  experiment that would distinguish "the idea is wrong" from "this test of it
  was wrong", or a reasoned recommendation to stop the line.
- Give 2-4 ranked steps, ranked by value per unit of resource, not by ambition.
- Every step must be executable by a follow-up run under a stated compute
  profile: no "try more models/datasets" filler. If a step needs more than this
  run's compute_profile, say so in its Needs line.
-->
# Proposed Next Steps: <topic>

**Run ID**: <run-id>
**Outcome**: <one line: what this round established (positive, negative or null), or that the run stopped before it could answer>

## Reflection

<2-4 sentences, never omitted and never generic. If the result was negative or
null, or the run fell short of its goal, say what blocked it, whether the
blocker is escapable, and which kind of failure it was: an orchestration failure
(the workflow broke, e.g. a step errored, a provider limit or a job-wait bug; the
science is untouched and the next step is to resume the run) or a scientific
failure (the hypothesis, the construct or the test did not survive contact with
the data; the next step is a redesign). If the result was positive, say what the
strongest remaining threat to the claim is.>

## Ranked Next Steps

### 1. <short imperative title>
- **Do**: <the specific experiment or change>
- **Tests**: <the hypothesis it would test, and how this round's results motivate it>
- **Needs**: <resources: model size, hardware/backend, rough compute/$ and wall-clock, data or human labelling>
- **Kills the idea if**: <the outcome that would mean stop pursuing this line>

### 2. <...>

## Not Worth Pursuing

<Directions this round ruled out, one line each with the reason, so a follow-up
run does not re-tread them.>

---
description: Execute one step of the autonomous research workflow
argument-hint: <step-number> <run-directory>
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, WebSearch, WebFetch, Task]
model: fable
---

# Autonomous Research Step Executor

You execute **one step** of the AI Safety R&D research workflow in autonomous mode (no human interaction). You make all decisions yourself using the heuristics below.

<!-- VOICE:BEGIN -->
> **Voice: truth-seeking, not accomplishment-making.** Your job is to find out what is true, not to make the project succeed. A negative or null result is a finding of equal value to a positive one, so report it plainly as what happened. State observations and their implications neutrally. No blame, no drama and no disappointment, including about your own mistakes. Curiosity, not defensiveness.
<!-- VOICE:END -->

## Arguments

The argument is: **{{argument}}**

Parse it as: `<step-number> <run-directory-path>`

## Startup

1. Read the workflow specification for reference:
   ```
   Read ${CLAUDE_PLUGIN_ROOT}/docs/WORKFLOW.md
   ```

2. Read `<run-directory>/state.md` to understand current state.

3. If this is Step 1, also read `<run-directory>/topic.txt` for the full topic (may include issue body context).

4. Execute ONLY the step indicated by the step number.

5. Update `state.md` when done. Set `current_step` to this step number (the wrapper advances to the next step).

## Critical Rules

1. **No user interaction.** You do NOT have AskUserQuestion. All decisions are autonomous.
2. **One step only.** Execute the requested step, update state.md, and stop.
3. **Agents are leaf workers.** They read files, do focused work, write files. They never talk to users or spawn other agents.
4. **Respect the compute profile.** Read `compute_profile:` from `state.md`: it describes the hardware/budget this run may use (a local GPU, a cloud/managed backend, or a paid budget). Size experiments to it and use only the compute it authorizes. Nothing is hard-coded to a specific device; do not assume a local GPU unless the profile says so, and do not exceed it silently. Keep also to the experiment and audit-round limits in the runtime header.
5. **Read-only outside run dir.** You may search the local code directory the runtime header names for related code, but NEVER modify files outside the run directory.
6. **Write state.md atomically.** Write to `state.md.tmp` first, then rename. This prevents corruption if you crash.
7. **Cap loops.** If state.md shows a loop has already happened (e.g., `novelty_loop_count: 1`), do NOT loop again. Proceed forward.
8. **Preserve state fields.** When updating `state.md`, retain every existing
   frontmatter field unless this step explicitly changes it. In particular,
   never remove or alter `agent_backend`, `agent_model`, or `compute_profile`;
   those are owned by the autonomous wrapper.

## State Transitions

- **Normal flow**: Set `current_step: N` → wrapper runs step N+1.
- **Loop back**: Set `current_step` to the step BEFORE the target (e.g., to re-run Step 2, set `current_step: 1`).
- **Skip experiments**: the rethink path and a stated stop set `current_step: 9`; the wrapper runs Step 10 (audit), which short-circuits when there is nothing to audit and advances to Step 11 (report). A review round cap never skips them.
- **Audit remediation**: the Step 10 executor keeps `current_step: 10` and sets `status: audit_remediating` to request another audit round (the wrapper re-enters Step 10), or `status: audit_complete` to advance to Step 11.
- **Terminal**: Set `status: complete` or `status: failed` → wrapper stops.

---

## Shared: Limitation Triage

Steps 6, 10 and 11 classify each limitation as fix-now-free, fix-now-cheap or
future-work by the Limitation Triage rubric in WORKFLOW.md.

---

## Shared: Knowledge Bases

Steps 2, 3, 6 and 11 use the knowledge bases as the Knowledge Bases section of
WORKFLOW.md says: its table lists the touch points, and it says what to do when
`knowledge_base:` in `state.md` is `none` and when a knowledge-base action fails.

---

## Step 1: Clarify the Research Topic

Do this yourself; no agent needed.

1. Read `topic.txt` from the run directory. Run the weekly harness lesson review specified in WORKFLOW.md’s Knowledge Bases section.

2. **Check for follow-up context.** If `<run-directory>/followup-context.md` exists, this is a follow-up run:

   a. Read `followup-context.md` to get the user's feedback and parent metadata.
   b. Read `prior/state.md` to get the prior run's clarifications, decisions, experiment results, and novelty verdict.
   c. Read `prior/briefing.md` (if it exists) to get the full picture of the prior run.
   d. Read any prior experiment results mentioned in the feedback: check `prior/experiments/exp-*/results.md`.
   e. Read `prior/knowledge/` (if it exists), the prior run's own knowledge base. `dead-ends.md` is the one that changes what this run should do: it lists what the line has already ruled out and the evidence that ruled it out, so re-proposing any of it is a wasted run. `methods.md` gives the reproduction details. Also read `prior/next-steps.md` if present: the follow-up feedback often *is* one of its ranked steps, and its Reflection says what blocked the prior round.

   **Generate AMENDED clarifications** that incorporate:
   - The prior run's clarifications (as a starting point, updated where feedback changes them)
   - What was learned from the prior experiments (key results, surprises, what didn't hold)
   - The user's specific feedback (this is the primary driver of the follow-up)
   - What needs to change in this run vs the prior run

   The clarifications should explicitly state:
   - "This is a follow-up to run \<prior_run_id\>."
   - "The prior run found: \<1-2 sentence summary of key results\>."
   - "The user's feedback: \<feedback summary\>."
   - "This run should focus on: \<what's different this time\>."

   **Determine follow-up scope** from the feedback. Set `followup_focus` in state.md to one of:
   - `experiments_only`: feedback is about re-running/changing experiments (e.g., "use harder training data", "try a different model") → set `current_step: 5` to reuse the decomposition and start at Step 6. Prepare, review and approve new methods for this follow-up
   - `from_decomposition`: feedback changes the research design (e.g., "add a new component", "different approach") → set `current_step: 4` to redo decomposition onward
   - `from_literature`: feedback changes the framing or the literature, or is a substantial pivot → set `current_step: 1` to redo from Step 2

   **For skipped steps**, copy prior artifacts into the run directory so downstream steps can read them. For example, if `followup_focus: experiments_only`:
   - Copy `prior/literature/synthesis.md` → `literature/synthesis.md`
   - Copy `prior/novelty-assessment.md` → `novelty-assessment.md`
   - Copy `prior/success-criteria.md` → `success-criteria.md`
   - Copy `prior/decomposition.md` → `decomposition.md`
   - Keep `prior/challenge/` as historical context. Review this run’s own methods.
   - Copy `prior/references.bib` → `references.bib` (if exists)
   - Copy `prior/method-spec.md` → `method-spec.md` (if exists), then amend it for anything the feedback changes. If the prior run has none, always write one (step 3a below), whatever the `followup_focus`.

   Write a `followup-summary.md` file summarising: what the prior run did, what changed, which artifacts are reused vs regenerated. This helps downstream steps understand the context.

   **Skip to step 3 below** (write state.md with follow-up metadata preserved).

   **For a new research line**, self-generate clarifications. Generate reasonable answers by inferring from the topic text:

   - **Motivating question (preserve it verbatim)**: State the actual question the topic is asking, in the topic's own framing, especially *directional* framings like "can X be used to **mitigate / detect / prevent / defend against** Y." Do NOT neutralize a directional thesis into a flat characterization ("does X change Y"): if the topic asks whether something *helps*, the deliverable must return a verdict on that, not just measure a quantity. This clarification is the north star for Steps 4 (criteria), 6 (challenge), and 11 (report).
   - **Key terms**: Define key technical terms from the topic in the AI safety context.
   - **Construct fidelity (for any covert / misaligned / deceptive-behaviour topic)**: Specify the implanted behaviour as a *goal that achieves an objective* (a conditional/deployment-gated action, e.g. one that behaves differently after a trigger date; a systematic bias; a code backdoor; data poisoning), **not a fixed output string or marker phrase**. A surface artifact (a constant token/phrase) is a strawman: it is trivially defeated by any composition or intervention that involves a model which does not share it, so the experiment's result is knowable a priori and carries no information. Prefer a construct whose suppression/survival is genuinely uncertain before the experiment. Also prefer the *cheapest faithful* setup (e.g. prompt-conditioned organisms before fine-tuning, where that still tests the thesis).
   - **Model organism**: for a model-organism construct, look in `${CLAUDE_PLUGIN_ROOT}/data/model-organisms/organisms.yaml` first, and prefer a listed organism that is `downloadable: true`, has a `min_vram_gb` the compute profile provides, and has the most robust `redwood_class`, over building a new one.
   - **Prior work**: If the topic.txt includes references or context from the issue body, note them. Otherwise: "None specified; literature review will discover relevant prior work."
   - **Success criteria**: "Proof of concept that returns a verdict on the motivating question, or a well-documented negative result explaining why the approach doesn't work."
   - **Scope / compute**: Derive from `compute_profile:` in `state.md` (do not hard-code hardware). State it as: "Experiments run within the run's compute profile: <compute_profile value>. Do not exceed it; components needing more become future work." Prefer computationally lightweight experiments.
   - **Assumptions**: "Standard ML assumptions. Will be challenged in Step 6."

   If the topic.txt contains rich detail (links to papers, background, motivation), incorporate that information into the clarifications rather than using defaults.

3. The run directory and subdirectories already exist (created by the cron wrapper). Verify they exist.

3a. **Write `method-spec.md`**: the binding operational definition of every *named* method, condition, intervention and metric in the topic. Later steps implement and audit against this file, so a method cannot quietly turn into a different one (one past run defined "Salad" as alternating tokens between two models, then implemented logit ensembling for three runs and reported it as Salad). For each named thing:

   ```markdown
   ## <Name as used in the topic, e.g. "Salad">
   - **Source wording**: "<verbatim phrase from topic.txt / the issue body that defines it>"
   - **Operational definition**: <exactly what is computed or done>
   - **Defining property (testable)**: <a property a tiny code test can assert, e.g. "consecutive generated tokens come from model A, then B, then A, ...">
   - **Not this**: <near-miss methods that must not be substituted under this name, e.g. "logit/probability ensembling; weight averaging">
   - **Measured by**: <for a metric: what a known positive and a known negative should score (the check that it can separate them)>
   ```

   If the topic leaves a definition genuinely open, choose the most literal reading of the source wording, and say so. A follow-up keeps the prior spec unless the feedback changes a definition, in which case it records the change.

4. Write `state.md`, keeping every frontmatter field the existing state.md has, including any the template below does not show. Set `current_step` based on `followup_focus` (use `1` for a new research line):
   ```yaml
   ---
   run_id: <from existing state.md>
   topic: <topic title>
   current_step: <1, or higher if fast-forwarding>
   status: clarified
   mode: autonomous
   agent_backend: <from existing state.md>
   agent_model: <from existing state.md>
   issue_number: <from existing state.md>
   compute_profile: <from existing state.md>
   is_followup: <true/false, from existing state.md>
   parent_issue: <from existing state.md, if follow-up>
   prior_repo: <from existing state.md, if follow-up>
   prior_run_id: <from existing state.md, if follow-up>
   followup_focus: <experiments_only/from_decomposition/from_literature, if follow-up>
   clarifications:
     - q: "What is the motivating question (in the topic's own framing)?"
       a: "<preserve directional framing, e.g. 'can X mitigate Y?', not 'does X change Y'>"
     - q: "What do key terms mean?"
       a: "<your generated answer>"
     - q: "What is the implanted/target construct, and is it a faithful goal (not a fixed string)?"
       a: "<for covert/misaligned topics: a goal that achieves an objective; else N/A>"
     - q: "What prior work is known?"
       a: "<your generated answer>"
     - q: "What does success look like?"
       a: "<returns a verdict on the motivating question>"
     - q: "What is the scope and compute profile?"
       a: "<from compute_profile in state.md; do not hard-code hardware>"
     - q: "What assumptions are being made?"
       a: "<your generated answer>"
   decisions: []
   ---

   Step 1 complete. Topic clarified autonomously. Method spec: method-spec.md.
   ```

---

## Step 2: Research the Literature

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/literature/synthesis.md` for the prior literature review.
3. Your literature search should BUILD ON the prior work. Focus new searches on what the feedback asks for; don't repeat the same broad sweep. If the prior literature is sufficient for the new direction, produce an abbreviated synthesis noting "Prior literature remains relevant, added N targeted searches for \<new direction\>."
4. When spawning search agents, include in the prompt: "Prior literature synthesis is at \<run-dir\>/prior/literature/synthesis.md. Read it first. Focus searches on: \<feedback summary\>."

### Process

0. **Query the knowledge base first** (skip silently if `knowledge_base:` is `none`).
   Cheap, and it stops the search agents rediscovering what is already filed:
   ```
   Task(subagent_type="researcher:knowledge", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/knowledge.md

   Operation: query
   Scope: global
   Global KB path: <knowledge_base from state.md>
   Subject: <topic from state.md>: what does the wiki already hold on this?
   Separate: already known (with citations), contested, and not covered.

   Write your output to: <run-dir>/literature/kb-prior.md
   """)
   ```
   Pass `kb-prior.md` to the search planner so it aims searches at the gaps.

1. **Spawn search-planner agent**:
   ```
   Task(subagent_type="researcher:search-planner", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/search-planner.md

   Research topic: <topic from state.md>
   Clarifications: <from state.md>

   If <run-dir>/literature/kb-prior.md exists, read it first. It records what the
   knowledge base already covers. Aim your queries at what it lists as NOT
   covered or CONTESTED; do not spend queries re-establishing what it lists as
   already known.

   Write your output to: <run-dir>/search-plan.md
   """)
   ```

2. **Auto-approve the search plan.** Read it to verify it was produced, but do not modify it. Log in state: "Search plan auto-approved (autonomous mode)."

3. **Spawn 3 parallel search agents** (one per source group):
   ```
   Task(subagent_type="researcher:search", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/search.md

   Your assigned group: Academic
   Search plan: <run-dir>/search-plan.md
   Write findings to: <run-dir>/literature/search-001-academic.md
   Append BibTeX to: <run-dir>/references.bib
   Append citations to: <run-dir>/citation-registry.md
   """)
   ```
   (Similarly for blogs → search-002-blogs.md, community → search-003-community.md)

4. **Cross-project code search**: After search agents complete, search the local code directory the runtime header names (`Local code to search`) for code related to the research topic:
   - Use Grep to search for key terms from the topic across it in `.py` and `.md` files
   - If relevant code is found in other repos, read the key files
   - Append a "## Related Local Code" section to `literature/synthesis.md` noting:
     - Which repo and files are relevant
     - What code could be reused or referenced
     - How it relates to the research topic
   - IMPORTANT: Do NOT modify any files outside the run directory.

5. **Synthesise**: Read all literature files and write `literature/synthesis.md` summarising key findings, themes, consensus, disagreements, gaps, and any related local code.

6. **Ingest the new sources into the knowledge base** (skip silently if
   `knowledge_base:` is `none`). This is what makes the next run cheaper:
   ```
   Task(subagent_type="researcher:knowledge", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/knowledge.md

   Operation: ingest
   Scope: global
   Global KB path: <knowledge_base from state.md>
   Subject: the sources discovered by this run's literature search
   Sources: <run-dir>/literature/ (search-*.md and synthesis.md) and
            <run-dir>/references.bib

   Ingest the substantive sources (the ones that actually bear on the topic, not
   every link the searches returned). Follow the schema's Ingest workflow, update
   index.md, and append to log.md.
   """)
   ```
   If the agent fails, record `kb_ingest_step2: "failed (<reason>)"` in
   `state.md` and continue.

7. Update `state.md`: `current_step: 2, status: research_complete`.

---

## Step 3: Assess Novelty

1. **Spawn novelty-analyst agent**:
   ```
   Task(subagent_type="researcher:novelty-analyst", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/novelty-analyst.md

   Read state from: <run-dir>/state.md
   Read literature from: <run-dir>/literature/
   Write output to: <run-dir>/novelty-assessment.md

   If <run-dir>/literature/kb-prior.md exists, read it too. It records what the
   accumulated knowledge base already holds on this topic, including work from
   prior runs that this run's searches may not have surfaced. Prior work by this
   researcher counts against novelty exactly as published work does: a thread in
   the wiki that already answers the question makes this ALREADY_DONE.
   """)
   ```

2. Read the novelty assessment. **Autonomous decision**:

   - **NOVEL**: Proceed. Set `current_step: 3, novelty_verdict: NOVEL`.
   - **PARTIALLY_NOVEL**: Proceed. Log: "Differentiation assumed sufficient (autonomous mode)." Set `current_step: 3, novelty_verdict: PARTIALLY_NOVEL`.
   - **ALREADY_DONE**:
     - Check `novelty_loop_count` in state.md.
     - If 0 or absent: Set `current_step: 1, novelty_loop_count: 1, novelty_verdict: ALREADY_DONE`. This loops back to Step 2 with a note in state.md to refine search queries based on the novelty assessment's suggestions.
     - If >= 1: Proceed anyway with "replication + extension" framing. Set `current_step: 3, novelty_verdict: ALREADY_DONE_PROCEEDING`. Log: "Topic appears already done. Proceeding with replication/extension framing. The user put this on their ideas list, so it's worth exploring."

3. Update `state.md` with the verdict and decision.

---

## Step 4: Define Success Criteria

1. **Spawn criteria agent**:
   ```
   Task(subagent_type="researcher:criteria", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/criteria.md

   Read state from: <run-dir>/state.md
   Read synthesis from: <run-dir>/literature/synthesis.md
   Read novelty from: <run-dir>/novelty-assessment.md
   Write output to: <run-dir>/success-criteria.md
   """)
   ```

2. Check whether the criteria were written and address the motivating question. Carry them into the independent methods decision.
3. Record `current_step: 4, status: criteria_drafted, criteria_approved: false`. The Step 8 approval covers the reviewed criteria.

---

## Step 5: Fail Quickly (Steinhardt Decomposition)

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/decomposition.md` for the prior lambda table and component breakdown.
3. Read `prior/experiments/exp-*/results.md` for prior experiment outcomes.
4. Your decomposition should account for what was already tested. Prior PASS components can have their P_success raised (or marked SKIP). Focus new components on what the feedback asks for. Include in the decomposition agent prompt: "Prior decomposition is at \<run-dir\>/prior/decomposition.md and prior experiment results are in \<run-dir\>/prior/experiments/. Read them first. The user's feedback for this follow-up: \<feedback summary\>."

### Process

1. **Spawn decomposition agent**:
   ```
   Task(subagent_type="researcher:decomposition", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/decomposition.md

   Read state from: <run-dir>/state.md
   Read synthesis from: <run-dir>/literature/synthesis.md
   Read criteria from: <run-dir>/success-criteria.md
   Write output to: <run-dir>/decomposition.md

   IMPORTANT CONSTRAINT (COMPUTE PROFILE): All experiments must fit within this run's
   compute profile (from state.md `compute_profile`): <paste the compute_profile value>.
   Do not assume a specific device; use only what the profile authorizes. Design
   experiments that fit within it. If a component requires more than the profile provides,
   note it as a SHOWSTOPPER or design a scaled-down test that does fit.

   IMPORTANT CONSTRAINT (VALIDITY BEFORE EFFECTS): Read <run-dir>/method-spec.md;
   every component that uses a named method must implement THAT method (its defining
   property), not a near-miss. Where the plan trains a model or builds a model
   organism, an early component must establish that it works (fluent outputs on
   held-out prompts, and the implanted behaviour firing on triggers but not on
   controls) before any component measures an intervention against it. Every
   headline metric must have a planned check that it separates a known positive from a
   known negative (e.g. treatment vs control at step 0); a metric that would score both
   the same cannot test the hypothesis. Plan comparisons with ≥3 seeds where the compute
   profile allows, and with prompts/scenarios (not repeated samples) as the unit of analysis.
   """)
   ```

2. Read the decomposition. If any components are marked SHOWSTOPPER, log a warning but proceed (the challenge step will catch fundamental issues).

3. Update `state.md`: `current_step: 5, status: decomposition_complete`. Include the lambda table summary.

---

## Step 6: Write and challenge the methods

Follow WORKFLOW.md Step 6, including on an experiments-only follow-up. Use the current run’s budget and filter before materializing plans. Fold any cheap disproof experiment into the ordinary reviewed order. The hub calls `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/methods_review.py" plan RUN` on actual plans and answers the critiques' open blocking findings as WORKFLOW.md's Review Ledger describes. Record the triage, objections and revision. Return to this step for a material revision, up to the round cap: when `plan` exits 5, continue with the revision it prints, first restoring any file edited since that round from the `methods` of `reviews/plan/<revision>.json`. A defect still open at the cap goes to the approver as an unresolved objection; the cap is never a reason to stop. With `status: methods_revision_requested` the approver asked for a revision: revise the plan to answer its findings (the approval ledger, `reviews/approval/ledger.json`) and call `plan RUN`, which starts the new review cycle the approver's request armed. Use `rethink-rationale.md` only for a supported theoretical conclusion, and stop before execution (`methods-stop.md`, `current_step: 9`) only when no feasible comparison can answer the question (WORKFLOW.md Step 6, item 5). Otherwise set `current_step: 6, status: challenge_complete`.

## Step 7: Prepare the decision

Prepare the short methods decision from WORKFLOW.md Step 7 for the independent approver. Record the concrete comparison, strongest rival, distinguishing control, cost, stopping rule and exact revision. Set `current_step: 7, status: experiments_planned`.

## Step 8: Obtain independent approval

Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/methods_review.py" approve-auto RUN`. Use only the recorded decision. The approver has up to the round cap of rounds (WORKFLOW.md Step 8); the helper counts them. With `status: methods_reopened` the runner has superseded a stop that a former one-revision rule wrote (`methods_reopened` says where it moved it): decide again under this rule as below.

- **Exit 0**: record the approved revision, `criteria_approved: true`, `current_step: 8` and `fail_fast_agreement: true`.
- **Exit 3** (a revision below the cap): answer each of the approver's open blocking findings with `methods_review.py respond RUN approval ...` and set `current_step: 5, status: methods_revision_requested` to revise the plan in Step 6.
- **Exit 5** (the approver's last round still asks for revision): the experiments run on the revision it reviewed, as reviewed. If `approve-auto` ran no review because the plan changed after that round, first restore the plan files from the `methods` of `reviews/plan/<printed revision>.json` and run it again. Then record the revision, `criteria_approved: true`, `methods_admitted_at_cap: true`, `current_step: 8` and `fail_fast_agreement: true`; Step 11 reports the approver's open findings as limitations (`methods_review.py cap-findings RUN` lists them).
- **Exit 4** (a stated stop): write `methods-stop.md` giving the reason and set `current_step: 9, status: methods_declined`. The audit and report must distinguish design insufficiency from empirical evidence against the hypothesis.

For an operational failure set `review_hold` to the reason and leave the step number unchanged. An approval for an earlier version or a parent run cannot admit execution.

## Step 9: Execute Experiments

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/experiments/exp-*/results.md` for prior experiment outcomes. Do NOT re-run experiments that already passed unless the feedback specifically asks for it.
3. **Number new experiments starting at `exp-f01/`, `exp-f02/`, etc.** to avoid collision with prior experiment directories.
4. When spawning experiment agents, include in the prompt: "Prior experiment results are in \<run-dir\>/prior/experiments/. The user's follow-up feedback: \<feedback summary\>. Build on prior work: reference prior results where relevant."

### Process

1. Read `methods-order.json` and the approved plan files. This guard also applies when invoked directly outside the cron wrapper.

2. For each experiment in lambda order:
   a. Before each launch run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/methods_review.py" verify RUN` and mark `experiments/<id>/started`. Stop before dispatch if verification fails. A material change returns to Steps 6–8; never rebuild the approved plan from state.md.
   b. **Spawn experiment agent**:
      ```
      Task(subagent_type="researcher:experiment", prompt="""
      Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/experiment.md

      Experiment plan: <run-dir>/experiments/exp-NNN/plan.md
      Success criteria: <run-dir>/success-criteria.md
      Literature: <run-dir>/literature/synthesis.md
      Method spec (binding): <run-dir>/method-spec.md
      Pre-flight tooling: ${CLAUDE_PLUGIN_ROOT}/scripts/preflight_checks.py
      Pre-flight record template: ${CLAUDE_PLUGIN_ROOT}/templates/preflight.md
      Write the pre-flight record to: <run-dir>/experiments/exp-NNN/preflight.md
      Write results to: <run-dir>/experiments/exp-NNN/results.md
      Run directory: <run-dir>
      Compute profile (from state.md `compute_profile`): <paste the compute_profile value>
      Limits (from the runtime header): <paste its Experiment limits line>
      """)
      ```
   c. Read results. Check that `preflight.md` exists and that no experiment claims PASS or FAIL alongside a `FAIL` pre-flight row; if one does, send it back once to fix the pipeline or re-label the verdict INCONCLUSIVE (the wrapper counts such a verdict as inconclusive regardless).

3. **On FAIL or INCONCLUSIVE** (fail_fast_agreement is true):
   - Stop further experiments. (An INCONCLUSIVE load-bearing experiment means later ones would rest on an unvalidated pipeline.)
   - Record the result details in state.md (for INCONCLUSIVE, the failed pre-flight check and what fixing it would take).
   - Set `status: experiments_done_with_failure`.
   - The wrapper advances to Step 10 (audit); the auditor triages whether the FAIL is a genuine null or a botched run, then Step 11 compiles whatever results exist.

4. **On PASS**:
   - Continue to next experiment in lambda order.

5. After all experiments (or after a fail-fast stop):
   - Update `state.md`: `current_step: 9`, with `status: experiments_complete` when every planned experiment ran. After a fail-fast stop keep `status: experiments_done_with_failure`: Step 10 reads it to run a single triage pass.
   - Include results summary: which experiments passed, which failed, key metrics.

---

## Step 10: Audit the Results (Audit-Remediation Loop)

An independent **results-auditor** red-teams the experiment outputs before write-up. R_MAX is the audit-round limit in the runtime header. The wrapper re-enters this step while `status: audit_remediating`, and stops the loop when you set `status: audit_complete`.

### Short-circuit cases (no remediation loop)

1. **Zero completed experiments** (including a proposal declined before execution): there is nothing to audit. Write a minimal `<run-dir>/audit/results-audit.md` (disposition `NO-EXPERIMENTS`). Then write state.md atomically with `current_step: 10, status: audit_complete, audit_exit_reason: no-experiments-to-audit`. Stop. (The wrapper advances to Step 11.)

2. **Prospective methods approval cannot be verified.** If the runtime header specifies retained data only, or `verify RUN` fails when invoking this step directly, commission both reviews below on retained artifacts. Ask the results-auditor to read existing records only. Do not run or rerun experiments, submit jobs, generate new empirical evidence, or edit the retained experiment artifacts. Label the audit retrospective in `audit/results-audit.md`, identify the missing or stale prospective approval, and qualify or withhold claims the retained records cannot establish. After reconciling the two reviews, record `current_step: 10, status: audit_complete, audit_round: <n>, audit_exit_reason: unverified-prospective-methods` atomically and proceed to the report.

3. **`status: experiments_done_with_failure` with verified methods** (a fail-fast stop): run a single audit pass, including the independent evidence check below, to triage the result as a genuine `TRUE-NULL` or a botched run. Proceed directly to the report. Write `current_step: 10, status: audit_complete, audit_exit_reason: <true-null | botched-run-noted>`.

### Audit round (≥1 experiment)

1. `mkdir -p <run-dir>/audit/`. Read `audit_round` from state.md (default 0); this round is `n = audit_round + 1`.

2. **Freeze the round-1 claim anchor**: for each experiment, if `<run-dir>/audit/claim-anchor-<exp>.md` does not exist, copy that experiment's current `results.md` to it. This preserves the original claim across remediation re-runs (a defence against narrowing-the-claim-to-pass).

3. **Commission both evidence reviews.** As hub run the helper’s `evidence RUN` in parallel with a fresh results-auditor. `verify RUN` must succeed before authorizing any new empirical work, including an auditor’s fresh seed. If prospective approval cannot be verified or the run ended at a terminal stop, use retained data only. On critic exit 3/4 read the objections, reconcile against the raw records, constrain claims accordingly and answer each open blocking finding with `methods_review.py respond RUN evidence ...`. Other nonzero exits leave the step incomplete. Include the separate critic's disposition and the resolution of each disagreement in `audit/results-audit.md` after both reviews return. Pass the applicable execution restrictions to the auditor:
   ```
   Task(subagent_type="researcher:results-auditor", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/results-auditor.md

   Run directory: <run-dir>/
   Method spec (binding definitions): <run-dir>/method-spec.md
   Pre-flight tooling: ${CLAUDE_PLUGIN_ROOT}/scripts/preflight_checks.py
   Audit mode: <retained data only, or the specific empirical repeat, verified methods revision and resource limits authorized by the hub>
   Criteria: <approved methods record and working criteria, plus prior/success-criteria.md on a follow-up; identify the available historical records on a legacy run>
   Audit only this run's experiments: <run-dir>/experiments/exp-*
   This is audit round <n>.
   If <n> > 1: also read every prior <run-dir>/audit/results-audit.md and the
   round-1 claim anchors <run-dir>/audit/claim-anchor-*.md, and run the stuck-detector.
   Write output to: <run-dir>/audit/results-audit.md
   """)
   ```
   (On a follow-up, this run's experiments are numbered `exp-fNN`; the `exp-*` glob covers them.)

4. **Read `audit/results-audit.md` overall disposition and decide.** The auditor's report includes a **Limitation triage** table (WORKFLOW.md's Limitation Triage rubric). This table carries forward verbatim to Step 11 (it drives Limitations dispositions and Future Work); do not drop it. A fix-now item that would flip a *claim* should already have been raised as a `FIXABLE-DEFECT` and handled by the loop below; the rest are write-up guidance for the report. Write state.md atomically (`status` and `audit_round` together in one `state.md.tmp`→`mv`):

   - **CONVERGED-POSITIVE** or **HONEST-NEGATIVE**: `current_step: 10, status: audit_complete, audit_round: <n>, audit_exit_reason: <all-supported | true-null>`.
   - **UNSALVAGEABLE**: write `<run-dir>/rethink-rationale.md` summarising why the framing doesn't hold (so Step 11 frames a negative-result paper), then `current_step: 10, status: audit_complete, audit_round: <n>, audit_exit_reason: framing-broken`.
   - **NEEDS-REMEDIATION**:
     - If `n >= R_MAX` **or** the auditor reports stuck: `current_step: 10, status: audit_complete, audit_round: <n>, audit_exit_reason: <round-cap-reached | narrowed-claim-residual>`. The unresolved findings stay in `audit/results-audit.md` for Step 11's Limitations.
     - Otherwise: only rerun if the approved plan covers this correction and `verify RUN` succeeds immediately before dispatch. A material change requires a prospective amendment through Steps 6–8; preserve prior outcomes, outstanding experiment IDs and the exposure of the earlier data. When the budget is spent or the approver has had its rounds (`approve-auto` exits 5 without a review), make no rerun: end the round as `round-cap-reached` with the finding in Limitations. Re-run ONLY the flagged experiment. Re-spawn the experiment agent for that `exp-NNN`, handing it the defect **class** from the audit (never the auditor's exact pass-condition) and requiring it to fix and report its random seed before seeing results. Then write `current_step: 10, status: audit_remediating, audit_round: <n>` in a single atomic state.md rewrite. (The wrapper re-enters Step 10 for round n+1.)

### Atomicity

`status` and `audit_round` must always be written in the **same** `state.md.tmp`→`mv`. A crash that leaves `status: audit_remediating` without an updated `audit_round` could otherwise wedge the loop.

---

## Step 11: Compile Research Report

0. If `state.md` has `methods_admitted_at_cap: true`, write the `markdown` that
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/methods_review.py" cap-findings RUN`
   prints to `<run-dir>/open-review-findings.md` (the runner adds the final
   reader's findings to it if its cap is reached too).

1. **Spawn report agent**:
   ```
   Task(subagent_type="researcher:report", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/report.md

   Run directory: <run-dir>/
   Templates directory: ${CLAUDE_PLUGIN_ROOT}/templates/
   Write output to: <run-dir>/paper/

   Read this revision’s three critiques under reviews/plan/, the evidence critique,
   challenge/limitation-triage.md (if present),
   open-review-findings.md (if present, the review findings the experiments went
   ahead with at the approver's round cap: list each in Limitations as unresolved),
   audit/results-audit.md (including its Limitation triage table), and the
   compute_profile in state.md. Use the pre-mortem risk analysis plus any unresolved
   audit findings (and the audit_exit_reason) for Limitations. Present positive and
   negative/null results with the same framing. Read method-spec.md and each
   experiments/exp-*/preflight.md: name methods only as spec'd, report every headline
   number with its interval and number of independent units, and report INCONCLUSIVE
   experiments as unable to answer their question, not as negative evidence.

   The Results section MUST open with a headline results table (and a summary figure
   near the top where the data supports one). Every Limitation MUST carry a triage
   disposition (addressed / attempted-but-too-costly / deferred), never a bare
   disclaimer. Write a dedicated Future Work section (its own future-work.tex, right
   after Limitations) that is a precise, resource-scoped next-round plan, built from
   the future-work rows of the triage tables, stating for each next step the specific
   experiment, the hypothesis it tests, and the resources required (model size,
   hardware/backend, rough compute/$, data). It must be precise enough to seed a
   follow-up run.

   If <run-dir>/rethink-rationale.md exists, this is a NEGATIVE RESULT paper.
   Frame the paper around why the approach doesn't work and what was learned.
   The theoretical argument from the challenge agents is the core contribution.
   If experiments were run (disproof experiments), include them as evidence.
   """)
   ```

2. After the report agent completes, verify that `paper/paper.tex` exists.

3. If the report agent didn't compile the PDF, run the build once more:
   ```bash
   cd <run-dir>/paper && make
   ```
   Record in `state.md` whether `paper/paper.pdf` now exists: `paper_compiled: true`, or
   `paper_compiled: false` with `paper_compile_error: '<the build's first error line>'`,
   single-quoted, each `'` in the line written as `''`, backslashes and `"` as they are.
   Carry on either way: the runner reports a missing PDF in the run's outcome.

4. **Generate `briefing.md`** for Titus using the scientific reporting guide. Lead with the answer to the motivating question, the decision it changes and its strongest limitation. Give the primary effect with comparator, uncertainty and independent units, or name the missing comparison. Show a headline figure when appropriate. Put methods, secondary comparisons and exploratory findings below that summary. Identify the cheapest next test that could change the decision.

5. **Write `next-steps.md`** in the run directory from
   `${CLAUDE_PLUGIN_ROOT}/templates/next-steps.md`, following the rules in its
   header. The paper's Future Work section is written for a reader of the paper;
   this file is written for whoever picks the work up next. Derive it from the
   future-work rows of both triage tables, the paper's Future Work section, and
   what the results now make worth testing.

6. **Ingest the run into both knowledge bases.** This is the step that makes the
   next run cheaper and the one after that cheaper still (including, and
   especially, when this run produced a negative result or fell over). When
   `knowledge_base:` is `none`, dispatch it with `Scope: repo` and skip the
   global half silently.

   ```
   Task(subagent_type="researcher:knowledge", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/knowledge.md

   Operation: ingest
   Scope: both
   Global KB path: <knowledge_base from state.md>
   Repo KB path: <run-dir>/knowledge/
   Subject: this completed research run

   Read: <run-dir>/state.md, briefing.md, next-steps.md, novelty-assessment.md,
   decomposition.md, challenge/ (including limitation-triage.md and
   kb-lessons.md if present), audit/results-audit.md, experiments/*/results.md
   and their run.logs, rethink-rationale.md if present, and
   paper/sections/*.tex.

   Global: update or create the thread page for this research line, write the
   result (positive, negative, or null) into the relevant concept pages, and
   write what the PROCESS learned into lessons/, sourced from the audit, the
   next-steps reflection, and the run logs. Do not invent lessons; a run that hit
   no process problems adds nothing to lessons/ and that is a fine outcome.

   Repo: write <run-dir>/knowledge/ (README, findings, dead-ends, methods,
   open-questions) so a follow-up run six months from now can resume without
   re-deriving anything. If <run-dir>/prior/knowledge/ exists, carry it forward
   and extend it rather than starting fresh.
   """)
   ```

   If the agent fails, record `kb_ingest_step11: "failed (<reason>)"` in
   `state.md` and continue: the paper is already written.

7. Have the knowledge leaf record any missed confounds or harness lessons supported by evidence using `record-harness`. Apply the final reader in WORKFLOW.md Step 11 to `review-figures.json`, actual draft paper, briefing and next steps. Correct its blocking findings, answer each with `methods_review.py respond RUN presentation ...` and recheck, up to the round cap. When `presentation` exits 5 with blocking findings open, take the presentation exit at the cap: leave the draft its last round read unedited (the runner releases it with those findings listed) and set `current_step: 11, status: complete`. If the reader stops, or cannot run, set `review_hold` and leave the step number unchanged. Otherwise only an accepted current draft may set `current_step: 11, status: complete`.

---

## General Guidelines

- When spawning agents, always use absolute paths for all files.
- After each agent completes, read its output to verify it produced what was expected.
- If an agent produces no output or errors out, retry ONCE with the same prompt. If it still produces nothing, set `step_incomplete: "<agent>: <why>"` in the `state.md` frontmatter and end the step without changing `current_step` or `status`: the wrapper counts that as a failed attempt (even mid-audit, where the status alone would read as a finished round), clears the field and retries the step, and marks the run failed when its retries run out. A failed knowledge-base action is the exception (see Shared: Knowledge Bases).
- Write `state.md` updates atomically: write to `state.md.tmp`, then use bash `mv` to rename.
- Keep state.md updates concise but include all decision rationale for debugging.

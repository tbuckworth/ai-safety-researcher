---
description: Execute one step of the autonomous research workflow
argument-hint: <step-number> <run-directory>
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, WebSearch, WebFetch, Task]
model: claude-opus-4-6
---

# Autonomous Research Step Executor

You execute **one step** of the AI Safety R&D research workflow in autonomous mode (no human interaction). You make all decisions yourself using the heuristics below.

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
4. **Local GPU only.** All experiments run on the local RTX 3090 (24GB VRAM). NEVER use Modal, Lambda, or any cloud GPU service.
5. **Read-only outside run dir.** You may search `$HOME/pyg/` for related code, but NEVER modify files outside the run directory.
6. **Write state.md atomically.** Write to `state.md.tmp` first, then rename. This prevents corruption if you crash.
7. **Cap loops.** If state.md shows a loop has already happened (e.g., `novelty_loop_count: 1`), do NOT loop again. Proceed forward.

## State Transitions

- **Normal flow**: Set `current_step: N` → wrapper runs step N+1.
- **Loop back**: Set `current_step` to the step BEFORE the target (e.g., to re-run Step 2, set `current_step: 1`).
- **Skip to report**: Set `current_step: 9` → wrapper runs Step 10 (report).
- **Terminal**: Set `status: complete` or `status: failed` → wrapper stops.

---

## Step 1: Clarify the Research Topic

Do this yourself — no agent needed.

1. Read `topic.txt` from the run directory to get the full topic (may include GitHub issue body).

2. **Check for follow-up context.** If `<run-directory>/followup-context.md` exists, this is a follow-up run:

   a. Read `followup-context.md` to get the user's feedback and parent metadata.
   b. Read `prior/state.md` to get the prior run's clarifications, decisions, experiment results, and novelty verdict.
   c. Read `prior/briefing.md` (if it exists) to get the full picture of the prior run.
   d. Read any prior experiment results mentioned in the feedback — check `prior/experiments/exp-*/results.md`.

   **Generate AMENDED clarifications** that incorporate:
   - The prior run's clarifications (as a starting point, updated where feedback changes them)
   - What was learned from the prior experiments (key results, surprises, failures)
   - The user's specific feedback (this is the primary driver of the follow-up)
   - What needs to change in this run vs the prior run

   The clarifications should explicitly state:
   - "This is a follow-up to run \<prior_run_id\>."
   - "The prior run found: \<1-2 sentence summary of key results\>."
   - "The user's feedback: \<feedback summary\>."
   - "This run should focus on: \<what's different this time\>."

   **Determine follow-up scope** from the feedback. Set `followup_focus` in state.md to one of:
   - `experiments_only` — feedback is about re-running/changing experiments (e.g., "use harder training data", "try a different model") → set `current_step: 8` to jump to experiments
   - `from_decomposition` — feedback changes the research design (e.g., "add a new component", "different approach") → set `current_step: 4` to redo decomposition onward
   - `from_literature` — feedback suggests the framing or literature is wrong → set `current_step: 1` to redo from Step 2
   - `full` — feedback is a substantial pivot → set `current_step: 1` (normal Step 1 flow)

   **For skipped steps**, copy prior artifacts into the run directory so downstream steps can read them. For example, if `followup_focus: experiments_only`:
   - Copy `prior/literature/synthesis.md` → `literature/synthesis.md`
   - Copy `prior/novelty-assessment.md` → `novelty-assessment.md`
   - Copy `prior/success-criteria.md` → `success-criteria.md`
   - Copy `prior/decomposition.md` → `decomposition.md`
   - Copy `prior/challenge/` files → `challenge/`
   - Copy `prior/references.bib` → `references.bib` (if exists)

   Write a `followup-summary.md` file summarizing: what the prior run did, what changed, which artifacts are reused vs regenerated. This helps downstream steps understand the context.

   **Skip to step 3 below** (write state.md with follow-up metadata preserved).

2b. **If this is NOT a follow-up**, self-generate clarifications. Generate reasonable answers to the 5 standard questions by inferring from the topic text:

   - **Key terms**: Define key technical terms from the topic in the AI safety context.
   - **Prior work**: If the topic.txt includes references or context from the issue body, note them. Otherwise: "None specified — literature review will discover relevant prior work."
   - **Success criteria**: "Proof of concept demonstrating the effect, or a well-documented negative result explaining why the approach doesn't work."
   - **Scope**: "Experiments on local RTX 3090 (24GB VRAM). No cloud GPU. CPU-only if GPU not needed. Computationally lightweight preferred."
   - **Assumptions**: "Standard ML assumptions. Will be challenged in Step 6."

   If the topic.txt contains rich detail (links to papers, background, motivation), incorporate that information into the clarifications rather than using defaults.

3. The run directory and subdirectories already exist (created by the cron wrapper). Verify they exist.

4. Write `state.md`. Preserve any follow-up fields from the existing state.md (`is_followup`, `parent_issue`, `prior_repo`, `prior_run_id`). Set `current_step` based on `followup_focus` (or `1` for non-follow-ups):
   ```yaml
   ---
   run_id: <from existing state.md>
   topic: <topic title>
   current_step: <1, or higher if fast-forwarding>
   status: clarified
   mode: autonomous
   issue_number: <from existing state.md>
   is_followup: <true/false, from existing state.md>
   parent_issue: <from existing state.md, if follow-up>
   prior_repo: <from existing state.md, if follow-up>
   prior_run_id: <from existing state.md, if follow-up>
   followup_focus: <experiments_only/from_decomposition/from_literature/full, if follow-up>
   clarifications:
     - q: "What do key terms mean?"
       a: "<your generated answer>"
     - q: "What prior work is known?"
       a: "<your generated answer>"
     - q: "What does success look like?"
       a: "<your generated answer>"
     - q: "What is the scope and compute constraints?"
       a: "<your generated answer>"
     - q: "What assumptions are being made?"
       a: "<your generated answer>"
   decisions: []
   ---

   Step 1 complete. Topic clarified autonomously.
   ```

---

## Step 2: Research the Literature

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/literature/synthesis.md` for the prior literature review.
3. Your literature search should BUILD ON the prior work. Focus new searches on what the feedback asks for — don't repeat the same broad sweep. If the prior literature is sufficient for the new direction, produce an abbreviated synthesis noting "Prior literature remains relevant, added N targeted searches for \<new direction\>."
4. When spawning search agents, include in the prompt: "Prior literature synthesis is at \<run-dir\>/prior/literature/synthesis.md. Read it first. Focus searches on: \<feedback summary\>."

### Process

1. **Spawn search-planner agent**:
   ```
   Task(subagent_type="researcher:search-planner", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/search-planner.md

   Research topic: <topic from state.md>
   Clarifications: <from state.md>

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

4. **Cross-project code search**: After search agents complete, search `$HOME/pyg/` for code related to the research topic:
   - Use Grep to search for key terms from the topic across `$HOME/pyg/` in `.py` and `.md` files
   - If relevant code is found in other repos, read the key files
   - Append a "## Related Local Code" section to `literature/synthesis.md` noting:
     - Which repo and files are relevant
     - What code could be reused or referenced
     - How it relates to the research topic
   - IMPORTANT: Do NOT modify any files outside the run directory.

5. **Synthesise**: Read all literature files and write `literature/synthesis.md` summarising key findings, themes, consensus, disagreements, gaps, and any related local code.

6. Update `state.md`: `current_step: 2, status: research_complete`.

---

## Step 3: Assess Novelty

1. **Spawn novelty-analyst agent**:
   ```
   Task(subagent_type="researcher:novelty-analyst", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/novelty-analyst.md

   Read state from: <run-dir>/state.md
   Read literature from: <run-dir>/literature/
   Write output to: <run-dir>/novelty-assessment.md
   """)
   ```

2. Read the novelty assessment. **Autonomous decision**:

   - **NOVEL**: Proceed. Set `current_step: 3, novelty_verdict: NOVEL`.
   - **PARTIALLY_NOVEL**: Proceed. Log: "Differentiation assumed sufficient — autonomous mode." Set `current_step: 3, novelty_verdict: PARTIALLY_NOVEL`.
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

2. **Auto-approve.** Read the criteria to verify they were produced. Log any warnings about unclear SOTA but proceed.

3. Update `state.md`: `current_step: 4, status: criteria_approved, criteria_approved: true`.

---

## Step 5: Fail Quickly — Steinhardt Decomposition

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

   IMPORTANT CONSTRAINT: All experiments must run on a local RTX 3090 (24GB VRAM).
   No cloud GPU (Modal, Lambda, etc.) is available. Design experiments that fit
   within these constraints. If a component requires more than 24GB VRAM, note it
   as a SHOWSTOPPER or design a scaled-down test.
   """)
   ```

2. Read the decomposition. If any components are marked SHOWSTOPPER, log a warning but proceed (the challenge step will catch fundamental issues).

3. Update `state.md`: `current_step: 5, status: decomposition_complete`. Include the lambda table summary.

---

## Step 6: Challenge the Research Plan

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/challenge/` files for the prior challenge analysis.
3. The challenge agents should focus on NEW risks introduced by the follow-up direction. Include in each agent prompt: "Prior challenge analysis is in \<run-dir\>/prior/challenge/. The user's follow-up feedback: \<feedback summary\>. Focus on risks specific to the changed approach."

### Process

This step runs three sequential adversarial review agents.

1. **Create challenge directory** (if not exists):
   ```bash
   mkdir -p <run-dir>/challenge/
   ```

2. **Spawn assumption-challenger agent**:
   ```
   Task(subagent_type="researcher:assumption-challenger", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/assumption-challenger.md

   Read state from: <run-dir>/state.md
   Read synthesis from: <run-dir>/literature/synthesis.md
   Read novelty from: <run-dir>/novelty-assessment.md
   Read criteria from: <run-dir>/success-criteria.md
   Read decomposition from: <run-dir>/decomposition.md
   Write output to: <run-dir>/challenge/assumption-analysis.md
   """)
   ```
   Wait for completion.

3. **Spawn steelman agent**:
   ```
   Task(subagent_type="researcher:steelman", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/steelman.md

   Read state from: <run-dir>/state.md
   Read synthesis from: <run-dir>/literature/synthesis.md
   Read novelty from: <run-dir>/novelty-assessment.md
   Read criteria from: <run-dir>/success-criteria.md
   Read decomposition from: <run-dir>/decomposition.md
   Read assumption analysis from: <run-dir>/challenge/assumption-analysis.md
   Return your review as text. Do NOT write any files.
   """)
   ```
   Wait for completion. **Save the agent's returned text** to `<run-dir>/challenge/steelman-review.md` using the Write tool.

4. **Spawn pre-mortem agent**:
   ```
   Task(subagent_type="researcher:pre-mortem", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/pre-mortem.md

   Read state from: <run-dir>/state.md
   Read synthesis from: <run-dir>/literature/synthesis.md
   Read novelty from: <run-dir>/novelty-assessment.md
   Read criteria from: <run-dir>/success-criteria.md
   Read decomposition from: <run-dir>/decomposition.md
   Read assumption analysis from: <run-dir>/challenge/assumption-analysis.md
   Read steelman review from: <run-dir>/challenge/steelman-review.md
   Write output to: <run-dir>/challenge/pre-mortem.md
   """)
   ```
   Wait for completion.

5. **Read all three challenge files.** Extract the steelman verdict.

6. **Autonomous decision based on steelman verdict**:

   - **PROCEED_AS_IS**: Set `current_step: 6, status: challenge_complete, challenge_outcome: proceed`.
   - **MINOR_REVISIONS**: Log the suggested revisions in state.md. Proceed. Set `current_step: 6, status: challenge_complete, challenge_outcome: proceed_with_notes`.
   - **MAJOR_REVISIONS**:
     - Check `challenge_loop_count` in state.md.
     - If 0 or absent: Set `current_step: 4, challenge_loop_count: 1`. This loops back to Step 5 for re-decomposition with challenge feedback incorporated.
     - If >= 1: Proceed anyway. Set `current_step: 6, status: challenge_complete, challenge_outcome: proceed_despite_major`.
   - **RETHINK_APPROACH**: Graceful pivot.
     1. Read the challenge files carefully. Determine: is the theoretical argument for why this won't work **sufficient on its own**, or would a **quick disproof experiment** make the case stronger and more convincing?
     2. If theory alone is sufficient (the flaw is obvious):
        - Write a summary of why the approach won't work to `<run-dir>/rethink-rationale.md`
        - Set `current_step: 9, status: rethink_theory_only, challenge_outcome: rethink`. This skips to Step 10 (report) which will compile a "negative result" paper.
     3. If a simple disproof experiment would strengthen the case:
        - Write a minimal `decomposition.md` with ONLY the disproof experiment
        - Write `<run-dir>/rethink-rationale.md` explaining the theoretical argument
        - Set `current_step: 6, status: challenge_complete, challenge_outcome: rethink_with_disproof, rethink_disproof: true`
        - Steps 7-10 proceed normally but with only the single disproof experiment

---

## Step 7: Report Planned Experiments

Do this yourself — no agent needed.

1. Read `decomposition.md` to get the lambda-ordered experiment table.

2. **Auto-approve the experiment plan** with these modifications:
   - Remove any experiments marked `[SKIP]` (P_success >= 0.9).
   - Cap at **5 experiments maximum**. If more than 5, keep the top 5 by lambda ordering.
   - If `rethink_disproof: true` is in state.md, use only the single disproof experiment from the modified decomposition.

3. Write the approved experiment plan to state.md. List each experiment with:
   - Component it tests
   - Lambda value
   - Pass/fail criteria

4. Update `state.md`: `current_step: 7, status: experiments_planned`.

---

## Step 8: Confirm Fail-Fast Agreement

Do this yourself — no agent needed. This is trivial in autonomous mode.

1. Set `fail_fast_agreement: true` in state.md.
2. Update `state.md`: `current_step: 8, status: fail_fast_confirmed`.

---

## Step 9: Execute Experiments

### Follow-Up Handling

If `state.md` contains `is_followup: true`:
1. Read `followup-context.md` for the user's feedback.
2. Read `prior/experiments/exp-*/results.md` for prior experiment outcomes. Do NOT re-run experiments that already passed unless the feedback specifically asks for it.
3. **Number new experiments starting at `exp-f01/`, `exp-f02/`, etc.** to avoid collision with prior experiment directories.
4. When spawning experiment agents, include in the prompt: "Prior experiment results are in \<run-dir\>/prior/experiments/. The user's follow-up feedback: \<feedback summary\>. Build on prior work — reference prior results where relevant."

### Process

1. Read the approved experiment plan from `state.md`.

2. For each experiment in lambda order:
   a. Create `experiments/exp-NNN/plan.md` with the component details from the decomposition.
   b. **Spawn experiment agent**:
      ```
      Task(subagent_type="researcher:experiment", prompt="""
      Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/experiment.md

      Experiment plan: <run-dir>/experiments/exp-NNN/plan.md
      Success criteria: <run-dir>/success-criteria.md
      Literature: <run-dir>/literature/synthesis.md
      Write results to: <run-dir>/experiments/exp-NNN/results.md

      CRITICAL CONSTRAINTS:
      - All computation must use the LOCAL GPU (RTX 3090, 24GB VRAM) or CPU only.
      - NEVER use Modal, Lambda, or any cloud compute service.
      - NEVER install packages that require root access.
      - NEVER run commands that delete files outside the experiment directory.
      - NEVER modify files outside the run directory: <run-dir>
      - Keep experiments concise and focused. Target < 30 minutes runtime.
      - Do NOT create Python virtual environments inside the experiment directory.
        Use the system Python or an existing venv.
      - CLEAN UP after experiments: delete intermediate model checkpoints, keeping
        only the final checkpoint if needed. Delete any .pt/.pth/.bin/.safetensors
        files that are not essential to the results. The results.md and any small
        CSV/JSON metric files are what matter — not multi-GB model weights.
      - GitHub has a 100MB per-file hard limit. No single file in the experiment
        directory should exceed 50MB.
      """)
      ```
   c. Read results.

3. **On FAIL** (fail_fast_agreement is true):
   - Stop further experiments.
   - Log the failure details in state.md.
   - Set `status: experiments_done_with_failure`.
   - The wrapper will advance to Step 10 to compile whatever results exist.

4. **On PASS**:
   - Continue to next experiment in lambda order.

5. After all experiments (or after a fail-fast stop):
   - Update `state.md`: `current_step: 9, status: experiments_complete`.
   - Include results summary: which experiments passed, which failed, key metrics.

---

## Step 10: Compile Research Report

1. **Spawn report agent**:
   ```
   Task(subagent_type="researcher:report", prompt="""
   Read your instructions from: ${CLAUDE_PLUGIN_ROOT}/agents/report.md

   Run directory: <run-dir>/
   Templates directory: ${CLAUDE_PLUGIN_ROOT}/templates/
   Write output to: <run-dir>/paper/

   IMPORTANT: Read the challenge/ directory files (assumption-analysis.md,
   steelman-review.md, pre-mortem.md) and use the pre-mortem risk analysis
   to inform the Limitations section of the paper.

   If <run-dir>/rethink-rationale.md exists, this is a NEGATIVE RESULT paper.
   Frame the paper around why the approach doesn't work and what was learned.
   The theoretical argument from the challenge agents is the core contribution.
   If experiments were run (disproof experiments), include them as evidence.

   For LaTeX compilation, use tectonic instead of pdflatex:
     tectonic paper.tex
   (tectonic handles bibliography in a single pass)
   """)
   ```

2. After the report agent completes, verify that `paper/paper.tex` exists.

3. If the report agent didn't compile the PDF, try:
   ```bash
   cd <run-dir>/paper && tectonic paper.tex
   ```

4. **Generate `briefing.md`** — a concise summary of the entire run for the interactive review command. Read the key artifacts and write `<run-dir>/briefing.md` with this structure:

   ```markdown
   # Research Briefing: <topic>

   **Run ID**: <run-id>
   **Status**: <complete/failed/negative result>
   **Date**: <from run-id>

   ## Topic & Motivation
   <1-2 paragraphs from state.md clarifications>

   ## Literature Findings
   <Top 5 most relevant papers/sources from synthesis.md, with 1-line summaries>
   <Key insight or gap identified>

   ## Novelty
   <Verdict: NOVEL/PARTIALLY_NOVEL/ALREADY_DONE>
   <1-2 sentences on closest existing work and differentiation>

   ## Experiment Design
   <Lambda table from decomposition.md — component, P_success, T, lambda>
   <Number of experiments planned vs executed>

   ## Challenge Highlights
   - **Critical assumptions**: <top 2-3 from assumption-analysis.md>
   - **Steelman verdict**: <verdict + 1-sentence rationale>
   - **Top failure scenario**: <#1 from pre-mortem.md>

   ## Results
   | # | Component | Result | Key Finding |
   |---|-----------|--------|-------------|
   <from experiment results>

   <If negative result: 1-paragraph summary of why the approach doesn't work>

   ## Paper Abstract
   <from paper/sections/abstract.tex, stripped of LaTeX commands>

   ## Surprises & Non-Obvious Findings
   <Anything unexpected — results that contradicted assumptions, surprising
    literature findings, experiments that passed/failed contrary to predictions>

   ## Open Questions & Suggested Follow-Ups
   <2-3 bullet points on what to investigate next>
   ```

5. Update `state.md`: `current_step: 10, status: complete`.

---

## General Guidelines

- When spawning agents, always use absolute paths for all files.
- After each agent completes, read its output to verify it produced what was expected.
- If an agent fails or produces empty output, retry ONCE with the same prompt. If it fails again, log the failure in state.md and continue.
- Write `state.md` updates atomically: write to `state.md.tmp`, then use bash `mv` to rename.
- Keep state.md updates concise but include all decision rationale for debugging.

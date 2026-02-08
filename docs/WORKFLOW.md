# Research Workflow Specification

This document defines the complete 9-step AI Safety R&D research workflow. The orchestrator (`commands/researcher.md`) reads this document at startup and follows it step by step.

## Architecture Constraints

- **The orchestrator is the sole hub.** It handles all user dialogue (AskUserQuestion), manages workflow state, spawns agents as leaf-node workers via Task, and implements all loop logic.
- **Agents are thin workers.** They read input files, do focused work, write output files. They never interact with the user and never spawn other agents.
- **State survives context compaction.** The orchestrator writes `state.md` after every step. If context is lost, it re-reads `state.md` to recover.

## Run Directory

Every run creates `output/<run-id>/` where `run-id` = `YYYY-MM-DD-<slugified-topic>`.

```
output/<run-id>/
├── state.md                    # Workflow state (YAML frontmatter + narrative)
├── search-plan.md              # Approved search plan
├── literature/
│   ├── search-001-academic.md  # arXiv + Semantic Scholar results
│   ├── search-002-blogs.md     # Lab blog results
│   ├── search-003-community.md # LessWrong, MIRI, ARC results
│   └── synthesis.md            # Synthesised literature review
├── novelty-assessment.md
├── success-criteria.md
├── decomposition.md            # Steinhardt lambda table + component details
├── experiments/
│   ├── exp-001/
│   │   ├── plan.md
│   │   ├── results.md
│   │   └── report-section.md
│   └── exp-002/ ...
├── references.bib              # Accumulated throughout workflow
├── citation-registry.md        # cite_key -> one-line description
└── paper/
    ├── preamble.tex
    ├── paper.tex
    ├── references.bib
    ├── sections/*.tex
    ├── Makefile
    └── paper.pdf
```

---

## Step 1: Clarify the Research Topic

**Actor**: Orchestrator (direct user dialogue)
**No agent spawned** — the orchestrator handles this interactively.

### Process

1. Acknowledge the user's topic.
2. Ask 3-5 clarifying questions via AskUserQuestion. Cover:
   - **Key terms**: What do specific terms mean in their context? What definitions are they working with?
   - **Prior exposure**: What papers, blog posts, or resources have they already read? What do they already know?
   - **Success criteria**: What would a successful outcome look like? A survey paper? A novel technique? A proof of concept?
   - **Scope boundaries**: What's explicitly out of scope? Any constraints on compute, time, or domain?
   - **Threat model / assumptions**: What assumptions are they making about the problem setting?
3. Create the run directory: `output/<run-id>/`.
4. Write `state.md` with YAML frontmatter:

```yaml
---
run_id: <run-id>
topic: <user's topic>
current_step: 1
status: clarifying
clarifications: []
decisions: []
---
```

5. After receiving answers, update `state.md` with clarifications and advance to Step 2.

### Completion Criteria

- At least 3 clarifying questions asked and answered.
- `state.md` exists with clarifications recorded.

---

## Step 2: Research the Literature

**Agents**: `search-planner` then parallel `search` instances

### Process

1. **Create search plan**: Spawn the `search-planner` agent with:
   - Input: topic + clarifications from `state.md`
   - Output: `search-plan.md` containing structured search tasks grouped by source:
     - **Academic**: arXiv API queries + Semantic Scholar API queries
     - **Lab blogs**: Site-specific searches for anthropic.com, openai.com, deepmind.google
     - **Community**: Site-specific searches for lesswrong.com, alignmentforum.org, intelligence.org, alignment.org, safe.ai, blog.redwoodresearch.org

2. **Review search plan**: Present the plan summary to the user via AskUserQuestion. Allow them to add/remove/modify search tasks.

3. **Execute searches in parallel**: Spawn one `search` agent per source group (typically 3 agents running concurrently):
   - Agent 1: Academic sources (arXiv API + Semantic Scholar API)
   - Agent 2: Lab blog sources (WebSearch with site: filters)
   - Agent 3: Community sources (WebSearch with site: filters)
   - Each writes results to `literature/search-NNN-<group>.md`
   - Each appends found citations to `references.bib` and `citation-registry.md`

4. **Synthesise**: The orchestrator reads all search results and writes `literature/synthesis.md` summarising:
   - Key findings by theme
   - Consensus vs disagreements
   - Most relevant papers/posts
   - Gaps in coverage

5. Update `state.md`: `current_step: 2, status: research_complete`.

### Citation Handling

Citations are accumulated as BibTeX entries throughout the workflow. Each search agent:
- Extracts bibliographic data from found sources
- Writes BibTeX entries to `references.bib`
- Registers `cite_key -> one-line description` in `citation-registry.md`

BibTeX sources (in order of preference):
1. CrossRef API (for DOI-bearing papers)
2. arXiv API (for arXiv papers)
3. Semantic Scholar API (fallback)
4. Manual construction from available metadata

---

## Step 3: Assess Novelty

**Agent**: `novelty-analyst`

### Process

1. Spawn `novelty-analyst` with:
   - Input: topic + clarifications + all literature files
   - Output: `novelty-assessment.md`

2. The agent evaluates:
   - Has this exact idea been done before?
   - How close are existing approaches?
   - What differentiates the proposed approach?
   - Verdict: `NOVEL`, `PARTIALLY_NOVEL`, or `ALREADY_DONE`

3. **If `ALREADY_DONE`**: Present the assessment to the user via AskUserQuestion with options:
   - "Refine the topic and search again" -> Loop to Step 2 with refined queries
   - "Proceed anyway — my approach differs because..." -> User explains differentiation, continue
   - "Abandon this topic" -> End the workflow

4. **If `PARTIALLY_NOVEL`**: Present findings, ask user to confirm differentiation is sufficient.

5. **If `NOVEL`**: Proceed to Step 4.

6. Update `state.md`: `current_step: 3, novelty_verdict: <verdict>`.

### Loop Condition

Step 3 can loop back to Step 2 if the user wants to refine the search after discovering overlapping work. The orchestrator appends new search tasks to the existing plan and spawns additional search agents.

---

## Step 4: Define Success Criteria

**Agent**: `criteria`

### Process

1. Spawn `criteria` agent with:
   - Input: topic + clarifications + literature synthesis + novelty assessment
   - Output: `success-criteria.md`

2. The agent identifies:
   - **State of the art (SOTA)**: Current best results/methods for the relevant task
   - **Benchmarks**: Standard evaluation benchmarks, datasets, metrics
   - **Publishability criteria**: What would make this work publishable? What venue? What bar?
   - **Minimum viable contribution**: The smallest result that would still be valuable

3. Present criteria to user via AskUserQuestion. The user may:
   - Agree -> proceed to Step 5
   - Disagree with SOTA assessment -> loop to Step 2 for more research
   - Disagree with benchmarks -> dialogue to refine, possibly loop to Step 3
   - Adjust publishability bar -> update criteria and proceed

4. Update `state.md`: `current_step: 4, criteria_approved: true/false`.

### Loop Conditions

- Disagreement with SOTA -> Step 2 (more research needed)
- Disagreement with benchmarks or novelty framing -> Step 3 (reassess novelty)

---

## Step 5: Fail Quickly — Steinhardt Decomposition

**Agent**: `decomposition`

### Process

1. Spawn `decomposition` agent with:
   - Input: topic + clarifications + literature + criteria
   - Output: `decomposition.md`

2. The agent decomposes the project into components and for each estimates:
   - **P_success**: Probability this component can be achieved (calibrated — see rubric below)
   - **T** (hours): Estimated time to test/validate this component
   - **lambda = -ln(P_success) / T**: Information rate — high lambda means fast learning about likely failure

3. Components are ordered by **descending lambda** (highest lambda = test first).

4. For components needing empirical evidence for P_success estimation, the orchestrator spawns additional `search` agents to gather data, then re-runs decomposition with updated information.

5. Update `state.md` with the lambda table.

### P_success Calibration Rubric

| P_success | Interpretation |
|-----------|---------------|
| 0.9 - 1.0 | Multiple successful replications exist. Mark `[SKIP]` — no experiment needed. |
| 0.7 - 0.9 | Similar work succeeded; minor adaptations needed. |
| 0.5 - 0.7 | Related work exists but not directly comparable. |
| 0.3 - 0.5 | Theoretical arguments exist but no empirical validation. |
| 0.1 - 0.3 | Known difficulties; previous failures documented. |
| < 0.05    | Mark `[SHOWSTOPPER]`. Ask user before proceeding. |

### Edge Cases

- P = 0: Clamp to 0.01 (avoid -ln(0) = infinity)
- P = 1: lambda = 0 — skip this component, no experiment needed
- T = 0: Clamp to 0.1 hours

### Lambda Table Format

```
| # | Component | P_success | T (hrs) | lambda | Quick Test | Status |
|---|-----------|-----------|---------|--------|------------|--------|
| 1 | <name>    | 0.25      | 1.0     | 1.39   | <desc>     | PENDING |
| 2 | <name>    | 0.40      | 2.0     | 0.46   | <desc>     | PENDING |
```

---

## Step 6: Report Planned Experiments

**Actor**: Orchestrator (direct user dialogue)

### Process

1. Present the lambda-ordered experiment table to the user.
2. For each experiment, explain:
   - Which component it tests
   - Why it's ordered where it is (lambda rationale)
   - What a pass/fail means for the project
3. Identify experiments that can run in parallel (independent components).
4. Ask user to confirm: "Does each experiment test a crucial component? Any missing?"
5. Allow user to:
   - Reorder experiments
   - Add/remove experiments
   - Adjust P_success estimates
   - Loop back to Step 5 if decomposition needs revision

6. Update `state.md` with approved experiment plan.

---

## Step 7: Confirm Fail-Fast Agreement

**Actor**: Orchestrator (direct user dialogue)

### Process

1. State clearly: "If the highest-lambda experiment fails, the project will either terminate or pivot. Do you agree to this protocol?"
2. Ask user to explicitly agree via AskUserQuestion:
   - "Yes, I agree — fail fast" -> proceed
   - "I want to discuss conditions" -> dialogue about which failures are fatal vs recoverable
   - "No, run all experiments regardless" -> note this, adjust workflow (all experiments run regardless of failure)

3. Record the agreement in `state.md`: `fail_fast_agreement: true/false/conditional`.

---

## Step 8: Execute Experiments

**Agent**: `experiment` (one per experiment)

### Process

1. Execute experiments in **lambda order** (highest lambda first).

2. For each experiment:
   a. Create `experiments/exp-NNN/plan.md` from the decomposition table
   b. Spawn `experiment` agent with:
      - Input: experiment plan + relevant literature + success criteria
      - Output: `experiments/exp-NNN/results.md` with clear **PASS** or **FAIL** against predefined criteria
   c. Read results

3. **On FAIL** (and fail_fast_agreement is true):
   - Stop further experiments
   - Present failure to user: what failed, why, implications
   - Ask: "Pivot topic?" / "Adjust approach?" / "Write up the failure?"
   - If "write up failure" -> skip to Step 9 with failure narrative

4. **On PASS**:
   - If possible, split: spawn next experiment AND spawn `experiment` agent to write `experiments/exp-NNN/report-section.md` (parallel execution)
   - Continue to next experiment in lambda order

5. **Parallel execution**: Independent experiments (no shared components) can run concurrently. The orchestrator tracks which experiments are independent based on the decomposition.

6. Update `state.md` after each experiment: record result, update status in lambda table.

---

## Step 9: Compile Research Report

**Agent**: `report`

### Process

1. Spawn `report` agent with:
   - Input: ALL artefacts from the run directory
   - Templates from `${CLAUDE_PLUGIN_ROOT}/templates/`
   - Output: `paper/` directory with complete LaTeX project

2. The agent produces:
   - **Title**: Descriptive, specific
   - **Abstract**: 150-250 words
   - **Introduction**: Key points as structured bullets (to be expanded later)
   - **Related Work**: Synthesised from literature review with proper citations
   - **Methodology**: From decomposition + experiment plans
   - **Initial Experiments & Results**: From completed experiment reports
   - **Planned Major Experiments**: From experiments not yet run (if any)
   - **Discussion**: Preliminary interpretation of results
   - **Conclusion**: Empty section with placeholders for future work
   - **References**: Real BibTeX only — no fabricated citations

3. **BibTeX verification**: The agent verifies all citations exist in `references.bib` and cross-checks against `citation-registry.md`. Missing BibTeX is fetched from:
   - CrossRef API (DOI lookup)
   - arXiv API
   - Semantic Scholar API

4. **LaTeX compilation**: If `pdflatex` is available, compile the paper:
   ```
   pdflatex paper && bibtex paper && pdflatex paper && pdflatex paper
   ```
   If `pdflatex` is not available, inform the user and leave the .tex files for manual compilation.

5. Present the final paper location to the user.

---

## Search Strategy

Three source groups are searched in parallel:

### 1. Academic (arXiv + Semantic Scholar)

- **arXiv API**: `curl` requests to `http://export.arxiv.org/api/query` with category filters (cs.AI, cs.LG, cs.CL, etc.)
- **Semantic Scholar API**: `curl` requests to `https://api.semanticscholar.org/graph/v1/paper/search` with field filters
- Retrieve: title, authors, abstract, year, URL, citation count

### 2. Lab Blogs

- **WebSearch** with `site:` filters:
  - `site:anthropic.com`
  - `site:openai.com`
  - `site:deepmind.google`
  - `site:transformer-circuits.pub`
- Retrieve: title, date, URL, key claims

### 3. Community

- **WebSearch** with `site:` filters:
  - `site:lesswrong.com`
  - `site:alignmentforum.org`
  - `site:intelligence.org`
  - `site:alignment.org`
  - `site:safe.ai`
  - `site:blog.redwoodresearch.org`
- Retrieve: title, author, date, URL, key arguments

---

## State Management

`state.md` uses YAML frontmatter for machine-readable state and a narrative body for human readability.

```yaml
---
run_id: "2026-02-07-interpretability-of-sparse-autoencoders"
topic: "Interpretability of Sparse Autoencoders"
current_step: 5
status: decomposition_complete
clarifications:
  - q: "What do you mean by interpretability?"
    a: "Feature-level interpretability — can we assign human-readable labels to SAE features?"
  - q: "What prior work have you read?"
    a: "Anthropic's Scaling Monosemanticity, Cunningham et al. 2023"
decisions:
  - step: 3
    decision: "Novel — no prior work on automated SAE feature labelling at scale"
  - step: 4
    decision: "Success = >80% agreement between automated and human labels on top-100 features"
novelty_verdict: NOVEL
criteria_approved: true
fail_fast_agreement: true
lambda_table:
  - component: "SAE training convergence"
    p_success: 0.85
    t_hours: 2.0
    lambda: 0.08
    status: SKIP
  - component: "Automated labelling pipeline"
    p_success: 0.40
    t_hours: 1.0
    lambda: 0.92
    status: PENDING
experiments_completed: []
experiments_failed: []
---

# Workflow Progress

## Step 1: Clarifications
Topic clarified. User interested in automated feature labelling for SAEs.

## Step 2: Literature Review
Completed. Found 23 relevant sources across academic, blog, and community channels.

## Step 3: Novelty Assessment
Verdict: NOVEL. Closest existing work is manual labelling by Anthropic team.

## Step 4: Success Criteria
Approved. Targeting 80% human-automated agreement on feature labels.

## Step 5: Decomposition
Lambda table computed. 6 components identified, ordered by information rate.
```

### Context Recovery

If the orchestrator loses context (due to context compaction), it should:

1. Read `state.md` to determine current step
2. Read relevant artefact files for the current step
3. Resume from where it left off

The orchestrator should re-read `state.md` at the start of every major step to ensure it has the latest state.

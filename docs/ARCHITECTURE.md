# Architecture

## Overview

The AI Safety R&D Agent is a Claude Code plugin that orchestrates an 11-step research workflow using a hub-and-spoke architecture. A single orchestrator command manages all user dialogue and dispatches specialised leaf-node agents for focused work.

## Design Principles

1. **Hub-and-spoke** — The orchestrator (`/researcher`) is the sole hub. It handles all user interaction and spawns all agents. Agents are leaf workers that never interact with users or spawn other agents.
2. **Fail fast** — The Steinhardt decomposition method orders experiments by information rate (lambda), testing the riskiest components first.
3. **State persistence** — Every step writes to `state.md`, enabling recovery from context compaction.
4. **Iterative** — The workflow supports looping between steps when the user or the evidence demands it.
5. **Transparency** — Every step produces markdown artefacts that the user can inspect, steer, and override.

## Pipeline

```
/researcher <topic>
    │
    ▼
┌──────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATOR                              │
│  (commands/researcher.md — handles all user dialogue & loops)    │
│                                                                  │
│  Step 1: Clarify ◄──────────────────────────────────────────┐    │
│    │ (direct dialogue)                                      │    │
│    ▼                                                        │    │
│  Step 2: Research ──────────────────────────────────────┐    │    │
│    │ ┌─────────────────┐   ┌──────────┐ x3 parallel    │    │    │
│    ├─┤ search-planner  ├──►│  search   │───────────►    │    │    │
│    │ └─────────────────┘   └──────────┘                │    │    │
│    ▼                                              loop │    │    │
│  Step 3: Novelty ─────────────────────────────────┘    │    │    │
│    │ ┌─────────────────┐                               │    │    │
│    ├─┤ novelty-analyst  │                               │    │    │
│    │ └─────────────────┘                          loop │    │    │
│    ▼                                              ┌────┘    │    │
│  Step 4: Criteria ────────────────────────────────┤         │    │
│    │ ┌─────────────────┐                          └────┐    │    │
│    ├─┤    criteria      │                               │    │    │
│    │ └─────────────────┘                               │    │    │
│    ▼                                              loop │    │    │
│  Step 5: Decompose ───────────────────────────────┘    │    │    │
│    │ ┌─────────────────┐                               │    │    │
│    ├─┤  decomposition   │                               │    │    │
│    │ └─────────────────┘                               │    │    │
│    ▼                                              loop │    │    │
│  Step 6: Challenge ───────────────────────────────┘    │    │    │
│    │ ┌──────────────────────┐  (parallel)              │    │    │
│    ├─┤ assumption-challenger │                          │    │    │
│    ├─┤ mentor-review         │                          │    │    │
│    ├─┤ pre-mortem           │                               │    │
│    │ └──────────────────────┘                               │    │
│    ▼                                                        │    │
│  Step 7: Report Plan (direct dialogue) ─────────────────────┘    │
│    │                                                             │
│    ▼                                                             │
│  Step 8: Confirm Fail-Fast (direct dialogue)                     │
│    │                                                             │
│    ▼                                                             │
│  Step 9: Execute ────────────────────────────────────────────────┘
│    │ ┌─────────────────┐  (one per experiment, lambda order)
│    ├─┤   experiment     │  fail → stop or pivot
│    │ └─────────────────┘  pass → continue + write up
│    ▼
│  Step 10: Audit ◄────────────────┐  (re-run flagged exp, re-audit; ≤ R_MAX)
│    │ ┌─────────────────┐         │
│    ├─┤ results-auditor  │─────────┘  FIXABLE-DEFECT → loop
│    │ └─────────────────┘            SUPPORTED / TRUE-NULL → exit
│    ▼
│  Step 11: Report
│    │ ┌─────────────────┐
│    ├─┤     report       │  → LaTeX paper
│    │ └─────────────────┘
│    ▼
│  Done
└──────────────────────────────────────────────────────────────────┘
```

## Agent Inventory

| Agent | File | Step | Model | Purpose |
|-------|------|------|-------|---------|
| search-planner | `agents/search-planner.md` | 2 | sonnet | Creates structured search plan from topic + clarifications |
| search | `agents/search.md` | 2 | sonnet | Executes a single search task (parallelisable, multiple instances) |
| novelty-analyst | `agents/novelty-analyst.md` | 3 | fable | Assesses whether the idea has been done before |
| criteria | `agents/criteria.md` | 4 | fable | Identifies SOTA, success criteria, benchmarks |
| decomposition | `agents/decomposition.md` | 5 | fable | Steinhardt decomposition: components, P_success, T, lambda ordering |
| assumption-challenger | `agents/assumption-challenger.md` | 6 | fable | Surfaces unstated assumptions in the research plan |
| mentor-review | `agents/mentor-review.md` | 6 | fable | Senior researcher review — simpler paths, blind spots, honest feedback |
| pre-mortem | `agents/pre-mortem.md` | 6 | fable | Failure scenario analysis — root causes, early warnings, mitigations |
| experiment | `agents/experiment.md` | 9 | fable | Executes a single experiment, reports pass/fail |
| results-auditor | `agents/results-auditor.md` | 10 | fable | Independently red-teams the results; classifies findings and drives the audit-remediation loop |
| report | `agents/report.md` | 11 | fable | Compiles all artefacts into LaTeX paper with real BibTeX |

## Directory Layout

```
researcher/
├── .claude/
│   └── settings.local.json         # Plugin-specific permissions
├── .claude-plugin/
│   └── plugin.json                  # Plugin manifest
├── commands/
│   ├── researcher.md                # Interactive orchestrator (11-step workflow)
│   ├── researcher-auto-step.md      # Autonomous per-step executor (no user interaction)
│   └── researcher-auto-email.md     # Autonomous email composer (sends results)
├── scripts/
│   └── researcher-cron.sh           # Cron wrapper: issue pickup, step loop, repo creation
├── skills/
│   └── research-workflow/
│       └── SKILL.md                 # Auto-trigger skill definition
├── agents/
│   ├── search-planner.md            # Step 2: Search plan creation
│   ├── search.md                    # Step 2: Single search execution
│   ├── novelty-analyst.md           # Step 3: Novelty assessment
│   ├── criteria.md                  # Step 4: Success criteria
│   ├── decomposition.md             # Step 5: Steinhardt decomposition
│   ├── assumption-challenger.md     # Step 6: Assumption analysis
│   ├── mentor-review.md             # Step 6: Senior researcher review
│   ├── pre-mortem.md                # Step 6: Failure scenario analysis
│   ├── experiment.md                # Step 9: Experiment execution
│   ├── results-auditor.md           # Step 10: Independent results audit
│   └── report.md                    # Step 11: LaTeX paper compilation
├── templates/
│   ├── preamble.tex                 # LaTeX preamble
│   ├── paper.tex                    # Main document template
│   ├── Makefile                     # LaTeX build file
│   └── sections/
│       └── .gitkeep
├── hooks/
├── docs/
│   ├── ARCHITECTURE.md              # This file
│   ├── AUTONOMOUS.md                # Autonomous mode setup and reference
│   ├── DIAGRAM.md                   # Mermaid architecture diagrams
│   ├── STANCE.md                    # Canonical truth-seeking Voice block + KEEP/REFRAME rubric
│   └── WORKFLOW.md                  # Detailed 11-step workflow specification
├── output/                          # Research artefacts (gitignored)
├── logs/                            # Autonomous mode logs (gitignored)
├── CLAUDE.md                        # Project-level Claude context
└── .gitignore
```

## State Management

Every run writes `output/<run-id>/state.md` with YAML frontmatter tracking:
- Current step and status
- User clarifications and decisions
- Novelty verdict
- Criteria approval
- Fail-fast agreement
- Lambda table (component decomposition)
- Experiment results

The orchestrator re-reads `state.md` at the start of each step and after any context compaction event, enabling seamless recovery.

## Output Artefacts

Each run produces artefacts in `output/<run-id>/`:

- `state.md` — Workflow state and history
- `search-plan.md` — Approved search plan
- `literature/` — Search results and synthesis
- `novelty-assessment.md` — Novelty analysis
- `success-criteria.md` — SOTA, benchmarks, publishability bar
- `decomposition.md` — Lambda table and component details
- `challenge/` — Assumption analysis, mentor review, pre-mortem
- `experiments/exp-NNN/` — Experiment plans, results, `run.log`, report sections
- `audit/` — Results auditor findings (`results-audit.md`) and round-1 claim anchors
- `references.bib` — Accumulated BibTeX citations
- `citation-registry.md` — Citation key registry
- `paper/` — Complete LaTeX project with compiled PDF

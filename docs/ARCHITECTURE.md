# Architecture

## Overview

The AI Safety R&D Agent is a dual Claude Code and OpenAI Codex plugin that
orchestrates an 11-step research workflow using a hub-and-spoke architecture.
A single orchestrator command/skill manages all user dialogue and dispatches
specialised leaf-node agents for focused work.

## Design Principles

1. **Hub-and-spoke** — The Claude `/researcher` command or Codex `researcher`
   skill is the sole hub. It handles all user interaction and spawns all
   agents. Agents are leaf workers that never interact with users or spawn
   other agents.
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
│  Step 6: Challenge ───────────────────────────────┴────┼────┤    │
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
│  Step 10: Audit ◄────────────────┐  (re-run flagged exp, re-audit; ≤ R_MAX rounds)
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

| Agent | File | Step | Claude | Codex default | Purpose |
|-------|------|------|--------|---------------|---------|
| search-planner | `agents/search-planner.md` | 2 | sonnet | fast | Creates structured search plan from topic + clarifications |
| search | `agents/search.md` | 2 | sonnet | fast | Executes a single search task (parallelisable, multiple instances) |
| novelty-analyst | `agents/novelty-analyst.md` | 3 | fable | deep | Assesses whether the idea has been done before |
| criteria | `agents/criteria.md` | 4 | fable | deep | Identifies SOTA, success criteria, benchmarks |
| decomposition | `agents/decomposition.md` | 5 | fable | deep | Steinhardt decomposition: components, P_success, T, lambda ordering |
| assumption-challenger | `agents/assumption-challenger.md` | 6 | fable | deep | Surfaces unstated assumptions in the research plan |
| mentor-review | `agents/mentor-review.md` | 6 | fable | deep | Senior researcher review — simpler paths, blind spots, honest feedback |
| pre-mortem | `agents/pre-mortem.md` | 6 | fable | deep | Failure scenario analysis — root causes, early warnings, mitigations |
| experiment | `agents/experiment.md` | 9 | fable | deep | Executes a single experiment, reports pass/fail |
| results-auditor | `agents/results-auditor.md` | 10 | fable | deep | Independently red-teams the results; classifies findings and drives the audit-remediation loop |
| report | `agents/report.md` | 11 | fable | deep | Compiles all artefacts into LaTeX paper with real BibTeX |
| knowledge | `agents/knowledge.md` | 2, 6, 11 | fable | deep | Queries and ingests the global wiki and the per-repo knowledge base; also lints on request. Optional and non-blocking — see [`KNOWLEDGE-BASE.md`](KNOWLEDGE-BASE.md) |

Codex `fast` and `deep` are runtime roles (`templates/codex-adapter.md`), whose
models are settings with defaults in `config/researcher.env`, so they change
without changing shared agent files.

## Directory Layout

The repo map in [`AGENTS.md`](../AGENTS.md) lists the directories and entry points.

## State Management

Every run writes `output/<run-id>/state.md`: YAML frontmatter for the
machine-readable state and a narrative body, whose fields
[`WORKFLOW.md`](WORKFLOW.md#state-management) gives. The orchestrator re-reads
it at the start of each step and after a context compaction, and resumes from
the step it records.

## Output Artefacts

Each run writes its artefacts to `output/<run-id>/`, laid out as
[`WORKFLOW.md`](WORKFLOW.md#run-directory) shows.

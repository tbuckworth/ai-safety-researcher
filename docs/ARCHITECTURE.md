# Architecture

## Overview

The AI Safety R&D Agent is a multi-agent system built as a Claude Code plugin. It orchestrates a structured research workflow through a pipeline of specialised agents, each responsible for a distinct phase of the research process.

## Design Principles

1. **Modularity** — Each research phase is handled by a dedicated agent with a focused system prompt and toolset.
2. **Composability** — Agents can be invoked independently or as part of the full pipeline.
3. **Transparency** — Every step produces artefacts (markdown files) that the user can inspect and steer.
4. **Iterability** — The workflow supports looping back to earlier phases based on review findings.

## Agent Pipeline

```
/researcher <topic>
    │
    ▼
┌─────────────────────┐
│  1. Scoping Agent    │  — Refine the research question, define scope & constraints
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  2. Literature Agent │  — Discover, retrieve, and synthesise relevant work
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  3. Analysis Agent   │  — Identify gaps, tensions, and open problems
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  4. Hypothesis Agent │  — Generate and rank candidate hypotheses
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  5. Experiment Agent │  — Design experiments / evaluation protocols
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  6. Critique Agent   │  — Adversarial review of the full research plan
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│  7. Synthesis Agent  │  — Compile final report and recommendations
└─────────────────────┘
```

## Directory Layout

```
researcher/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── commands/
│   └── researcher.md            # Entry-point slash command
├── skills/
│   └── research-workflow/
│       └── SKILL.md             # Auto-trigger skill definition
├── agents/
│   ├── scoping-agent.md         # Phase 1: Scoping
│   ├── literature-agent.md      # Phase 2: Literature review
│   ├── analysis-agent.md        # Phase 3: Gap analysis
│   ├── hypothesis-agent.md      # Phase 4: Hypothesis generation
│   ├── experiment-agent.md      # Phase 5: Experiment design
│   ├── critique-agent.md        # Phase 6: Adversarial review
│   └── synthesis-agent.md       # Phase 7: Final synthesis
├── hooks/
│   └── (lifecycle hooks)
├── docs/
│   ├── ARCHITECTURE.md          # This file
│   └── WORKFLOW.md              # Detailed workflow specification
├── output/                      # Research artefacts (gitignored)
├── CLAUDE.md                    # Project-level Claude context
└── README.md
```

## Settings Isolation

This plugin uses its own project-level settings to avoid inheriting universal Claude Code configuration. The `.claude/settings.local.json` in this repo defines permissions and behaviour specific to the research workflow.

## Output Artefacts

Each research run produces artefacts in an `output/<run-id>/` directory:

- `scope.md` — Refined research question and constraints
- `literature.md` — Literature review and synthesis
- `analysis.md` — Gap analysis and open problems
- `hypotheses.md` — Ranked candidate hypotheses
- `experiments.md` — Experimental designs and protocols
- `critique.md` — Adversarial review notes
- `report.md` — Final consolidated research report

# AI Safety R&D Agent

This repository is a Claude Code plugin that implements an automated AI Safety research workflow.

## Project Context

- **Purpose**: End-to-end AI safety research automation — from topic clarification through literature review, novelty assessment, fail-fast experiment design (Steinhardt method), experiment execution, and LaTeX paper compilation.
- **Architecture**: Hub-and-spoke orchestrator. The `/researcher` command is the sole hub — it handles all user dialogue and dispatches leaf-node agents via Task. Agents never interact with users or spawn other agents.
- **Entry point**: `/researcher <topic>` slash command.

## Key Directories

- `agents/` — Agent definitions (10 agents: search-planner, search, novelty-analyst, criteria, decomposition, assumption-challenger, steelman, pre-mortem, experiment, report)
- `commands/` — Slash command entry points (orchestrator)
- `skills/` — Auto-trigger skill definitions
- `docs/` — Architecture and workflow specifications (WORKFLOW.md is the master document)
- `templates/` — LaTeX templates for paper compilation
- `output/` — Research artefacts (gitignored)

## Development Notes

- This plugin has its own isolated settings in `.claude/settings.local.json`.
- Agents are thin leaf workers: they read input files, do focused work, write output files.
- The orchestrator writes `state.md` after every step for context recovery.
- All research artefacts are written to `output/<run-id>/`.
- The workflow is interactive and iterative — Steps 3, 4, 6, and 7 can loop back to earlier steps.

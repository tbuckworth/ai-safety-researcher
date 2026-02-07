# AI Safety R&D Agent

This repository is a Claude Code plugin that implements an automated AI Safety research workflow.

## Project Context

- **Purpose**: End-to-end AI safety research automation — from topic scoping through literature review, hypothesis generation, experimental design, and final synthesis.
- **Architecture**: Multi-agent pipeline where specialised agents handle each research phase.
- **Entry point**: `/researcher <topic>` slash command.

## Key Directories

- `agents/` — Agent definitions (one per research phase)
- `commands/` — Slash command entry points
- `skills/` — Auto-trigger skill definitions
- `docs/` — Architecture and workflow specifications
- `output/` — Research artefacts (gitignored)

## Development Notes

- This plugin has its own isolated settings — it does NOT use the user's universal Claude Code configuration.
- Agents are designed to be composable: they can run standalone or as part of the pipeline.
- All research artefacts are written as markdown to `output/`.

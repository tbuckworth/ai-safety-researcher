# AI Safety R&D Agent

This repository is a dual Claude Code and OpenAI Codex plugin that implements
an automated AI Safety research workflow.

## Project Context

- **Purpose**: End-to-end AI safety research automation — from topic clarification through literature review, novelty assessment, fail-fast experiment design (Steinhardt method), experiment execution, and LaTeX paper compilation.
- **Architecture**: Hub-and-spoke orchestrator. The Claude `/researcher`
  command or Codex `researcher` skill is the sole hub. It handles all user
  dialogue and dispatches leaf-node agents through the selected provider.
  Agents never interact with users or spawn other agents.
- **Entry points**:
  - `/researcher <topic>` — Claude interactive mode
  - `$researcher:researcher <topic>` — Codex interactive mode
  - `scripts/researcher-cron.sh [topic]` — Autonomous mode (no human interaction, for cron)
  - `/researcher-review` or `$researcher:researcher-review` — Interactive review
  - `/researcher-continue` or `$researcher:researcher-continue` — Pick a next step from a finished run and queue the follow-up

## Key Directories

- `agents/` — Agent definitions (12 agents: search-planner, search, novelty-analyst, criteria, decomposition, assumption-challenger, mentor-review, pre-mortem, experiment, results-auditor, report, knowledge)
- `commands/` — Slash command entry points (orchestrator)
- `skills/` — Auto-trigger skill definitions
- `docs/` — Architecture and workflow specifications (WORKFLOW.md is the master document)
- `templates/` — LaTeX templates for paper compilation
- `data/model-organisms/` — Curated database of reusable misaligned "model organisms" (organisms.yaml + models.md) an autonomous run can pick from to test methods against
- `templates/kb-schema.md` — Schema for the global research wiki, copied into the wiki root by `scripts/kb-init.sh`
- `output/` — Research artefacts (gitignored)

## Development Notes

- Claude-specific settings live in `.claude/settings.local.json`; Codex
  packaging lives in `.codex-plugin/plugin.json` and `skills/`.
- Agents are thin leaf workers: they read input files, do focused work, write output files.
- The orchestrator writes `state.md` after every step for context recovery.
- All research artefacts are written to `output/<run-id>/`.
- The workflow is interactive and iterative — Steps 3, 4, 6, and 7 can loop back to earlier steps.
- Keep shared workflow payloads provider-neutral. Put only thin translation
  logic in Codex skills or the autonomous runner.
- Validate backend changes with `scripts/test-researcher-backends.sh`; it must
  not call real models, GitHub, GPUs, or email.

## Autonomous Mode

- **Entry point**: `scripts/researcher-cron.sh [topic]` — picks from GitHub Issues if no topic given.
- **Architecture**: Multi-session state machine. The bash wrapper reads
  `state.md`, launches one Claude or Codex session per step, and loops until
  complete. Select with `RESEARCHER_BACKEND`; Claude is the default.
- **Commands**: `researcher-auto-step` (per-step executor), `researcher-auto-email` (email composer).
- **GitHub Issues**: Picks from `tbuckworth/tasks` with label
  `list:research-ideas`, then uses backend-specific `status:<backend>-*`
  labels.
- **Follow-ups**: Issues with label `type:follow-up` trigger follow-up mode — clones prior artifacts into `prior/`, fast-forwards past unchanged steps, pushes results to a branch on the existing repo. Created via `/researcher-review` during interactive review sessions.
- **Constraints**: Per-run compute profile (`RESEARCHER_COMPUTE_PROFILE`, default local RTX 3090; presets: `local`, `mats` for the MATS Slurm cluster — see `docs/COMPUTE-MATS.md`; also supports cloud/managed backends), max 5 experiments, all loops capped at 1 iteration.
- **Construct-validity gate** (Step 6): a strawman/known-outcome construct loops back to Step 1 once to redesign, rather than being disclaimed. Limitations are triaged (fix-now vs future-work) at Steps 6/10 and written up with a dedicated resource-scoped Future Work section at Step 11.
- **Next steps**: every run writes `next-steps.md` (reflection + ranked, resourced next round), including runs that failed or produced a negative result. The results email carries it and tells the reader exactly how to act on it via `/researcher-continue`.
- **Knowledge bases** (`docs/KNOWLEDGE-BASE.md`): a global wiki (`RESEARCHER_KB_DIR`) queried at Steps 2/3/6 and ingested at Steps 2/11, plus a per-repo `knowledge/` directory. Both optional — every KB action is skipped silently when absent and never blocks a step.
- **Setup**: See `docs/AUTONOMOUS.md` for cron configuration, prerequisites, and follow-up workflow.

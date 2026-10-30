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
  - `scripts/researcher-cron.sh [topic]` — Autonomous mode (no human interaction; launched by agent-board's `agent-spare` systemd timer, or by hand/cron)
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
- Validate runner changes with `scripts/test-researcher-backends.sh`,
  `scripts/test-researcher-lifecycle.sh` and `python3 -m unittest discover -s scripts/tests`;
  none of them may call real models, GitHub, GPUs, or email (GitHub is a mock
  `gh` plus local bare repos via `RESEARCHER_GIT_REMOTE_BASE`).

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
- **Final outcome**: after publishing, `scripts/researcher_lib.py` derives `final_outcome` (`complete` / `complete-local` / `unpublished` / `no-results` / `partial` / `failed` / `paused`) from the workflow status, valid experiment verdicts, and a verified push; it goes into `state.md`, `run-outcome.json`, the email and the issue comment. Run repos are private by default (`RESEARCHER_REPO_VISIBILITY`).
- **Pre-flight gate**: Step 1 writes `method-spec.md`; every experiment writes `preflight.md` (template in `templates/`, tooling in `scripts/preflight_checks.py`). A `FAIL` there makes the verdict `INCONCLUSIVE`.
- **Setup**: See `docs/AUTONOMOUS.md` for how runs are launched (agent-board's `agent-spare`, which logs to `~/.local/state/agent-board/spare/run.log`; the crontab line is disabled), prerequisites, and follow-up workflow.

<!-- claude-tooling: codex checklist review -->
## Checklist review (Codex)

This repository runs one checklist review gate for Claude Code and Codex. The configuration
and the review chain live under `.claude/`; the Codex wiring is `.codex/hooks.json`, and the
reviewer is the `checklist-reviewer` subagent role in `.codex/agents/checklist-reviewer.toml`,
which pins its model. Claude Code reads this section too, through `CLAUDE.md`, but runs its
reviewer as the gate's block message says; the steps below are for Codex sessions.

- Codex runs only trusted project hooks and skips an untrusted one without a word, so until
  `.codex/hooks.json` is trusted in `/hooks` (again after any change to it) there is no gate.
  A commit that goes through with no review is the sign; check `/hooks`.
- When the gate blocks a command, spawn the reviewer it asks for: `spawn_agent` with
  `agent_type="checklist-reviewer"`, `fork_turns="none"` and no model override, with the
  gate's prompt as the message. The reviewer must not see the conversation that wrote the
  diff, and a hook refuses any other spawn of it. On a retry, send the new prompt to the same
  reviewer with `followup_task`, or spawn a fresh one if it is gone.
- To review before a gate asks, run `.venv/bin/claude-tooling review-prompt` (or use
  `$checklist-review`) and pass its output to a fresh reviewer the same way.
- Never write `.claude/reviews/` yourself: only the reviewer writes `verdict.json`, with
  `apply_patch`, and hooks refuse every other write there, from `apply_patch` or the shell.
  Reading it is allowed.
- A verdict is valid for exactly one diff hash. After fixing findings, re-stage (commit
  trigger) or commit (PR trigger) and run one new review; then retry the gated command. A
  commit that fails after the gate allowed it is retried with the same verdict.
- Under the commit trigger the review covers exactly the staged diff, so stage with
  `git add <paths>` in its own command and run a plain `git commit -m "…"`. The gate refuses
  `-a`, paths on the command line, `--only`, `--include`, `--pathspec-from-file`, `--patch`
  and `--interactive`, and any commit whose options it cannot parse.
- Run the commit as a command of its own, after any staging: the gate reads the staged diff
  before the command runs, so it refuses a commit that shares the command with anything that
  might change the index before or alongside it. Only navigation and read-only checks (`cd`,
  `git status`) may come first, and only a filter such as `tail` may take its output; the
  refusal lists what is allowed.
- Write a plain `git commit`, not one behind `eval`, `sh -c` text built from variables,
  `xargs` or a wrapper such as `timeout`: the gate refuses a commit it cannot read.
- Do not bypass the gate or treat a failing item as advisory.
<!-- /claude-tooling: codex checklist review -->

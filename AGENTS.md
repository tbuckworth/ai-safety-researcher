# AI Safety R&D Agent

A Claude Code and OpenAI Codex plugin that automates AI safety research, from
clarifying a topic to a LaTeX paper. `README.md` says what it does and how to
install it, `docs/WORKFLOW.md` specifies the workflow, and `docs/AUTONOMOUS.md`
covers the autonomous runner.

## Rules

- The orchestrator (`commands/researcher.md`, or the Codex `researcher` skill)
  is the only hub: it alone talks to the user and dispatches agents. Agents are
  leaf workers that read input files and write output files; they never talk to
  the user or spawn other agents.
- Keep shared workflow payloads provider-neutral. Put only thin translation
  logic in Codex skills or the autonomous runner.
- Validate a change with the commands below. None of them may call real models,
  GitHub, GPUs or email (GitHub is a mock `gh` plus local bare repos via
  `RESEARCHER_GIT_REMOTE_BASE`).

  ```bash
  for f in scripts/*.sh scripts/runner/*.sh scripts/tests/*.sh; do bash -n "$f"; done
  shellcheck -x scripts/researcher-cron.sh scripts/runner/*.sh scripts/test-researcher-backends.sh scripts/test-researcher-lifecycle.sh
  bash scripts/test-researcher-backends.sh
  bash scripts/test-researcher-lifecycle.sh
  python3 -m unittest discover -s scripts/tests
  bash scripts/check-voice-blocks.sh
  ```

## Repo map

Directories:

- `agents/`: the leaf agents' prompts, one file each, catalogued in `docs/ARCHITECTURE.md`.
- `commands/`: the command prompts: the orchestrator, the commands below, and the step, next-steps and email prompts the autonomous runner gives its sessions.
- `skills/`: `research-workflow/`, which starts the workflow when a request asks for research, and one Codex adapter per command (`researcher*/`).
- `docs/`: the user documentation (workflow, architecture, autonomous runs, knowledge bases, voice, diagrams, the MATS cluster).
- `templates/`: what runs fill in: the LaTeX paper (`paper.tex`, `preamble.tex`, `Makefile`), `next-steps.md`, `preflight.md`, the wiki schema `kb-schema.md`, and `codex-adapter.md`, the Codex translation of the workflow.
- `config/`: the deployment defaults and the compute-profile presets, described in `config/CLAUDE.md`.
- `data/model-organisms/`: a curated database of misaligned model organisms that a run can test a method against.
- `scripts/`: the autonomous runner, its helpers and its tests (entry points below).
- `.claude-plugin/`, `.codex-plugin/`: the Claude Code and Codex plugin manifests.
- `.claude/`, `.codex/`: the checklist review gate's settings and reviewer, managed by claude-tooling.
- `output/`, `logs/`: links the runner makes to its output and log directories (gitignored).

Entry points:

- `/researcher <topic>` (Codex: `$researcher:researcher`): the interactive workflow, `commands/researcher.md`.
- `/researcher-review [run-dir]` (Codex: `$researcher:researcher-review`): explore a finished run, `commands/researcher-review.md`.
- `/researcher-continue [run-dir]` (Codex: `$researcher:researcher-continue`): queue the next round from a finished run, `commands/researcher-continue.md`.
- `scripts/researcher-cron.sh [topic]`: the autonomous runner; its functions are in `scripts/runner/`, one file per concern.
- `scripts/researcher_lib.py`: the runner's decisions, as the subcommands its docstring lists.
- `scripts/preflight_checks.py`: an experiment's pre-flight checks.
- `scripts/config.sh KEY...`: prints configured values; the runner and the helpers source it.
- `scripts/kb-init.sh [path]`: bootstraps the global knowledge base.
- `scripts/create-followup-issue.sh`: files a follow-up research issue.
- `scripts/send-results-email.sh <run-dir>`: sends a run's results email through agent-mail.
- `scripts/check-voice-blocks.sh`: checks the Voice block copies and the parsed tokens of `docs/STANCE.md`.
- `scripts/test-researcher-backends.sh`, `scripts/test-researcher-lifecycle.sh`: the runner's integration tests, against the mock CLIs in `scripts/tests/mocks.sh`.
- `scripts/tests/`: unit tests for the Python helpers and the plugin manifests.

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
- In a linked git worktree, Codex runs the main checkout's `.codex/hooks.json`, not the
  worktree's: if the main checkout has none there is no gate, and if it has an older one the
  gate is the older one. Check that file, and trust it in `/hooks`.
- When the gate blocks a command, spawn the reviewer it asks for: `spawn_agent` with
  `agent_type="checklist-reviewer"`, `fork_turns="none"` and no model override, with the
  gate's prompt as the message. The reviewer must not see the conversation that wrote the
  diff, and a hook refuses any other spawn of it. On a retry, send the new prompt to the same
  reviewer with `followup_task`, or spawn a fresh one if it is gone.
- To review before a gate asks, run `claude-tooling review-prompt` from the clone's tooling
  environment,
  `"$(git rev-parse --path-format=absolute --git-common-dir)/claude-tooling/venv/bin/claude-tooling" review-prompt`
  (or use `$checklist-review`), and pass its output to a fresh reviewer the same way.
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

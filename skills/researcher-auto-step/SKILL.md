---
name: researcher-auto-step
description: Execute one numbered step of an existing autonomous research run. Use when asked to continue, retry, or run a specific workflow step in a research run directory.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-auto-step.md` and `../../docs/WORKFLOW.md`
completely and follow them as the canonical workflow.

- Treat the requested step number and run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter and translate `Task(...)` blocks into Codex
  leaf subagents. The workflow explicitly authorizes these subagents.
- Preserve requested parallelism, wait for all workers, and never let a leaf
  worker spawn agents or interact with the user.
- Prefer `gpt-5.6-terra` with medium reasoning for search-planner and search
  workers, and `gpt-5.6-sol` with high or xhigh reasoning for other workers,
  when available. Otherwise inherit the parent.
- Execute exactly one step, update `state.md` atomically, and stop.

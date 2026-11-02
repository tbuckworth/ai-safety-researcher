---
name: researcher-auto-step
description: Execute one numbered step of an existing autonomous research run. Use when asked to continue, retry, or run a specific workflow step in a research run directory.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-auto-step.md` and `../../docs/WORKFLOW.md`
completely and follow them as the canonical workflow, translated to Codex by
`../../templates/codex-adapter.md`, which you also follow.

- Treat the requested step number and run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter.
- Execute exactly one step, update `state.md` atomically, and stop.

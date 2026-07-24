---
name: researcher-review
description: Interactively inspect and review the results of an autonomous research run. Use when asked to understand findings, inspect artifacts, challenge conclusions, or explore a run directory.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-review.md` completely and follow it as the
canonical workflow.

- Treat an optional run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter and ask questions conversationally.
- When invoking project helper scripts, set `RESEARCHER_BACKEND=codex` so
  follow-up issues receive the correct `source:codex` label.

---
name: researcher-auto-next-steps
description: Write next-steps.md for an autonomous research run that ended without one. Use when asked to write the missing next steps of a run that stopped early.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-auto-next-steps.md` completely and follow it as
the canonical workflow.

- Treat the run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter.

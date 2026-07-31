---
name: researcher-auto-email
description: Compose and send an email summarizing an autonomous research run. Use when asked to email research findings or send a completed run report.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-auto-email.md` completely and follow it as the
canonical workflow.

- Treat the run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter.
- Identify the runtime agent as OpenAI Codex rather than Claude.
- Preserve approval requirements for sending email and never infer a
  recipient. Use the shared report-email helper through
  `RESEARCHER_SEND_EMAIL_SCRIPT` or its documented canonical path.

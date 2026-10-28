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
- Never infer a recipient. In autonomous mode obey the handoff (Codex is
  handed compose-only mode; the wrapper sends). Used interactively, write
  `email-draft.html` and `email-subject.txt` and say they are ready: the helper
  `scripts/send-results-email.sh <run-dir>` sends from a Claude session, since
  agent-mail routes replies by session and Codex has no session id to give it.

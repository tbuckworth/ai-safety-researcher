---
name: researcher-continue
description: Continue a previous autonomous research run by choosing its next step and queueing a follow-up. Use when asked to continue, extend, follow up on, or act on the results of a research run.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher-continue.md` completely and follow it as the
canonical workflow.

- Treat an optional run directory as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only frontmatter and translate `AskUserQuestion` into normal
  Codex conversation turns — but keep the confirmations. Creating a GitHub issue
  and launching a run both need an explicit yes.
- When invoking project helper scripts, set `RESEARCHER_BACKEND=codex` so the
  follow-up issue receives the correct `source:codex` label.
- When offering to start the follow-up immediately, set
  `RESEARCHER_BACKEND=codex` on the `researcher-cron.sh` invocation too, so the
  run continues on the same backend the user is talking to.

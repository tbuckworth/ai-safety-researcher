---
name: researcher
description: Run the AI Safety R&D workflow end-to-end for a research topic or question. Use for a full interactive research process from clarification and literature search through experiments, audit, and paper compilation.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher.md` and `../../docs/WORKFLOW.md` completely and
follow them as the canonical workflow.

- Treat the user's topic as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only command and agent frontmatter.
- Translate `AskUserQuestion` into normal Codex conversation turns.
- Translate each `Task(...)` block into a Codex leaf subagent with the complete
  block prompt. The workflow explicitly authorizes these subagents. Leaf
  agents must not spawn agents or interact with the user.
- Run Task blocks marked parallel concurrently and wait for all of them.
- Prefer `gpt-5.6-terra` with medium reasoning for search-planner and search
  workers, and `gpt-5.6-sol` with high or xhigh reasoning for the other
  workers, when those models are available. Otherwise inherit the parent.
- When invoking project helper scripts, set `RESEARCHER_BACKEND=codex` so
  generated source labels and attribution are correct.

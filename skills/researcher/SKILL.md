---
name: researcher
description: Run the AI Safety R&D workflow end-to-end for a research topic or question. Use for a full interactive research process from clarification and literature search through experiments, audit, and paper compilation.
---

Resolve the plugin root as the directory two levels above this `SKILL.md`.
Read `../../commands/researcher.md` and `../../docs/WORKFLOW.md` completely and
follow them as the canonical workflow, translated to Codex by
`../../templates/codex-adapter.md`, which you also follow.

- Treat the user's topic as `{{argument}}`.
- Treat every `${CLAUDE_PLUGIN_ROOT}` reference as the resolved plugin root.
- Ignore Claude-only command and agent frontmatter.
- Translate `AskUserQuestion` into normal Codex conversation turns.
- When invoking project helper scripts, set `RESEARCHER_BACKEND=codex` so
  generated source labels and attribution are correct.

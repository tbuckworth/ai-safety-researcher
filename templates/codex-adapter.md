# Codex Runtime Adapter

This workflow was authored with Claude Code vocabulary. Translate it to Codex
semantics rather than treating the pseudocode as literal shell or API syntax.

- A `Task(...)` block means: spawn a Codex leaf subagent, give it the complete
  prompt in the block, wait for it, and use its returned result. The workflow
  authorizes these subagents.
- Keep leaf agents from spawning further agents or interacting with the user.
- Run explicitly parallel Task blocks concurrently and wait for all results.
- Run the search-planner and search workers on the fast worker model and
  reasoning effort, and the novelty, criteria, decomposition, challenge,
  experiment, audit, report and knowledge workers on the deep worker model and
  reasoning effort, when that override is available; otherwise workers inherit
  the parent's. An autonomous run lists its worker models after this adapter. In
  an interactive session they are the configured ones: `RESEARCHER_CODEX_FAST_MODEL`
  and `RESEARCHER_CODEX_FAST_REASONING` (fast), `RESEARCHER_CODEX_MODEL` and
  `RESEARCHER_CODEX_REASONING` (deep), which `scripts/config.sh` in the plugin
  root prints.
- Translate Read/Write/Edit/Glob/Grep/Bash/WebSearch/WebFetch to the available
  Codex filesystem, shell, and web tools.

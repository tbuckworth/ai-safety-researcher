---
description: Compose and send autonomous research results email
argument-hint: <run-directory>
allowed-tools: [Read, Glob, Bash, mcp__gmail__send_email, mcp__claude_ai_Gmail__gmail_get_profile]
model: claude-opus-4-6
---

# Autonomous Research Email Composer

You compose and send a results email for a completed autonomous research run.

## Run Directory

The run directory is: **{{argument}}**

## Instructions

1. **Get recipient email**: Use `mcp__claude_ai_Gmail__gmail_get_profile` to get the authenticated user's email address. Send ONLY to this address — never to anyone else.

2. **Read artifacts** from the run directory:
   - `state.md` — run status, topic, novelty verdict, experiment results summary
   - `novelty-assessment.md` — novelty verdict
   - `decomposition.md` — experiment plan and lambda table
   - `challenge/pre-mortem.md` — top risks
   - `experiments/*/results.md` — individual experiment results
   - `paper/sections/abstract.tex` — paper abstract (if exists)
   - `rethink-rationale.md` — why the approach doesn't work (if exists)
   - `.repo_url` — GitHub repo URL (if exists)

3. **Compose the email** with this structure:

   **Subject**: `[Auto-Research] <topic> — <NOVEL|PARTIALLY_NOVEL|ALREADY_DONE> — <N pass, M fail>`

   If the run was a RETHINK_APPROACH, use: `[Auto-Research] <topic> — Negative Result`

   **Body** (plain text with markdown-style formatting):

   ```
   ## TL;DR
   - Topic: <topic from state.md>
   - Novelty: <verdict>
   - Experiments: <N pass, M fail> (or "skipped — negative result from theory")
   - Key finding: <1 sentence — either the paper abstract or the rethink rationale>
   - Repo: <GitHub URL from .repo_url, or "N/A">

   ## Experiment Setup
   <From decomposition.md — briefly describe what was tested, in what order,
   with what criteria. Include the lambda table if present.>

   ## Results
   <For each experiment, one paragraph: what was tested, result (PASS/FAIL),
   key metric, and what it means.>

   <If this is a negative result / RETHINK, explain the theoretical argument
   for why the approach doesn't work, and any disproof experiment results.>

   ## Key Risks Identified
   <Top 3 failure scenarios from pre-mortem, briefly>

   ## Links
   - GitHub repo: <URL>
   - GitHub issue: <URL if issue_number in state.md>
   - Run directory: <run-dir path>

   ---
   <If paper/paper.pdf does NOT exist, append the full paper content below
   by reading all sections/*.tex files and converting to readable text.
   Strip LaTeX commands for readability.>
   ```

4. **Check for PDF**: If `paper/paper.pdf` exists, note in the email that the PDF is in the GitHub repo (Gmail MCP may not support file attachments — include the repo link prominently instead).

5. **Send the email** using `mcp__gmail__send_email` to the authenticated user's email address.

6. If email sending fails, write the composed email body to `<run-dir>/email-draft.md` as a fallback so the user can find it.

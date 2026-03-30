---
description: Compose and send autonomous research results email
argument-hint: <run-directory>
allowed-tools: [Read, Glob, Bash, mcp__gmail__send_email, mcp__claude_ai_Gmail__gmail_get_profile]
model: claude-opus-4-6
---

# Autonomous Research Email Composer

You compose and send a well-formatted HTML results email for a completed autonomous research run.

## Audience

**Write for a reader who has never heard of this project.** Assume they have a general ML/AI safety background but no familiarity with the specific research question, methods, or terminology. Every acronym must be expanded on first use. Every metric must be defined before it appears in a table. The email should be fully self-contained — a reader should understand the research question, approach, and findings without opening any links.

## Run Directory

The run directory is: **{{argument}}**

## Instructions

1. **Get recipient email**: Use `mcp__claude_ai_Gmail__gmail_get_profile` to get the authenticated user's email address. Send ONLY to this address — never to anyone else.

2. **Read artifacts** from the run directory:
   - `briefing.md` — concise run summary (primary source — has topic, motivation, results, surprises)
   - `state.md` — run status, topic, clarifications (especially the Q&A pairs which explain scope and motivation)
   - `novelty-assessment.md` — novelty verdict and closest existing work
   - `experiments/*/results.md` — individual experiment results
   - `paper/sections/abstract.tex` — paper abstract (if exists)
   - `rethink-rationale.md` — why the approach doesn't work (if exists)
   - `.repo_url` — GitHub repo URL (if exists)

3. **Compose the email as HTML** using `mimeType: "multipart/alternative"` with both `body` (plain text fallback) and `htmlBody` (rich HTML).

   **Subject**: `[Auto-Research] <short plain-English topic> — <verdict> — <N pass, M fail>`
   If RETHINK_APPROACH: `[Auto-Research] <short plain-English topic> — Negative Result`

   **HTML body** — use this structure with inline styles (Gmail strips `<style>` blocks, so ALL styles must be inline):

   ```html
   <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 700px; margin: 0 auto; color: #1a1a1a; line-height: 1.6;">

     <!-- Header -->
     <div style="background: #f0f4f8; border-left: 4px solid #2563eb; padding: 16px 20px; margin-bottom: 24px;">
       <h1 style="margin: 0 0 8px 0; font-size: 20px; color: #1e293b;">
         <topic in plain English>
       </h1>
       <div style="font-size: 14px; color: #64748b;">
         Autonomous AI Safety Research Report · <date>
         <!-- If issue_number exists in state.md and is not "none", add the link -->
         · <a href="https://github.com/tbuckworth/tasks/issues/N" style="color: #64748b;">Original idea</a>
       </div>
     </div>

     <!-- Research Question — THE MOST IMPORTANT SECTION -->
     <div style="margin-bottom: 24px;">
       <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">What We Investigated</h2>
       <p style="font-size: 14px; margin: 12px 0;">
         <!-- 2-3 sentences: What question did we investigate? Write in plain English.
              Source from: state.md clarifications, briefing.md "Topic & Motivation" section.
              Example: "We tested whether the training pipeline used by Schoen et al. (2025)
              to create scheming AI models — fine-tuning on goal-conditioned examples followed
              by reinforcement learning — could work on smaller, open-source models running
              on consumer hardware." -->
       </p>
       <p style="font-size: 14px; margin: 12px 0;">
         <!-- 1-2 sentences: Why does this matter for AI safety?
              Example: "This matters because AI safety researchers need reliable ways to create
              'model organisms' — models with known misaligned goals — to test whether safety
              interventions can detect and prevent scheming behavior." -->
       </p>
     </div>

     <!-- Bottom Line -->
     <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;">
       <h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">Bottom Line</h2>
       <p style="font-size: 14px; margin: 0 0 12px 0;">
         <!-- 2-3 sentences answering the research question in plain language.
              Do NOT use undefined acronyms. Do NOT cite raw numbers without explaining
              what they mean. Include the overall verdict: positive / negative / mixed.
              Example: "Mixed results. The pipeline partially works at 7B scale: Expert
              Iteration (a filtered fine-tuning method) successfully induced goal-pursuing
              behavior, but standard reinforcement learning (GRPO) failed entirely due to
              insufficient training signal." -->
       </p>
       <table style="border-collapse: collapse; width: 100%; font-size: 14px;">
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Novelty</td><td style="padding: 4px 0;"><!-- verdict WITH context: what exists, what's new --></td></tr>
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Experiments</td><td style="padding: 4px 0;">N pass, M fail</td></tr>
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Repo</td><td style="padding: 4px 0;"><a href="URL" style="color: #2563eb;">GitHub link</a> (includes paper PDF)</td></tr>
       </table>
     </div>

     <!-- Approach — brief, defines terms -->
     <div style="margin-bottom: 24px;">
       <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Approach</h2>
       <p style="font-size: 14px; margin: 12px 0;">
         <!-- 1 short paragraph: What models were tested? What was the experimental setup?
              What methods were compared? Expand ALL acronyms on first use.
              Example: "We tested three open-source models (Qwen2.5-7B, DeepSeek-R1-7B,
              Llama-3.2-3B) on a single NVIDIA RTX 3090 GPU. We compared four training
              methods: prompt-only baselines, Supervised Fine-Tuning (SFT), Expert Iteration
              (filtering training data to keep only high-quality examples), and Group Relative
              Policy Optimization (GRPO, a reinforcement learning method)." -->
       </p>
       <!-- If key metrics need definition, define them here BEFORE the results table -->
       <p style="font-size: 13px; color: #475569; margin: 12px 0;">
         <!-- Optional: 1-2 sentences defining the key metrics used in results.
              Example: "We measured 'compliance gap' — the difference in goal-pursuing behavior
              between monitored and unmonitored conditions — as the primary indicator of
              covert goal pursuit." -->
       </p>
     </div>

     <!-- Results Table -->
     <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Results</h2>
     <table style="border-collapse: collapse; width: 100%; font-size: 14px; margin-bottom: 24px;">
       <thead>
         <tr style="background: #f8fafc;">
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">#</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">What We Tested</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">Result</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">What This Means</th>
         </tr>
       </thead>
       <tbody>
         <!-- For each experiment — describe in plain language, not internal component names.
              The "What This Means" column translates PASS/FAIL into implications.
              Example row:
              #1 | Can 7B models reason about hidden goals? | PASS | Yes — chain-of-thought
              reasoning about covert goals works at 7B scale, scoring 5.4-6.0 out of 10. -->
         <tr>
           <td style="padding: 8px 12px; border-bottom: 1px solid #f1f5f9;">1</td>
           <td style="padding: 8px 12px; border-bottom: 1px solid #f1f5f9;">...</td>
           <td style="padding: 8px 12px; border-bottom: 1px solid #f1f5f9;">
             <!-- Use green for PASS, red for FAIL -->
             <span style="background: #dcfce7; color: #166534; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600;">PASS</span>
             <!-- or -->
             <span style="background: #fef2f2; color: #991b1b; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600;">FAIL</span>
           </td>
           <td style="padding: 8px 12px; border-bottom: 1px solid #f1f5f9;">...</td>
         </tr>
       </tbody>
     </table>

     <!-- If there's a method comparison table, include it here with column definitions -->

     <!-- Surprising Findings — moved up because this is the most interesting content -->
     <div style="background: #fffbeb; border: 1px solid #fde68a; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;">
       <h2 style="margin: 0 0 12px 0; font-size: 16px; color: #92400e;">Surprising Findings</h2>
       <ol style="font-size: 14px; padding-left: 20px; margin: 0;">
         <!-- Each surprise: 2-3 sentences. State the surprise, explain why it's unexpected,
              and what it implies. Do NOT use telegraphic bullets — each item should be
              a self-contained mini-paragraph.
              Example: "Suppressing chain-of-thought reasoning made models MORE deceptive,
              not less. When we removed the model's ability to 'think out loud,' covert
              behavior jumped from 40% to 70%. This suggests chain-of-thought serves as a
              self-moderation mechanism — models that can reason about their actions choose
              to behave more honestly." -->
         <li style="margin-bottom: 12px;">...</li>
       </ol>
     </div>

     <!-- Limitations & Risks — brief -->
     <div style="margin-bottom: 24px;">
       <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Limitations</h2>
       <ol style="font-size: 14px; padding-left: 20px;">
         <!-- Top 2-3 risks/limitations. Each gets 1-2 sentences with context.
              Do NOT use internal labels (like "Unfalsifiable Middle") without explaining them. -->
         <li style="margin-bottom: 8px;">...</li>
       </ol>
     </div>

     <!-- Links -->
     <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;">
       <h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">Links</h2>
       <ul style="list-style: none; padding: 0; margin: 0; font-size: 14px;">
         <li style="margin-bottom: 4px;"><a href="REPO_URL" style="color: #2563eb;">GitHub repo</a> (includes paper PDF and all experiment code)</li>
       </ul>
     </div>

     <!-- Footer -->
     <div style="font-size: 12px; color: #94a3b8; border-top: 1px solid #e2e8f0; padding-top: 12px;">
       Generated by the autonomous AI safety researcher agent · Claude Opus 4.6
     </div>
   </div>
   ```

   **Formatting rules:**
   - ALL styles must be inline (Gmail strips `<style>` and `<link>` tags)
   - Use the template above as a guide, but fill in real data from the artifacts
   - PASS badges: green (`#dcfce7` bg, `#166534` text). FAIL badges: red (`#fef2f2` bg, `#991b1b` text)
   - **Expand ALL acronyms on first use** — no exceptions (SFT, RL, CoT, GRPO, AUC, etc.)
   - **Define every metric before using it in a table** — the reader must know what "good" vs "bad" looks like
   - Keep it scannable — the "Bottom Line" box should answer the research question in 10 seconds
   - For negative results / RETHINK, the "What We Investigated" section should still explain the idea, and add a prominent "Why It Failed" section after the results
   - **Do NOT include**: lambda tables, P_success values, P_publishable estimates, run ID slugs, VRAM statistics, or other internal workflow metadata. These are internal planning artifacts, not reader-facing content.
   - **GitHub repo names**: Keep the repo slug under 40 characters to avoid URL truncation. If the `.repo_url` file contains a truncated URL, read the actual URL from the file and use it as-is.

4. **Plain text fallback**: Also provide a `body` field with a plain-text version (markdown-style) that mirrors the same structure: Research Question, Bottom Line, Approach, Results, Surprises, Limitations, Links. Same rules about expanding acronyms and defining metrics apply.

5. **Attach the PDF** if `paper/paper.pdf` exists — use the `attachments` parameter with the absolute file path.

6. **Send the email** using `mcp__gmail__send_email` with:
   - `to`: authenticated user's email
   - `subject`: as above
   - `body`: plain text fallback
   - `htmlBody`: the HTML version
   - `mimeType`: `"multipart/alternative"`
   - `attachments`: `["<run-dir>/paper/paper.pdf"]` if the PDF exists

7. If email sending fails, write the composed HTML to `<run-dir>/email-draft.html` and the plain text to `<run-dir>/email-draft.md` as fallback.

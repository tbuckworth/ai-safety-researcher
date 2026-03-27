---
description: Compose and send autonomous research results email
argument-hint: <run-directory>
allowed-tools: [Read, Glob, Bash, mcp__gmail__send_email, mcp__claude_ai_Gmail__gmail_get_profile]
model: claude-opus-4-6
---

# Autonomous Research Email Composer

You compose and send a well-formatted HTML results email for a completed autonomous research run.

## Run Directory

The run directory is: **{{argument}}**

## Instructions

1. **Get recipient email**: Use `mcp__claude_ai_Gmail__gmail_get_profile` to get the authenticated user's email address. Send ONLY to this address — never to anyone else.

2. **Read artifacts** from the run directory:
   - `briefing.md` — concise run summary (if exists, use as primary source)
   - `state.md` — run status, topic, novelty verdict, experiment results summary
   - `novelty-assessment.md` — novelty verdict
   - `decomposition.md` — experiment plan and lambda table
   - `challenge/pre-mortem.md` — top risks
   - `experiments/*/results.md` — individual experiment results
   - `paper/sections/abstract.tex` — paper abstract (if exists)
   - `rethink-rationale.md` — why the approach doesn't work (if exists)
   - `.repo_url` — GitHub repo URL (if exists)

3. **Compose the email as HTML** using `mimeType: "multipart/alternative"` with both `body` (plain text fallback) and `htmlBody` (rich HTML).

   **Subject**: `[Auto-Research] <topic> — <NOVEL|PARTIALLY_NOVEL|ALREADY_DONE> — <N pass, M fail>`
   If RETHINK_APPROACH: `[Auto-Research] <topic> — Negative Result`

   **HTML body** — use this structure with inline styles (Gmail strips `<style>` blocks, so ALL styles must be inline):

   ```html
   <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 700px; margin: 0 auto; color: #1a1a1a; line-height: 1.5;">

     <!-- Header -->
     <div style="background: #f0f4f8; border-left: 4px solid #2563eb; padding: 16px 20px; margin-bottom: 24px;">
       <h1 style="margin: 0 0 8px 0; font-size: 20px; color: #1e293b;">
         <topic>
       </h1>
       <div style="font-size: 14px; color: #64748b;">
         Autonomous Research Run · <run-id> · <status>
       </div>
     </div>

     <!-- TL;DR -->
     <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;">
       <h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">TL;DR</h2>
       <table style="border-collapse: collapse; width: 100%; font-size: 14px;">
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Novelty</td><td style="padding: 4px 0;"><verdict></td></tr>
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Experiments</td><td style="padding: 4px 0;">N pass, M fail</td></tr>
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Key Finding</td><td style="padding: 4px 0;"><1 sentence></td></tr>
         <tr><td style="padding: 4px 12px 4px 0; color: #64748b; white-space: nowrap; vertical-align: top;">Repo</td><td style="padding: 4px 0;"><a href="URL" style="color: #2563eb;">GitHub link</a></td></tr>
       </table>
     </div>

     <!-- Results Table -->
     <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Experiment Results</h2>
     <table style="border-collapse: collapse; width: 100%; font-size: 14px; margin-bottom: 24px;">
       <thead>
         <tr style="background: #f8fafc;">
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">#</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">Component</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">Result</th>
           <th style="text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0;">Key Finding</th>
         </tr>
       </thead>
       <tbody>
         <!-- For each experiment: -->
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

     <!-- Experiment Setup -->
     <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Experiment Setup</h2>
     <p style="font-size: 14px; margin-bottom: 24px;">
       <From decomposition — what was tested, in what order, with what criteria.>
     </p>

     <!-- Lambda table — use <pre> with monospace for alignment -->
     <pre style="font-family: 'Courier New', Courier, monospace; font-size: 12px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; padding: 12px 16px; overflow-x: auto; margin-bottom: 24px;">
     <lambda table or decomposition summary>
     </pre>

     <!-- Key Risks -->
     <h2 style="font-size: 16px; color: #1e293b; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px;">Key Risks Identified</h2>
     <ol style="font-size: 14px; padding-left: 20px; margin-bottom: 24px;">
       <li style="margin-bottom: 8px;"><risk 1 from pre-mortem></li>
       <li style="margin-bottom: 8px;"><risk 2></li>
       <li style="margin-bottom: 8px;"><risk 3></li>
     </ol>

     <!-- Links -->
     <div style="background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px;">
       <h2 style="margin: 0 0 12px 0; font-size: 16px; color: #1e293b;">Links</h2>
       <ul style="list-style: none; padding: 0; margin: 0; font-size: 14px;">
         <li style="margin-bottom: 4px;"><a href="REPO_URL" style="color: #2563eb;">GitHub repo</a> (includes paper PDF)</li>
         <li style="margin-bottom: 4px;"><a href="ISSUE_URL" style="color: #2563eb;">GitHub issue</a></li>
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
   - PASS badges are green (`#dcfce7` bg, `#166534` text), FAIL badges are red (`#fef2f2` bg, `#991b1b` text)
   - Use `<pre>` with monospace font for lambda tables, code snippets, or any aligned text
   - Keep it scannable — the TL;DR box should give the full picture in 10 seconds
   - For negative results / RETHINK, add a prominent section explaining WHY it doesn't work

4. **Plain text fallback**: Also provide a `body` field with a plain-text version (markdown-style) for email clients that don't render HTML.

5. **Attach the PDF** if `paper/paper.pdf` exists — use the `attachments` parameter with the absolute file path.

6. **Send the email** using `mcp__gmail__send_email` with:
   - `to`: authenticated user's email
   - `subject`: as above
   - `body`: plain text fallback
   - `htmlBody`: the HTML version
   - `mimeType`: `"multipart/alternative"`
   - `attachments`: `["<run-dir>/paper/paper.pdf"]` if the PDF exists

7. If email sending fails, write the composed HTML to `<run-dir>/email-draft.html` and the plain text to `<run-dir>/email-draft.md` as fallback.

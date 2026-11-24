---
description: Compose and send autonomous research results email
argument-hint: <run-directory>
allowed-tools: [Read, Write, Glob, Grep, Bash]
model: fable
---

# Autonomous Research Email Composer

You compose and send a well-formatted HTML results email for a completed autonomous research run. It goes to
the configured recipient from the agents' mail account (agent-mail), never from the recipient's own Gmail, and is
reviewed before it leaves.

## Audience

**Write for a reader who has never heard of this project.** Assume they have a general ML/AI safety background but no familiarity with the specific research question, methods, or terminology. Every acronym must be expanded on first use. Every metric must be defined before it appears in a table. The email should be fully self-contained: a reader should understand the research question, approach, and findings without opening any links.

## Run Directory

The run directory is: **{{argument}}**

## Instructions

1. **Resolve the delivery mode**:
   - If the prompt includes an `Autonomous Email Handoff`, obey it exactly: it
     says whether you send the email yourself or only compose it (the wrapper
     then sends it).
   - Otherwise (run by hand in a Claude session) you send it yourself, as in
     step 5. The helper sends it to the configured recipient
     (`RESEARCHER_EMAIL_TO`); never send it to anyone else.
   - Run `agent-mail guide` and follow it where it does not conflict with this
     file: the pre-send review checks those rules.

2. **Read artifacts** from the run directory:
   - `briefing.md`: concise run summary (primary source; has topic, motivation, results, surprises)
   - `state.md`: run status, topic, clarifications (especially the Q&A pairs which explain scope and motivation)
   - `kb_<operation>_step<N>: "failed (<reason>)"` fields in `state.md`: each records a knowledge-base action that failed. For each one, add a line above the footer saying which action failed and why.
   - `novelty-assessment.md`: novelty verdict and closest existing work
   - `experiments/*/results.md`: individual experiment results
   - `paper/sections/abstract.tex`: paper abstract (if exists)
   - `next-steps.md`: the ranked next-round plan and the run's self-reflection (written by Step 11, or by the runner when a run ended without one). **This is the primary source for the "Proposed Next Steps" section.** If it is missing, say so in that section and take the steps from the Future Work section below; do not write the file, since the repo was published before this email.
   - `paper/sections/future-work.tex`: the paper's Future Work section (fallback source for next steps)
   - `rethink-rationale.md`: why the approach doesn't work (if exists)
   - `audit/results-audit.md`: the results auditor's overall disposition, exit reason, and any unresolved findings (if exists)
   - `run-outcome.json`: the wrapper's verified final outcome (`outcome`, `reasons`, `publish_state`, per-experiment verdicts). In autonomous mode the handoff gives the same facts. State any incomplete outcome in the first line. For `no-results`, say which question remains unanswered and include any pilot observation the audit supports, with its scope.
   - `experiments/*/preflight.md`: each experiment's pre-flight checks. An experiment whose verdict is `INCONCLUSIVE` (or whose pre-flight has a `FAIL`) could not answer its question: describe it that way, never as a negative result.
   - `.repo_url`: GitHub repo URL. **This file only exists if the repo push was confirmed successful.** If it is missing or empty, the code did NOT reach GitHub; OMIT the "Repo" row in the Bottom Line table and the GitHub entry in the Links section entirely, and do NOT invent a URL. In that case add a one-line note that results are attached/local (in the run directory) rather than linking to a repo.

3. **Write for a decision on a phone.** Use the reviewed briefing, the final audit and the first-screen and figures sections of `docs/SCIENTIFIC-REPORTING.md`. The email is a concise rendering of that evidence. Attribute critiques, recalculations and fresh runs accurately. Keep publication or delivery details distinct from scientific findings.

   - Subject: `[Auto-Research] <topic> — <what the evidence changes>`. The helper adds the workflow outcome prefix when needed. A paper, a count of passes and a stopped pilot each answer different questions.
   - Lead with the result for the original goal and its implication. State the most important comparison in natural units, how many independent units it covers, and the strongest remaining alternative. Name an unrun primary test when it limits the headline. Put the relevant figure next, followed by what the reader should see. If correcting a previous mail, redraw the same comparison.
   - Use short paragraphs and legible inline styles. Include enough method and baseline detail to interpret the result. Report secondary comparisons only when they change the decision. Explain what a broken or missing check prevented the study from establishing.
   - Under **Proposed Next Steps**, give the recommendation and its cost or a reason to stop, using `next-steps.md`. Distinguish an interrupted workflow from a scientific dead end. Mention failed knowledge-base actions, and the count of pending harness changes if reported by the hub. Keep private cross-run evidence local.
   - If the recipient must decide, write the question, options, recommended option and default as one valid agent-mail choices object in `email-choices.json`. The helper renders clickable buttons from it. For example, a decision to spend on a follow-up could offer “Approve the quoted run”, “Revise the comparison” and “Stop here”, with “Wait for a reply” as the default. State the amount, comparison and stop rule in the text. Omit this file for an informational report.
   - Below the findings, link the original idea when known and use the verified repo/branch for the paper and next steps. If publication failed, say where the work stands. Under **How to Continue This Research**, give the literal commands in the handoff to SSH if needed, change into the plugin directory, start the agent there, and invoke its continue command on this run. Use the supplied paths, omit SSH for a local run, and include the handoff's agent label in the footer.

4. **Write durable composition artifacts**:
   - Save the HTML to `<run-dir>/email-draft.html`.
   - Save the subject, as one plain-text line, to `<run-dir>/email-subject.txt`.
   - **Plots.** When the run produced figures (`figures/`, `experiments/*/`,
     `paper/figures/`), embed the one or two that show the main result: list
     each in `<run-dir>/email-images.txt` as `NAME=relative/path.png` (PNG,
     JPEG, GIF or WebP, inside the run directory) and place it in the HTML as
     `<img src="cid:NAME" alt="what it shows" style="max-width:100%">`, with
     two lines under it on what to see. Never use data: URIs or file paths in
     `src`; the helper sends nothing while a listed image is not one of these.

5. **Complete the requested delivery mode**:
   - In compose-only mode, stop after validating that both files are non-empty.
     The autonomous wrapper sends them.
   - Otherwise send it with the helper, which adds the outcome to the subject
     when the run is not `complete`, builds the plain-text part, attaches the
     listed plots and calls `agent-mail send` as this session:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/send-results-email.sh <run-dir>
   ```
   - **If it prints `agent-mail: NOT SENT` (exit 3), nothing was sent.** Fix
     what it lists in `email-draft.html` (and `email-subject.txt`), then run the
     same command once more: that send goes out whatever the review says. Never
     pass `--no-review`, and never run it a third time. Keep the mandatory
     sections (next steps, how to continue) through any revision: put the
     continuation commands below a clear break, labelled as the way to continue
     the run, not the way to see its results.
   - **If it exits 2, nothing was sent either.** Fix the input it names (most
     often a line of `email-images.txt`) and run it again.
   - Do NOT attach the PDF: the HTML email is self-contained and the GitHub repo link provides access to the full paper.

6. If sending fails for any other reason, retain the composition artifacts and
   report the failure. Never send it any other way or to anyone else.

---
description: Pick up a finished research run and queue the next round of work
argument-hint: [run-directory]
allowed-tools: [Read, Write, Glob, Grep, Bash, WebSearch, WebFetch, AskUserQuestion]
model: fable
---

# Research Continue — Queue the Next Round

You take a research run that has already happened and turn it into the next one.
This is the command the results email points at, so assume the user arrives with
nothing loaded: they read an email, they want to act on it, and they may not
remember the run at all.

`/researcher-review` explores a run and answers questions about it. This command
does one thing: **decide what to do next and queue it.** Reach for review when
the user wants to understand; reach for this when they want to proceed.

## Setup

1. **Find the run directory.**
   - If an argument was provided: `{{argument}}`
   - If blank: pick the most recently modified directory containing a `state.md`,
     checking `output/` in the current directory and
     `/media/titus/big/researcher-output/` on the desktop.
   - If the resolved directory has no `state.md`, say so and stop — do not guess
     at a neighbouring directory.

2. **Read `next-steps.md`.** This is the run's own ranked plan for what to do
   next, plus its reflection on what blocked it. It is the spine of this command.

   If it is missing (an older run, or one that died before the email step), read
   `state.md`, `briefing.md`, `experiments/*/results.md`, `rethink-rationale.md`,
   and `audit/results-audit.md`, then **write `next-steps.md` yourself** in the
   format below before continuing. Say that you did.

   ```markdown
   # Proposed Next Steps: <topic>

   **Run ID**: <run-id>
   **Outcome**: <one line>

   ## Reflection
   <what this round established; if it fell short, what blocked it and whether
    the blocker was orchestration (the workflow broke) or scientific (the idea
    or the test didn't survive), and whether it is escapable>

   ## Ranked Next Steps
   ### 1. <title>
   - **Do**: ...
   - **Tests**: ...
   - **Needs**: ...
   - **Kills the idea if**: ...

   ## Not Worth Pursuing
   <ruled-out directions, one line each>
   ```

3. **Read `state.md`** for `run_id`, `issue_number`, `compute_profile`, and
   status, and `.repo_url` for the prior repo. A follow-up pushes to the existing
   repo on a branch, so a missing `.repo_url` is worth flagging — the follow-up
   still works, it just starts a fresh repo.

## Present and Decide

Open with a tight orientation, no more than about ten lines:

- Topic, in one plain sentence.
- Outcome, in one sentence — including whether it was a real scientific result or
  a run that fell over.
- The reflection, in one or two sentences.

Then use `AskUserQuestion` to offer the ranked next steps as options, each
labelled with its title and described with what it tests and what it needs.
Always include a final option for a direction of the user's own.

If the run failed for **orchestration** reasons — a crashed step, a provider
limit, a wrapper bug — say so plainly and make *resuming the original run* the
first option, because a redesign would be answering a question that was never
actually asked. Resuming is not a follow-up issue: it is re-running
`scripts/researcher-cron.sh` against the existing run directory, and the run
picks up from its recorded step.

## Queue It

Once the user picks a direction:

1. **Draft the feedback text.** This becomes the follow-up issue body and is what
   the next run reads as its brief, so it must stand alone. Include: the specific
   experiment or change, the hypothesis it tests, how it builds on this round's
   results, the resources it needs, and what result would kill the line. Lift the
   substance from the chosen `next-steps.md` entry rather than re-deriving it.

2. **Confirm the draft** with `AskUserQuestion` before creating anything. Show
   the title and the body. Creating a GitHub issue is outward-facing — never do
   it on an inferred yes.

3. **Create the issue:**
   ```bash
   cat > /tmp/followup-feedback.txt <<'FEEDBACK'
   <feedback text>
   FEEDBACK
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-followup-issue.sh \
     --parent <issue_number> \
     --repo-url <repo_url> \
     --run-id <run_id> \
     --source "${RESEARCHER_BACKEND:-claude}" \
     --feedback-file /tmp/followup-feedback.txt
   ```
   Use a quoted heredoc, not `echo` — feedback text contains quotes, backticks,
   and `$` often enough that unquoted expansion will eventually corrupt a brief.

4. **Report** the issue URL, and tell the user how it will actually run: the next
   autonomous run picks up `list:research-ideas` issues, and a `type:follow-up`
   one clones this run's artifacts into `prior/`, fast-forwards the steps that
   don't change, and pushes to a branch on the existing repo.

5. **Offer to start it now** rather than waiting for the next scheduled run. Ask
   first — this launches a multi-hour job:
   ```bash
   RESEARCHER_BACKEND=claude \
   RESEARCHER_COMPUTE_PROFILE=<profile> \
   RESEARCHER_ISSUE=<new issue number> \
     ~/pyg/researcher/scripts/researcher-cron.sh
   ```
   Default `RESEARCHER_COMPUTE_PROFILE` to the prior run's `compute_profile`
   preset — a follow-up that silently drops from `mats` to the local GPU will
   quietly fail to run the experiment that was proposed. If the chosen next step
   needs more than the prior profile provided, say so and name the profile it
   actually needs. Long runs belong in `tmux`.

The user may queue several directions in one session — each is its own issue.

## Rules

- **Never invent a next step that `next-steps.md` and the artifacts don't
  support.** If the run genuinely exhausted the line, the honest recommendation
  is to stop, and you should say that instead of manufacturing a fourth option.
- Read-only on the run's artifacts, with one exception: writing a missing
  `next-steps.md`. Never edit experiment code, results, or the paper.
- One decision per session is a fine outcome. Do not pad.

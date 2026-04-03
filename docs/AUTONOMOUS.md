# Autonomous Research Mode

Run the full 10-step AI safety research workflow without human interaction. Designed for cron execution on the desktop.

## How It Works

The autonomous mode is a **multi-session state machine**:

1. `scripts/researcher-cron.sh` (bash) picks a research idea and creates a run directory
2. For each step 1-10, it launches a fresh Claude session via `/researcher-auto-step`
3. Each session executes one step, updates `state.md`, and exits
4. After all steps: creates a GitHub repo, sends an email, updates the GitHub issue

```
cron → researcher-cron.sh
         ├─ Pick issue from tbuckworth/tasks (label: list:research-ideas)
         ├─ Tag issue: status:claude-researching
         ├─ Loop: claude /researcher-auto-step <N> <run-dir>
         │    └─ Step N: spawn agents, make decisions, update state.md
         ├─ Create GitHub repo (gh CLI)
         ├─ Send email (claude /researcher-auto-email <run-dir>)
         └─ Update issue: status:claude-processed
```

## Prerequisites

On the machine running the cron job (desktop):

- **Claude Code CLI** — installed and authenticated
- **gh CLI** — authenticated (`gh auth login`)
- **Gmail MCP** — configured with valid OAuth token (sync from Mac: `bash ~/.claude/sync-config.sh`)
- **tectonic** — for LaTeX compilation (`sudo snap install tectonic` on Ubuntu)
- **jq** — for JSON parsing (`sudo apt install jq`)
- **Python 3** — for experiment execution
- **GPU** — NVIDIA RTX 3090 (24GB VRAM) with CUDA drivers

## Usage

### Manual run with a specific topic
```bash
./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

### Manual run picking from GitHub Issues
```bash
./scripts/researcher-cron.sh
```

### Cron setup (daily at 2am)
```bash
crontab -e
# Add:
0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1
```

## Decision Heuristics

The autonomous mode replaces 8 human interaction points:

| Step | Interactive Mode | Autonomous Mode |
|------|-----------------|-----------------|
| 1. Clarify topic | Ask 3-5 questions | Self-generate from topic + issue body |
| 2. Search plan | User approves | Auto-approve |
| 3. Novelty verdict | User decides | NOVEL/PARTIALLY_NOVEL → proceed; ALREADY_DONE → 1 retry then proceed |
| 4. Success criteria | User approves | Auto-approve |
| 6. Challenge synthesis | User picks path | PROCEED/MINOR → go; MAJOR → 1 re-decomposition; RETHINK → graceful pivot |
| 7. Experiment plan | User confirms | Auto-approve, cap at 5 experiments |
| 8. Fail-fast agreement | User agrees | Always yes |
| 9. On failure | User decides | Write up negative result |

### RETHINK_APPROACH Handling

When the steelman agent says the approach is fundamentally flawed:

1. If the theoretical argument alone is convincing → skip experiments, compile a "why this doesn't work" paper
2. If a quick disproof experiment would be more convincing → run just that one experiment, then compile the paper

Both produce valuable output: "here's why this idea doesn't work, and here's the evidence."

## Safety Constraints

- **Local GPU only** — no Modal, Lambda, or cloud compute
- **Max 5 experiments** per run
- **All loops capped at 1 iteration** — prevents infinite cycles
- **4-hour timeout** — wrapper kills the run and compiles whatever exists
- **Lockfile** — prevents concurrent runs
- **Read-only outside run dir** — agent can search `~/pyg/` but never modifies other repos
- **Budget cap** — `--max-budget-usd` flag on Claude sessions (not yet supported in all CLI versions)

## GitHub Integration

- **Issue labels**:
  - `list:research-ideas` — eligible for pickup
  - `status:claude-researching` — currently being worked on (prevents double-pickup)
  - `status:claude-processed` — completed
- **Repos**: Created as `tbuckworth/research-<slug>`, public, with PR for audit trail
- **Issue comments**: Bot adds a comment with repo link and status on completion

## Logs

- `logs/cron.log` — cron wrapper output
- `logs/step-N-*.log` — per-step Claude session output
- `logs/email-*.log` — email sending output
- `output/<run-id>/state.md` — workflow state (authoritative)

## Troubleshooting

**Run stuck (state not advancing)**:
- Check `state.md` for the current step and status
- Check the latest step log in `logs/`
- Delete the lockfile if stale: `rm /tmp/researcher-auto.lock`

**Gmail token expired**:
- Re-run OAuth: `python ~/pyg/admin/google_reauth.py`
- Sync to desktop: `bash ~/.claude/sync-config.sh`

**gh auth expired**:
- Run `gh auth login` on the desktop

**Experiment OOM on RTX 3090**:
- The 24GB VRAM limit is enforced via agent prompts, not hardware. If an experiment OOMs, the agent logs it as a FAIL and continues.

## Reviewing Results

After a run completes, use the interactive review command:

```bash
/researcher-review                    # most recent run
/researcher-review /path/to/run-dir   # specific run
```

This loads the run's `briefing.md` (auto-generated summary) and lets you ask questions about the results. It reads artifact files on demand — experiment code, challenge analysis, literature, paper sections — to answer your questions.

## Follow-Up Runs

The review command can create follow-up research issues. During a review session, say "create a follow-up" or describe what to investigate next, and the command will create a GitHub Issue tagged for follow-up.

### How Follow-Ups Work

1. **During review**: You give feedback (e.g., "the training data was too simple, re-run with harder tasks"). The review command calls `scripts/create-followup-issue.sh` to create an issue on `tbuckworth/tasks` with labels `list:research-ideas` and `type:follow-up`.

2. **Autonomous pickup**: The cron wrapper picks the follow-up issue like any other research idea. When it detects the `type:follow-up` label, it:
   - Clones the prior repo to copy key artifacts into a `prior/` subdirectory
   - Creates a `followup-context.md` with the feedback
   - Creates a fresh run directory (not inside the prior repo)

3. **Smart fast-forward**: Step 1 reads the prior context and feedback, then decides how much of the workflow to skip:
   - "Re-run experiments differently" → skips to Step 9 (copies prior literature, decomposition, challenge)
   - "Redesign the approach" → skips to Step 5 (copies prior literature)
   - "Wrong framing, needs new literature" → runs full workflow from Step 2

4. **Results**: Follow-up artifacts push to a new branch on the existing GitHub repo. Both the follow-up issue and the parent issue get completion comments with cross-links.

### Issue Labels

| Label | Purpose |
|-------|---------|
| `list:research-ideas` | Eligible for pickup (same as fresh ideas) |
| `type:follow-up` | Marks issue as a follow-up with prior context |
| `source:claude` | Created by the review command |
| `status:claude-researching` | Currently being worked on |
| `status:claude-processed` | Completed |

### Follow-Up Issue Format

The issue body is pure free-text feedback. Metadata is in a single footer line:
```
---
Parent: #42 | Repo: https://github.com/tbuckworth/research-foo | Run: 2026-04-03-foo
```

### Follow-Up Run Directory

```
output/<date>-followup-<slug>/
├── prior/                      # Copied from the prior run's GitHub repo
│   ├── state.md
│   ├── briefing.md
│   ├── literature/synthesis.md
│   ├── decomposition.md
│   ├── challenge/
│   └── experiments/exp-*/results.md
├── followup-context.md         # Feedback + metadata
├── followup-summary.md         # Written by Step 1: what changed and why
├── state.md                    # Fresh state for this run
├── topic.txt
├── experiments/
│   └── exp-f01/                # Follow-up experiments use f-prefix numbering
└── ...                         # Other artifacts as normal
```

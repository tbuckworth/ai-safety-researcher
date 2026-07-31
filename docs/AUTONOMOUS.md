# Autonomous Research Mode

Run the full 11-step AI safety research workflow without human interaction. Designed for cron execution on the desktop.

## How It Works

The autonomous mode is a **multi-session state machine**:

1. `scripts/researcher-cron.sh` (bash) picks a research idea and creates a run directory
2. For each step 1-11, it launches a fresh Claude or Codex session with the
   contents of `researcher-auto-step`
3. Each session executes one step, updates `state.md`, and exits
4. After all steps: creates a GitHub repo, sends an email, updates the GitHub issue

```
cron → researcher-cron.sh
         ├─ Pick issue from tbuckworth/tasks (label: list:research-ideas)
         ├─ Tag issue: status:<backend>-researching
         ├─ Loop: <claude|codex> researcher-auto-step <N> <run-dir>
         │    └─ Step N: spawn agents, make decisions, update state.md
         │       (Step 10 = audit-remediation loop: re-enters while status: audit_remediating)
         ├─ Create GitHub repo (gh CLI)
         ├─ Compose email with selected backend; send with shared Gmail helper
         └─ Update issue: status:<backend>-processed
```

## Prerequisites

On the machine running the cron job (desktop):

- At least one authenticated model CLI:
  - **Claude Code CLI** for `RESEARCHER_BACKEND=claude` (the default)
  - **Codex CLI** for `RESEARCHER_BACKEND=codex`
- **gh CLI** — authenticated (`gh auth login`)
- **Gmail OAuth token** — configured at
  `~/.config/google-docs-mcp/token.json` with `gmail.send`
- **Shared report-email helper** — normally at
  `~/pyg/claude-remote-setup/plugins/report-email/scripts/send_report_email.py`
- **tectonic** — for LaTeX compilation (`sudo snap install tectonic` on Ubuntu)
- **jq** — for JSON parsing (`sudo apt install jq`)
- **Python 3** — for experiment execution
- **GPU** — NVIDIA RTX 3090 (24GB VRAM) with CUDA drivers

## Usage

### Manual run with a specific topic
```bash
# Claude (default)
./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"

# Codex
RESEARCHER_BACKEND=codex \
  ./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

### Manual run picking from GitHub Issues
```bash
./scripts/researcher-cron.sh
```

### Cron setup (daily at 2am)
```bash
crontab -e
# Claude:
0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1

# Codex:
0 2 * * * RESEARCHER_BACKEND=codex /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1
```

The runner prepends `~/.local/bin` to `PATH`, because cron and non-login SSH
shells commonly omit it.

## Agent Backend and Models

`RESEARCHER_BACKEND` accepts exactly `claude` or `codex`. Claude remains the
default for backward compatibility.

| Setting | Default | Purpose |
|---------|---------|---------|
| `RESEARCHER_BACKEND` | `claude` | Parent CLI and issue-label namespace |
| `RESEARCHER_CLAUDE_MODEL` | `fable` | Claude parent model |
| `RESEARCHER_CODEX_MODEL` | `gpt-5.6-sol` | Codex parent/deep-worker model |
| `RESEARCHER_CODEX_REASONING` | `xhigh` | Codex parent reasoning effort |
| `RESEARCHER_CODEX_FAST_MODEL` | `gpt-5.6-terra` | Codex search workers |
| `RESEARCHER_CODEX_FAST_REASONING` | `medium` | Codex search-worker effort |
| `RESEARCHER_CODEX_DEEP_MODEL` | parent model | Codex non-search workers |
| `RESEARCHER_CODEX_DEEP_REASONING` | parent effort | Codex non-search-worker effort |
| `RESEARCHER_MODEL` | unset | Legacy override for the selected backend |

The Codex adapter translates Claude `Task(...)` blocks into leaf subagents. It
uses the faster model for search planning and literature collection and the
deeper model for novelty, decomposition, challenge, experiments, audit, and
reporting. If an explicit worker model is unavailable, workers inherit the
parent model.

An in-progress run records `agent_backend` and `agent_model` in `state.md`.
The wrapper refuses to resume it under a different backend unless
`RESEARCHER_ALLOW_BACKEND_SWITCH=true` is set deliberately.

### Codex execution controls

Codex runs via non-interactive `codex exec` with live web search, ephemeral
session storage, explicit model/reasoning settings, and user config ignored by
default so personal hooks and plugins do not alter cron behavior.

| Setting | Default |
|---------|---------|
| `RESEARCHER_CODEX_SANDBOX` | `danger-full-access` |
| `RESEARCHER_CODEX_APPROVAL_POLICY` | `never` |
| `RESEARCHER_CODEX_IGNORE_USER_CONFIG` | `true` |
| `RESEARCHER_CODEX_MAX_SUBAGENTS` | `4` |

`danger-full-access` matches the pre-existing Claude
`--dangerously-skip-permissions` behavior and is needed by experiments that
install dependencies, populate model caches, or use the GPU. Use it only on
the dedicated trusted desktop. For a constrained run, choose
`workspace-write`; expect dependency downloads or writes outside the run
directory to fail unless separately provisioned.

Codex CLI currently has no direct equivalent of Claude's
`--max-budget-usd`. The wrapper therefore relies on the compute profile,
experiment cap, retry cap, and wall-clock timeout. Account/project spending
limits should be configured separately when strict monetary enforcement is
required.

### Operational overrides

| Setting | Purpose |
|---------|---------|
| `RESEARCHER_OUTPUT_DIR` | Override `/media/titus/big/researcher-output` |
| `RESEARCHER_SKIP_PUBLISH=true` | Do not create repos or update issues |
| `RESEARCHER_SKIP_EMAIL=true` | Compose no email and send nothing |
| `RESEARCHER_EMAIL_TO` | Fixed self-recipient for autonomous delivery |
| `RESEARCHER_SEND_EMAIL_SCRIPT` | Override shared Gmail helper |
| `RESEARCHER_LINK_OUTPUT=false` | Do not rewrite repo output/log symlinks |
| `RESEARCHER_RETRY_DELAY_SECONDS` | Delay between provider retries |

## Decision Heuristics

The autonomous mode replaces 8 human interaction points:

| Step | Interactive Mode | Autonomous Mode |
|------|-----------------|-----------------|
| 1. Clarify topic | Ask 3-5 questions | Self-generate from topic + issue body |
| 2. Search plan | User approves | Auto-approve |
| 3. Novelty verdict | User decides | NOVEL/PARTIALLY_NOVEL → proceed; ALREADY_DONE → 1 retry then proceed |
| 4. Success criteria | User approves | Auto-approve |
| 6. Challenge synthesis | User picks path | Construct-validity gate first (strawman/known-outcome → loop to Step 1 once to redesign); then PROCEED/MINOR → go; MAJOR → 1 re-decomposition; RETHINK → graceful pivot. Fix-now limitations folded into the plan; rest → Future Work |
| 7. Experiment plan | User confirms | Auto-approve, cap at 5 experiments |
| 8. Fail-fast agreement | User agrees | Always yes |
| 9. On failure | User decides | Write up negative result |
| 10. Results audit | User steers the loop | Loop on FIXABLE-DEFECT up to 3 rounds; exit on SUPPORTED / TRUE-NULL / cap; unresolved findings → Limitations |

### RETHINK_APPROACH Handling

When the mentor-review agent says the approach is fundamentally flawed:

1. If the theoretical argument alone is convincing → skip experiments, compile a "why this doesn't work" paper
2. If a quick disproof experiment would be more convincing → run just that one experiment, then compile the paper

Both produce valuable output: "here's why this idea doesn't work, and here's the evidence."

## Compute Profile (hardware-agnostic)

Experiments are sized to a per-run **compute profile**, not a hard-coded device. The cron reads `RESEARCHER_COMPUTE_PROFILE` (default: the local RTX 3090) and writes it into `state.md` as `compute_profile:`; every step reads it to size experiments and to triage which limitations are fixable now vs future work. Override it to run elsewhere:

```bash
RESEARCHER_COMPUTE_PROFILE='Modal A100 40GB on-demand, ~$3.50/hr, up to $30 budget' ./scripts/researcher-cron.sh
RESEARCHER_COMPUTE_PROFILE='Lambda 8xH100 80GB node' ./scripts/researcher-cron.sh
RESEARCHER_COMPUTE_PROFILE='tinker fine-tuning API (managed training), no local GPU' ./scripts/researcher-cron.sh
```

Two short presets expand to full profile descriptions: `local` (the default,
local RTX 3090) and `mats` (MATS Slurm cluster, free `compute` partition, all
work submitted via `sbatch`). Setup and cluster policy:
[COMPUTE-MATS.md](COMPUTE-MATS.md).

```bash
RESEARCHER_COMPUTE_PROFILE=mats ./scripts/researcher-cron.sh   # run from the MATS dev node, in tmux
```

The default profile keeps the historical behaviour (local RTX 3090, no cloud). Nothing in the agents or steps assumes a specific device beyond what the profile states.

## Limitation Triage & Future Work

Limitations are triaged, not just disclaimed. At **Step 6** (design-time) and **Step 10** (results-time), each limitation is classified against the compute profile and remaining budget as **fix-now-free** (re-analysis of existing data), **fix-now-cheap** (a small run that fits the profile + experiment cap), or **future-work** (needs resources beyond the profile). Fix-now items are done; future-work items carry their precise resource asks into the paper's **Future Work** section, which states a resource-scoped next-round plan precise enough to seed a follow-up run. Step 11 refuses to write a limitation without a disposition.

## Safety Constraints

- **Compute profile** — experiments must fit the run's `compute_profile` (default: local RTX 3090, no cloud); do not exceed it silently
- **Max 5 experiments** per run
- **All loops capped at 1 iteration** — except the Step 10 audit-remediation
  loop, which allows up to 3 rounds (bash-owned ceiling at 4 + the configured
  wall-clock timeout as backstops)
- **8-hour timeout by default** — wrapper stops the run and compiles whatever
  exists; override with `RESEARCHER_TIMEOUT_HOURS`
- **Lockfile** — prevents concurrent runs
- **Read-only outside run dir** — agent can search `~/pyg/` but never modifies other repos
- **Provider permissions** — autonomous Claude and Codex runs are intentionally
  non-interactive; review the sandbox settings above before enabling cron
- **Cost control** — compute profile, experiment cap, retry cap, and timeout;
  Codex has no runner-level dollar-cap flag

## GitHub Integration

- **Issue labels**:
  - `list:research-ideas` — eligible for pickup
  - `status:claude-researching` — currently being worked on (prevents double-pickup)
  - `status:claude-processed` — completed
  - `status:codex-researching` — currently being worked on by Codex
  - `status:codex-processed` — completed by Codex
- **Repos**: Created as `tbuckworth/research-<slug>`, public, with PR for audit trail
- **Issue comments**: Bot adds a comment with repo link and status on completion

## Logs

- `logs/cron.log` — cron wrapper output
- `logs/step-N-attempt-N-*.log` — per-step provider output
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

**Codex works interactively but cron says it is missing**:
- Confirm `~/.local/bin/codex` exists
- Run `bash -lc 'codex --version'`
- The current wrapper prepends `~/.local/bin`; older deployed copies must be updated

**Codex step cannot install or download dependencies**:
- Check `RESEARCHER_CODEX_SANDBOX`
- `workspace-write` intentionally constrains writes; the default trusted-desktop
  mode is `danger-full-access`

**gh auth expired**:
- Run `gh auth login` on the desktop

**Experiment OOM / over-budget**:
- The compute profile is enforced via agent prompts, not hardware. If an experiment exceeds it (OOM on the local GPU, or needs more than the profile provides), the agent logs it as a FAIL-on-affordability and continues; the shortfall becomes a Future Work item with its resource ask.

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
| `source:claude` / `source:codex` | Created by the corresponding review backend |
| `status:claude-researching` | Currently being worked on |
| `status:claude-processed` | Completed |
| `status:codex-researching` | Currently being worked on by Codex |
| `status:codex-processed` | Completed by Codex |

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

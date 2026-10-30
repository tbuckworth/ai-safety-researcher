# Autonomous Research Mode

Run the full 11-step AI safety research workflow without human interaction. Designed for unattended runs on the desktop, launched by agent-board's `agent-spare` (see [Scheduled runs](#scheduled-runs-agent-spare)) or by hand.

## How It Works

The autonomous mode is a **multi-session state machine**:

1. `scripts/researcher-cron.sh` (bash) picks a research idea and creates a run directory
2. For each step 1-11, it launches a fresh Claude or Codex session with the
   contents of `researcher-auto-step`
3. Each session executes one step, updates `state.md`, and exits
4. After all steps: creates a GitHub repo, sends an email, updates the GitHub issue

```
agent-spare (or by hand) → researcher-cron.sh
         ├─ Pick issue from tbuckworth/tasks (label: list:research-ideas)
         ├─ Tag issue: status:<backend>-researching
         ├─ Loop: <claude|codex> researcher-auto-step <N> <run-dir>
         │    └─ Step N: spawn agents, make decisions, update state.md
         │       (Step 10 = audit-remediation loop: re-enters while status: audit_remediating)
         ├─ Create GitHub repo (gh CLI)
         ├─ Email: a Claude session writes it and sends it with agent-mail (reviewed)
         └─ Update issue: status:<backend>-processed
```

## Prerequisites

On the machine running the autonomous runs (desktop):

- At least one authenticated model CLI:
  - **Claude Code CLI** for `RESEARCHER_BACKEND=claude` (the default)
  - **Codex CLI** for `RESEARCHER_BACKEND=codex`
- **gh CLI** — authenticated (`gh auth login`)
- **agent-mail** (`~/.local/bin/agent-mail`, from `~/pyg/agent-mailroom`) and
  the Claude Code CLI for the results email. See "The results email" below.
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

# Target one specific idea instead of the head of the queue
RESEARCHER_ISSUE=2073 ./scripts/researcher-cron.sh
```

### Scheduled runs (agent-spare)

On the desktop, runs are launched by agent-board's `agent-spare`, not cron. Its
systemd user timer (`agent-spare.timer`) checks every 30 minutes whether a
plan's weekly allowance would otherwise go unused; if so, a planner picks the
idea and `agent-spare launch` starts `researcher-cron.sh` for that one issue in
its own systemd unit, setting the backend, models, compute profile,
`RESEARCHER_GUARD_CMD`, `RESEARCHER_JOB_WAIT_CMD` and `RESEARCHER_OWNER=agent-spare`.
The wrapper's output goes to `~/.local/state/agent-board/spare/run.log`; step
logs stay in `/media/titus/big/researcher-output/logs/`. The old crontab line is
disabled.

A crontab entry still works for a plain scheduled run, e.g.
```bash
0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1
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
| `RESEARCHER_CODEX_MODEL` | `gpt-6-astra` | Codex parent/deep-worker model |
| `RESEARCHER_CODEX_REASONING` | `xhigh` | Codex parent reasoning effort |
| `RESEARCHER_CODEX_FAST_MODEL` | `gpt-6.1-sol` | Codex search workers |
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
| `RESEARCHER_SKIP_PUBLISH=true` | Do not create repos or update issues (outcome `complete-local`) |
| `RESEARCHER_REPO_VISIBILITY` | Visibility of new run repos: `private` (default), `internal`, or `public` |
| `RESEARCHER_MIN_FREE_MB` | Publishing refuses to start below this much free space on the run volume (default 1024), or when `df` cannot measure it, and reports why |
| `RESEARCHER_MAX_FILE_MB` | Files at or above this size stay local instead of being committed (default 50; GitHub rejects >100 MB, failing the whole push) |
| `RESEARCHER_ALLOW_RERUN=true` | Let the queue pick an issue that already has a run directory here (default: skip it; `RESEARCHER_ISSUE=<n>` also re-runs one deliberately) |
| `RESEARCHER_RESUME_MAX_AGE_DAYS` | An unfinished autonomous run untouched for longer is not auto-resumed (default 14; 0 disables). Interactive runs (`mode: interactive`) are never resumed |
| `RESEARCHER_TIMEOUT_SECONDS` | Run timeout in seconds; overrides `RESEARCHER_TIMEOUT_HOURS` |
| `RESEARCHER_GITHUB_OWNER` / `RESEARCHER_TASKS_REPO` | Owner of run repos (default `tbuckworth`) / the issue queue (default `tbuckworth/tasks`) |
| `RESEARCHER_GIT_REMOTE_BASE` | Where git pushes (default `https://github.com`; tests point it at local bare repos) |
| `RESEARCHER_SKIP_EMAIL=true` | Compose no email and send nothing |
| `RESEARCHER_EMAIL_TO` | Fixed self-recipient for autonomous delivery |
| `RESEARCHER_AGENT_MAIL` | Path to `agent-mail` (default: the one on `PATH`; tests point it at a mock) |
| `RESEARCHER_EMAIL_CLAUDE_MODEL` | Claude model that writes a Codex run's results email (default `sonnet`; a Claude run uses its own model) |
| `RESEARCHER_LINK_OUTPUT=false` | Do not rewrite repo output/log symlinks |
| `RESEARCHER_SKIP_GPU_CHECK=true` | Skip the start-up GPU check, which exits 0 when a process uses over 500 MiB of GPU memory and exits 1 when `nvidia-smi` fails or reports a non-numeric value |
| `RESEARCHER_RETRY_DELAY_SECONDS` | Delay between provider retries |
| `RESEARCHER_JOB_WAIT_CMD` | Command printing outstanding external job ids for the run (`{run_id}` substituted). It exits 0 with its answer (no output: no jobs); a non-zero exit is an error, logged with its stderr, and the answer is unknown. While it prints anything or cannot answer, a non-advancing step waits instead of spending an attempt. Set automatically by the `mats` profile |
| `RESEARCHER_RUN_DIR` | Resume exactly this run directory, or exit 2 if it is finished, missing or interactive; never another unfinished run or the queue |
| `RESEARCHER_NO_RESUME=true` | Start fresh (with `RESEARCHER_ISSUE` or the queue) without resuming any unfinished run |
| `RESEARCHER_OWNER` | Mark the runs this caller creates (`owner:` in `state.md`, kept through every step). A run with an owner is resumed only by a caller with the same `RESEARCHER_OWNER` or through `RESEARCHER_RUN_DIR`, never by a plain cron run. agent-board's spare launcher sets `agent-spare` |
| `RESEARCHER_GUARD_CMD` | Command run before each step (`{run_id}` substituted). If it prints anything, the first line is the reason and the run pauses there like a provider limit (exit 3, resumable, nothing published; recorded as `last_pause_reason`); if it exits non-zero or times out, the reason is `guard failed: ` and its first stderr line (or `timed out`). It never interrupts a step; a step that ends without advancing while the guard holds (e.g. it asked for more budget) also pauses instead of retrying. While `RESEARCHER_JOB_WAIT_CMD` still reports jobs or cannot answer it waits for them, unless the line starts with `!` (a stop): that applies at once, also during a job wait, and the jobs keep running for the step that is redone on resume. The call is limited to 300 s. agent-board's spare-capacity launcher (`agent-spare guard`) uses it |
| `RESEARCHER_JOB_WAIT_CMD_TIMEOUT_SECONDS` | Each call of `RESEARCHER_JOB_WAIT_CMD` is stopped after this long, which counts as no answer (default 120) |
| `RESEARCHER_JOB_WAIT_POLL_SECONDS` | Poll interval while waiting (default 120) |
| `RESEARCHER_JOB_WAIT_MAX_SECONDS` | Cap on a step's waiting, summed over its waits (default 14400) |
| `RESEARCHER_JOB_WAIT_MAX_REFUNDS` | Cap on refunded attempts (default 10) |
| `RESEARCHER_KB_DIR` | Global knowledge base (default `~/pyg/research-wiki`, used only when it holds `KB-SCHEMA.md`). `none` disables it; a path set here without `KB-SCHEMA.md` exits 2. See [`KNOWLEDGE-BASE.md`](KNOWLEDGE-BASE.md) |
| `RESEARCHER_HOST_ALIAS` | SSH alias for the machine the run executes on, used in the email's "How to Continue" steps; `local` drops the ssh step. Defaults to `desktop` on the desktop; any other machine must set it, or the run exits 2 |

## Decision Heuristics

The autonomous mode replaces 9 human interaction points:

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

Paid compute (a Modal deploy or `modal run --detach`, a Lambda instance, a Slurm
`elastic-*` job, an HF endpoint) must be registered with `cloud-watch register`
straight after launch and stopped, then closed with `cloud-watch close`, before
the step ends; the experiment rules in `commands/researcher-auto-step.md` and
`agents/experiment.md` carry the exact command.

Two short presets expand to full profile descriptions: `local` (the default,
local RTX 3090) and `mats` (MATS Slurm cluster, free `compute` partition, all
work submitted via `sbatch`). Setup and cluster policy:
[COMPUTE-MATS.md](COMPUTE-MATS.md).

```bash
RESEARCHER_COMPUTE_PROFILE=mats ./scripts/researcher-cron.sh   # run from the desktop (or laptop), not the cluster
```

The run stays on the desktop (or laptop) and submits jobs to the cluster over
SSH (see [COMPUTE-MATS.md](COMPUTE-MATS.md)); the preset tells every agent it is
not on the cluster.

The default profile keeps the historical behaviour (local RTX 3090, no cloud). Nothing in the agents or steps assumes a specific device beyond what the profile states.

## Limitation Triage & Future Work

Limitations are triaged, not just disclaimed. At **Step 6** (design-time) and **Step 10** (results-time), each limitation is classified against the compute profile and remaining budget as **fix-now-free** (re-analysis of existing data), **fix-now-cheap** (a small run that fits the profile + experiment cap), or **future-work** (needs resources beyond the profile). Fix-now items are done; future-work items carry their precise resource asks into the paper's **Future Work** section, which states a resource-scoped next-round plan precise enough to seed a follow-up run. Step 11 refuses to write a limitation without a disposition.

## Next Steps (every run, including failed ones)

Step 11 writes `next-steps.md`: a `## Reflection` on what the round established
or what blocked it, then 2–4 **ranked** next steps, each with what to do, the
hypothesis it tests, the resources it needs, and the result that would kill the
line — plus a `## Not Worth Pursuing` list so a follow-up doesn't re-tread ruled-out
ground.

A run that never reaches Step 11 still gets one: the email composer writes it
from whatever artifacts exist, and diagnoses explicitly whether the failure was
**orchestration** (the workflow broke, the science is untouched, resume) or
**scientific** (the hypothesis or construct didn't survive, redesign). Every
results email carries the top steps and a literal, copy-pasteable
"How to Continue This Research" block.

## Knowledge Bases

Optional and non-blocking; see [`KNOWLEDGE-BASE.md`](KNOWLEDGE-BASE.md). The
global wiki (`RESEARCHER_KB_DIR`) is queried before searching (Step 2), for
novelty (Step 3), and for accumulated `lessons/` before the design is committed
(Step 6); sources are ingested after synthesis (Step 2) and the whole run —
result plus process lessons — after the paper (Step 11). Step 11 also writes the
research line's own `knowledge/` directory into the repo, which a follow-up run
clones into `prior/knowledge/` and extends.

Every knowledge-base action is skipped silently when there is no knowledge base;
a failed one is recorded in `state.md` and reported in the results email. It
never fails a step.

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
- **Repos**: Created as `tbuckworth/research-<slug>`, **private** by default (`RESEARCHER_REPO_VISIBILITY`). The run directory is committed in place on an explicitly named `main` branch and pushed as `HEAD:refs/heads/main`; publishing counts as done only when `git ls-remote` shows the remote branch at exactly the local commit. A slug already holding another run's repo, or an existing empty repo with the wrong visibility (the old bug left empty *public* repos), gets a date suffix instead. After creation the visibility is read back from GitHub; on a mismatch nothing is pushed. Oversized files and nested git repositories stay local and are listed as caveats in the outcome.
- **Final outcome**: written to `state.md` (`final_outcome`, `publish_state`) and `run-outcome.json`, whose `success` is true exactly for the outcomes that exit 0 (5 when a deliverable failed; see [Exit codes](#exit-codes)):

  | Outcome | Meaning | Exit |
  |---------|---------|------|
  | `complete` | Workflow finished, ≥1 valid PASS/FAIL verdict (or a theory-only negative result), push verified | 0 |
  | `complete-local` | As complete, but publishing was skipped on purpose | 0 |
  | `unpublished` | Finished with results, but publishing failed (reason recorded: push error, disk nearly full, ...) | 4 |
  | `no-results` | Finished, but no experiment produced a valid verdict (e.g. all `INCONCLUSIVE`) | 4 |
  | `partial` | Stopped early (timeout or failure) with some valid results | 4 |
  | `failed` | Stopped early with no valid results | 4 |
  | `paused` | Provider usage limit; resumable, nothing published | 3 |

  A timeout no longer overwrites a finished run: if the report completes after the timeout fast-track, the status stays `complete` with `timed_out: true` and the skipped audit listed as a caveat. Only an unfinished run becomes `timed_out` (a terminal status).
- **Issue comments**: on completion the issue gets a findings comment: the outcome and its caveats, repo / paper / next-steps links (or the local path when nothing was published), the per-experiment verdict table, the audit disposition, and the ranked next steps. A follow-up's parent issue gets the same comment.
- **Duplicates**: the queue skips issues claimed or processed by either backend, issues that already have a run directory here, and follow-ups whose request (follow-up key) was already filed, claimed, processed or run. The labels are re-read right before claiming; if that read fails, the runner exits 1 without running the issue.

## Logs

- `~/.local/state/agent-board/spare/run.log` — wrapper output of agent-spare runs (a hand-set crontab entry appends to `logs/cron.log` instead)
- `logs/step-N-attempt-N-*.log` — per-step provider output
- `logs/email-*.log` — email sending output
- `output/<run-id>/state.md` — workflow state (authoritative)

## Exit codes

| Exit | Meaning |
|------|---------|
| 0 | The run finished with outcome `complete` or `complete-local`, or there was nothing to do (no queued idea, the GPU is busy, another run holds the lock) |
| 1 | An error stopped the runner; the log says which (e.g. `state.md` could not be written, the picked issue could not be re-read before claiming it, `nvidia-smi` failed) |
| 2 | A setting or request is invalid (e.g. `RESEARCHER_BACKEND`, a numeric setting that is not an integer, a resume under another backend, a `RESEARCHER_RUN_DIR` that is not resumable) |
| 3 | Paused (provider limit or guard); resumable, nothing published |
| 4 | Finished without a usable result; the outcome table above says which |
| 5 | Finished with a usable result, but a deliverable failed: `run-outcome.json`, the email, the issue comment or the issue labels (the log names which; the others are still attempted). A paused or unusable run exits 3 or 4 even then |

## Troubleshooting

**Run stuck (state not advancing)**:
- Check `state.md` for the current step and status
- Check the latest step log in `logs/`
- Delete the lockfile if stale: `rm /tmp/researcher-auto.lock`

**Results email not sent**:
- The run log says why (`Writing and sending the results email ...`, then
  `Email sent ...` or an `ERROR:`); the composer's own output is in
  `logs/email-*.log`, and `email-draft.html` stays in the run directory.
- `agent-mail sent` lists what went out; `agent-mail status` checks the mailroom.
- A draft the pre-send review held and nobody revised is sent unchanged by the
  mailroom after its fallback wait; nothing is lost.

**Publishing failed**:
- The reason in `run-outcome.json` is git's own (`git commit failed: ...`);
  the full output is in `logs/gh-commit.log`.
- A file the global secret scan (gitleaks) flags is left out of the commit and
  listed as "not published: the secret scan flagged line N (rule)". If it is a
  false positive, allowlist it in `~/.gitleaks.toml` and re-publish; if it is a
  real secret, remove it from the run directory and rotate it.

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

## Continuing a Run

```bash
/researcher-continue                    # most recent run
/researcher-continue /path/to/run-dir   # specific run
```

The command the results email points at. It reads `next-steps.md`, presents the
ranked options, drafts the follow-up brief from the one you pick, confirms it,
creates the issue, and offers to launch the run immediately (defaulting to the
prior run's compute profile — a follow-up that silently drops from `mats` to the
local GPU would fail to run the experiment it proposed).

If the prior run died for orchestration reasons, it offers *resuming* instead,
since a redesign would answer a question that was never actually asked.

## Follow-Up Runs

`/researcher-continue` is the direct path. `/researcher-review` can also create follow-up research issues: during a review session, say "create a follow-up" or describe what to investigate next, and it will create a GitHub Issue tagged for follow-up.

### How Follow-Ups Work

1. **During review**: You give feedback (e.g., "the training data was too simple, re-run with harder tasks"). The review command calls `scripts/create-followup-issue.sh` to create an issue on `tbuckworth/tasks` with labels `list:research-ideas`, `type:follow-up` and the parent's `importance:` label (`importance:medium` when the parent has none), since agent-spare only starts ideas rated high or medium.

2. **Autonomous pickup**: The cron wrapper picks the follow-up issue like any other research idea. When it detects the `type:follow-up` label, it:
   - Clones the prior repo (on the output volume, never `/tmp`) to copy key artifacts into a `prior/` subdirectory
   - Creates a `followup-context.md` with the feedback
   - Creates a fresh run directory (not inside the prior repo)

3. **Smart fast-forward**: Step 1 reads the prior context and feedback, then decides how much of the workflow to skip:
   - "Re-run experiments differently" → skips to Step 9 (copies prior literature, decomposition, challenge)
   - "Redesign the approach" → skips to Step 5 (copies prior literature)
   - "Wrong framing, needs new literature" → runs full workflow from Step 2

4. **Results**: Follow-up artifacts push to a new branch on the existing GitHub repo, published in place: the branch starts from the branch being continued (the prior repo's default branch, or the `/tree/<branch>` in the issue's `Repo:` link for a follow-up of a follow-up) and the run directory is laid over it (`prior/` excluded), so nothing is copied. **A follow-up is not pushed into a prior repo whose visibility differs from `RESEARCHER_REPO_VISIBILITY`** (e.g. an older public repo while the default is private): the run ends `unpublished` with that reason, so making results public stays a deliberate choice. Both the follow-up issue and the parent issue get the findings comment.

`create-followup-issue.sh` is idempotent: it embeds a follow-up key (a hash of the request) in the issue body and reports an existing issue with the same key instead of filing a second one. `--force` files anyway.

### Issue Labels

| Label | Purpose |
|-------|---------|
| `list:research-ideas` | Eligible for pickup (same as fresh ideas) |
| `type:follow-up` | Marks issue as a follow-up with prior context |
| `source:claude` / `source:codex` | Created by the corresponding review backend |
| `importance:high` / `medium` / `low` | Copied from the parent issue (medium if it has none); agent-spare only starts high and medium |
| `status:claude-researching` | Currently being worked on |
| `status:claude-processed` | Completed |
| `status:codex-researching` | Currently being worked on by Codex |
| `status:codex-processed` | Completed by Codex |

### Follow-Up Issue Format

The title is `[Follow-up] ` and the feedback's first line. The body is the free-text feedback, then the metadata footer and the follow-up key; `scripts/researcher_lib.py` (`followup-issue`, `followup-meta`) writes and reads both, and only the footer's own `---` ends the feedback:
```
---
Parent: #42 | Repo: https://github.com/tbuckworth/research-foo | Run: 2026-04-03-foo
<!-- followup-key: <16 hex digits> -->
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
│   ├── next-steps.md           #   the prior round's ranked plan + reflection
│   ├── knowledge/              #   the line's KB — dead-ends.md stops re-treading
│   └── experiments/exp-*/results.md
├── followup-context.md         # Feedback + metadata
├── followup-summary.md         # Written by Step 1: what changed and why
├── state.md                    # Fresh state for this run
├── topic.txt
├── experiments/
│   └── exp-f01/                # Follow-up experiments use f-prefix numbering
└── ...                         # Other artifacts as normal
```

## The results email

The email goes to Titus from the agents' mail account, like every agent's mail
to him, never from his own Gmail. A Claude session writes it and sends it
itself with `scripts/send-results-email.sh <run-dir>`, which calls
`agent-mail send` (a Codex run uses `RESEARCHER_EMAIL_CLAUDE_MODEL` for this
step). So:

- **The pre-send review applies.** agent-mail has the mail read by a reviewer
  before it leaves. If it prints `agent-mail: NOT SENT` (exit 3), the session
  fixes what it lists and runs the helper once more; that send goes out
  whatever the review says.
- **Titus's reply comes back to that session.** The wrapper gives it a known
  session id (`claude --session-id`), and the mailroom resumes it when he
  replies, in the plugin directory, with the run's context.
- **Inline plots**: the composer lists them in `<run>/email-images.txt`
  (`NAME=relative/path.png` per line) and places each as
  `<img src="cid:NAME">`; the helper checks each one (an image inside the run
  directory, placed in the HTML) before attaching it.
- **Fallbacks.** A session that stops without sending has its draft sent by the
  wrapper as that session; a session that fails (a usage limit too) sends
  nothing, and the run exits 5. Only if the Claude CLI is not installed does a
  Codex run write the email with Codex, and the wrapper sends it
  `--unrouted`: not reviewed, and replies go to the orchestrator.
- The subject starts `[Auto-Research]`, with the outcome in front when the run
  is not `complete` (e.g. `[UNPUBLISHED]`). The old Gmail label "Researcher" is
  gone: the agents' account cannot label Titus's mailbox.

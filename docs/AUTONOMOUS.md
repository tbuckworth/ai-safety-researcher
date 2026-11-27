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
         ├─ Pick issue from the task queue, RESEARCHER_TASKS_REPO (label: list:research-ideas)
         ├─ Tag issue: status:<backend>-researching
         ├─ Loop: <claude|codex> researcher-auto-step <N> <run-dir>
         │    └─ Step N: spawn agents, make decisions, update state.md
         │       (Step 10 = audit-remediation loop: re-enters while status: audit_remediating)
         ├─ No next-steps.md (stopped before Step 11, or Step 11 wrote none): <claude|codex> researcher-auto-next-steps <run-dir>
         ├─ Create GitHub repo (gh CLI)
         ├─ Email: the first login that can writes it (else no model), sent with agent-mail
         └─ Update issue: status:<backend>-processed
```

## Prerequisites

On the machine running the autonomous runs (desktop):

- An authenticated **Codex CLI** for independent reviews on either backend, plus the Claude Code CLI when using the Claude backend.
- **gh CLI**: authenticated (`gh auth login`)
- The **agent mailroom** (`~/pyg/agent-mailroom`): `agent-mail` sends the
  results email, `agent-usage` gives the order of the logins that may write it,
  and `agent-status` records its outcome. See "The results email" below.
- **tectonic**: for LaTeX compilation (`sudo snap install tectonic` on Ubuntu)
- **jq**: for JSON parsing (`sudo apt install jq`)
- **Python 3**: for experiment execution
- **Compute**: the local GPU the `local` preset describes, with CUDA drivers, or,
  for the paid presets, a Modal or Lambda login and the `cloud-watch` CLI (see
  [Compute Profile](#compute-profile-hardware-agnostic))

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
logs stay in `logs/` in the output directory.

A crontab entry also works for a plain scheduled run, e.g.
```bash
0 2 * * * /path/to/researcher/scripts/researcher-cron.sh >> /path/to/researcher/logs/cron.log 2>&1
```

The runner prepends `~/.local/bin` to `PATH`, because cron and non-login SSH
shells commonly omit it.

## Configuration

Every setting in this document is an environment variable. The deployment's
defaults, the keys in the table below, are in `config/researcher.env` (its
format is in `config/CLAUDE.md`); the other settings give their defaults where
they are described. A variable set in the environment wins over its line, and
`RESEARCHER_CONFIG_FILE` names another file to read instead. A script stops on
a malformed line, or when a key it needs is set by neither: the runner and
`scripts/send-results-email.sh` and `scripts/send-run-report.sh` exit 2, and `scripts/create-followup-issue.sh`
and `scripts/kb-init.sh` exit 1, as on their other errors.
`scripts/config.sh KEY...` prints the values the scripts would use.

| Key in `config/researcher.env` | Purpose |
|---------|---------|
| `RESEARCHER_STORAGE_ROOT` | Volume holding `researcher-output/`, the run output directory unless `RESEARCHER_OUTPUT_DIR` is set |
| `RESEARCHER_GITHUB_OWNER` / `RESEARCHER_TASKS_REPO` | Owner of run repos / the issue queue |
| `RESEARCHER_EMAIL_TO` | Recipient of the results email: an address, or `titus` for agent-mail's owner (Titus) |
| `RESEARCHER_EMAIL_TIMEOUT_SECONDS` | Each writer of the results email is stopped after this long, and the next one tried (a whole number of at least 1) |
| `RESEARCHER_DEFAULT_KB_DIR` | The knowledge base used when `RESEARCHER_KB_DIR` is unset, if it holds `KB-SCHEMA.md` |
| `RESEARCHER_HOST_ALIASES` | Space-separated `hostname=alias` pairs: the SSH alias the email's reader uses for each machine (`RESEARCHER_HOST_ALIAS` overrides it) |
| `RESEARCHER_CODE_SEARCH_DIR` | Local code a step may search, read-only |
| `RESEARCHER_RUNNER_DIR` | The checkout of this repository that runs autonomous runs; `/researcher-continue` launches its `scripts/researcher-cron.sh` |
| `RESEARCHER_CLAUDE_BIN` / `RESEARCHER_CODEX_BIN` | The agent CLIs |
| `RESEARCHER_BACKEND`, the models and the Codex execution controls | See [Agent Backend and Models](#agent-backend-and-models) |
| `RESEARCHER_COMPUTE_PROFILE` | See [Compute Profile](#compute-profile-hardware-agnostic) |
| `RESEARCHER_MAX_EXPERIMENTS` | Most experiments in a run |
| `RESEARCHER_EXPERIMENT_MINUTES` | Per-experiment time target, in minutes of compute |
| `RESEARCHER_MAX_FILE_MB` | Files at or above this size stay local instead of being committed (GitHub rejects files over 100 MB, failing the whole push); experiments keep files under it |
| `RESEARCHER_MAX_AUDIT_ROUNDS` | R_MAX, the most Step 10 audit rounds; the runner forces the report one round later if a step ignores it |
| `RESEARCHER_MAX_REVIEW_ROUNDS` | The most plan or final-reader review rounds in one review cycle ([Review Ledger](WORKFLOW.md#review-ledger)) |

The runtime header of every step prompt gives the first four limits and the
code directory; the review helper applies the round cap itself. The limits are
numeric settings, checked at startup (exit 2 unless a whole number of at least 1).

## Agent Backend and Models

`RESEARCHER_BACKEND` accepts exactly `claude` or `codex`. Defaults are in
`config/researcher.env`, except where the table says otherwise.

| Setting | Purpose |
|---------|---------|
| `RESEARCHER_BACKEND` | Parent CLI and issue-label namespace |
| `RESEARCHER_CLAUDE_MODEL` | Claude parent model |
| `RESEARCHER_CLAUDE_LOGIN` | The agent mailroom's Claude login every Claude session of a Claude run runs on (default: unset, the login the runner's environment gives); see [A run on a Claude login](#a-run-on-a-claude-login) |
| `RESEARCHER_REVIEW_MODEL` | Independent Codex reviewers and the automatic methods approver on either backend |
| `RESEARCHER_REVIEW_REASONING` | Reasoning effort for those reviewers |
| `RESEARCHER_CODEX_MODEL` | Codex parent/deep-worker model |
| `RESEARCHER_CODEX_REASONING` | Codex parent reasoning effort |
| `RESEARCHER_CODEX_FAST_MODEL` | Codex search workers |
| `RESEARCHER_CODEX_FAST_REASONING` | Codex search-worker effort |
| `RESEARCHER_CODEX_DEEP_MODEL` | Codex workers for the non-search tasks listed below (default: the parent model) |
| `RESEARCHER_CODEX_DEEP_REASONING` | Reasoning effort for those workers (default: the parent's) |
| `RESEARCHER_EMAIL_CLAUDE_MODEL` | Model used by the mailroom's Claude writers for Codex runs and for Claude runs whose original login is unavailable or requires its own model. For other Claude runs, these writers use the run's model. |
| `RESEARCHER_MODEL` | Overrides the selected backend's model, `RESEARCHER_CLAUDE_MODEL` or `RESEARCHER_CODEX_MODEL` (default: unset) |

The Codex adapter (`templates/codex-adapter.md`, which the Codex skills also
follow) translates Claude `Task(...)` blocks into leaf subagents. It uses the
fast worker model for search planning and literature collection and the deep
worker model for novelty, criteria, decomposition, experiments, the results
auditor, reporting and the knowledge base. These workers inherit the parent
model if an explicit worker override is unavailable. On either backend, the
hub starts the independent plan critics, automatic methods approver, evidence
critic and presentation reviewer with `RESEARCHER_REVIEW_MODEL` and
`RESEARCHER_REVIEW_REASONING`. A failed reviewer invocation leaves the
corresponding gate incomplete.

A resumed run keeps the backend and models it started with; see
[Resuming a run](#resuming-a-run).

### A run on a Claude login

`RESEARCHER_CLAUDE_LOGIN` names one of the agent mailroom's Claude logins for a
Claude run, for example one that runs a model billed per token through a
settings file of its own:

```bash
RESEARCHER_CLAUDE_LOGIN=gemini ./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

- The runner looks the login up once, at startup, with the mailroom's
  `agent-usage login <name> --json`, which holds its config dir, settings file,
  model and options; if that fails, the runner exits 2.
- Every Claude session of the run (each step, the next-steps session, and the
  results email, which it writes first) runs with `CLAUDE_CONFIG_DIR` at the
  login's config dir (unset for the default login) and the login's options
  after the runner's own (`--settings <file>`, and `--model <model>` when it has
  one). A session drops the variables of another login the runner inherited
  (`CLAUDE_LOGIN_ENV` in `scripts/researcher_lib.py`: a config dir, a token, an
  endpoint, models), as every writer of the email does.
- A login with a model of its own runs only that model (a Claude model fails
  every request there), and it becomes the run's model. A `RESEARCHER_MODEL` or
  `RESEARCHER_CLAUDE_MODEL` that the launch's environment sets to another model
  exits 2. One that the launch does not set, taken from `config/researcher.env`
  or, on a resume, from the run's saved settings, is replaced, and the log says
  so. This is how a resume tells a setting the launch gives from one it takes
  ([Resuming a run](#resuming-a-run)).
- A Codex run runs on no Claude login. A launch that sets the login for one
  exits 2. A login the run's saved settings give is dropped when a resume
  switches the run to Codex: the leave that accepts the switch accepts the
  drop, which the log and `changes` in `run-config.json` record (and
  `state.md` then has `agent_login: none`). One from
  `config/researcher.env` is for Claude runs only. The independent Codex
  reviewers are the same on every run (`RESEARCHER_REVIEW_MODEL`).
- The login appears next to the model: `agent_login:` in `state.md`, and
  `Claude <model> (login <name>)` in the startup line, the email, the issue
  comment and the run repository's README.

### Codex execution controls

Codex runs via non-interactive `codex exec` with live web search, ephemeral
session storage, explicit model/reasoning settings, and user config ignored by
default so personal hooks and plugins do not alter cron behavior.

| Setting | Values (defaults in `config/researcher.env`) |
|---------|---------|
| `RESEARCHER_CODEX_SANDBOX` | `read-only`, `workspace-write` or `danger-full-access` |
| `RESEARCHER_CODEX_APPROVAL_POLICY` | `untrusted`, `on-request` or `never` |
| `RESEARCHER_CODEX_IGNORE_USER_CONFIG` | `true` or `false` |
| `RESEARCHER_CODEX_MAX_SUBAGENTS` | Most concurrent subagents, at least 1 |

`danger-full-access` matches how the runner starts Claude
(`--dangerously-skip-permissions`) and is needed by experiments that
install dependencies, populate model caches, or use the GPU. Use it only on
the dedicated trusted desktop. For a constrained run, choose
`workspace-write`; expect dependency downloads or writes outside the run
directory to fail unless separately provisioned.

Neither backend has a runner-level dollar cap: the runner passes Claude no
`--max-budget-usd`, and Codex has no equivalent. Spending is bounded by the
compute profile (a paid preset carries the run's budget), the experiment cap,
the retry cap and the run timeout. If you need a strict monetary limit, set a
spending limit on the provider account or project.

### Operational overrides

| Setting | Purpose |
|---------|---------|
| `RESEARCHER_OUTPUT_DIR` | Override `researcher-output/` under `RESEARCHER_STORAGE_ROOT` |
| `RESEARCHER_LOG_DIR` | Where the runner writes its logs (default `logs/` in the output directory) |
| `RESEARCHER_LOCKFILE` | The lockfile that keeps one run at a time (default `/tmp/researcher-auto.lock`). A run that finds it held by a live process logs that another run is active and exits 0; it removes a lockfile whose process is dead and goes ahead |
| `RESEARCHER_SKIP_PUBLISH=true` | Do not create repos or update issues (outcome `complete-local`) |
| `RESEARCHER_REPO_VISIBILITY` | Visibility of new run repos: `private` (default), `internal`, or `public` |
| `RESEARCHER_MIN_FREE_MB` | Publishing refuses to start below this much free space on the run volume (default 1024), or when `df` cannot measure it, and reports why |
| `RESEARCHER_ALLOW_RERUN=true` | Let the queue pick an issue that already has a run directory here (default: skip it; `RESEARCHER_ISSUE=<n>` also re-runs one deliberately) |
| `RESEARCHER_RESUME_MAX_AGE_DAYS` | An unfinished autonomous run untouched for longer is not auto-resumed (default 14; 0 disables). Interactive runs (`mode: interactive`) are never resumed |
| `RESEARCHER_TIMEOUT_HOURS` | Run timeout in hours (default 8). When it passes, a run that has finished Step 5 or a later step skips the audit and compiles the report from what exists; an earlier run ends `timed_out` |
| `RESEARCHER_TIMEOUT_SECONDS` | Run timeout in seconds; overrides `RESEARCHER_TIMEOUT_HOURS` |
| `RESEARCHER_GIT_REMOTE_BASE` | Where git pushes (default `https://github.com`; tests point it at local bare repos) |
| `RESEARCHER_SKIP_EMAIL=true` | Compose no email and send nothing |
| `RESEARCHER_AGENT_MAIL`, `RESEARCHER_AGENT_USAGE`, `RESEARCHER_AGENT_STATUS` | Paths to the mailroom's `agent-mail`, `agent-usage` and `agent-status` (default: the one on `PATH`, else `~/.local/bin`; tests point them at mocks, and `agent-usage` at a test configuration) |
| `RESEARCHER_LINK_OUTPUT=false` | Do not rewrite repo output/log symlinks |
| `RESEARCHER_SKIP_GPU_CHECK=true` | Skip the start-up GPU check, which exits 0 when a process uses over 500 MiB of GPU memory and exits 1 when `nvidia-smi` fails or reports a non-numeric value |
| `RESEARCHER_STEP_ATTEMPTS` | Attempts at a step that ends without advancing (default 3), after which the run is marked `failed` |
| `RESEARCHER_RETRY_DELAY_SECONDS` | Delay between provider retries |
| `RESEARCHER_JOB_WAIT_CMD` | A run setting (see [Resuming a run](#resuming-a-run)): a command printing outstanding external job ids for the run (`{run_id}` substituted). It exits 0 with its answer (no output: no jobs); a non-zero exit is an error, logged with its stderr, and the answer is unknown. While it prints anything or cannot answer, a non-advancing step waits instead of spending an attempt. Set automatically by the `mats` profile |
| `RESEARCHER_RUN_DIR` | Resume exactly this run directory, or exit 2 if it is finished, missing or interactive; never another unfinished run or the queue |
| `RESEARCHER_NO_RESUME=true` | Start fresh (with `RESEARCHER_ISSUE` or the queue) without resuming any unfinished run |
| `RESEARCHER_OWNER` | Mark the runs this caller creates (`owner:` in `state.md`, kept through every step). A run with an owner is resumed only by a caller with the same `RESEARCHER_OWNER` or through `RESEARCHER_RUN_DIR`, never by a plain cron run. agent-board's spare launcher sets `agent-spare` |
| `RESEARCHER_ALLOW_CONFIG_CHANGE=true` | Let a resume set a run setting to a value other than the one the run saved (the run's owner may without it); see [Resuming a run](#resuming-a-run) |
| `RESEARCHER_ALLOW_BACKEND_SWITCH=true` | The same, for `RESEARCHER_BACKEND` alone |
| `RESEARCHER_CONFIG_FILE` | Read this configuration file instead of `config/researcher.env` |
| `RESEARCHER_GUARD_CMD` | Command run before each step (`{run_id}` substituted). If it prints anything, the first line is the reason and the run pauses there like a provider limit (exit 3, resumable, nothing published; recorded as `last_pause_reason`); if it exits non-zero or times out, the reason is `guard failed: ` and its first stderr line (or `timed out`). It never interrupts a step; a step that ends without advancing while the guard holds (e.g. it asked for more budget) also pauses instead of retrying. While `RESEARCHER_JOB_WAIT_CMD` still reports jobs or cannot answer it waits for them, unless the line starts with `!` (a stop): that applies at once, also during a job wait, and the jobs keep running for the step that is redone on resume. The call is limited to 300 s. agent-board's spare-capacity launcher (`agent-spare guard`) uses it |
| `RESEARCHER_JOB_WAIT_CMD_TIMEOUT_SECONDS` | Each call of `RESEARCHER_JOB_WAIT_CMD` is stopped after this long, which counts as no answer (default 120) |
| `RESEARCHER_JOB_WAIT_POLL_SECONDS` | Poll interval while waiting (default 120) |
| `RESEARCHER_JOB_WAIT_MAX_SECONDS` | Cap on a step's waiting, summed over its waits (default 14400) |
| `RESEARCHER_JOB_WAIT_MAX_REFUNDS` | Cap on refunded attempts (default 10) |
| `RESEARCHER_KB_DIR` | Global knowledge base (default: `RESEARCHER_DEFAULT_KB_DIR`, used only when it holds `KB-SCHEMA.md`). `none` disables it; a path set here without `KB-SCHEMA.md` exits 2. See [`KNOWLEDGE-BASE.md`](KNOWLEDGE-BASE.md) |
| `RESEARCHER_HOST_ALIAS` | SSH alias for the machine the run executes on, used in the email's "How to Continue" steps; `local` drops the ssh step. Defaults to the machine's entry in `RESEARCHER_HOST_ALIASES`; a machine with none must set it, or the run exits 2 |

## Decision Heuristics

The hub clarifies scope from the topic or issue, conducts the search, checks novelty and sets decision-relevant success criteria. Before execution it writes the actual per-experiment methods. Three independent reviewers assess them and a separate automatic approver decides whether that revision can run. A disproof experiment also goes through approval. A theoretical rethink can finish with a rationale and zero experiments. The full criteria, revision rules and approval commands are in [Steps 6–8 of the workflow](WORKFLOW.md#step-6-write-and-challenge-the-methods).

Each critique and approval is saved under `reviews/` in the run directory. The plan receipt preserves the text of the reviewed methods. Approval records when it was given and which experiments already had results. Model review receipts record the decision, elapsed time and token usage when the CLI provides it. With one audit round and no revisions, the three initial reviewer calls run in parallel. The automatic approver and final reader are sequential gates. The evidence reviewer can run alongside the empirical auditor. A cache hit reuses the receipt for the same revision. Each review stage also keeps a ledger of its findings, which every later round of that stage sees ([Review Ledger](WORKFLOW.md#review-ledger)). When the final reader reaches its round cap with a blocking finding open, the runner holds delivery and says so in `last_pause_reason`.

## Compute Profile (hardware-agnostic)

Experiments are sized to a per-run **compute profile**, not a hard-coded device.
The runner resolves `RESEARCHER_COMPUTE_PROFILE` (default in
`config/researcher.env`) and writes the text into `state.md` as
`compute_profile:`; every step reads it to size experiments and to triage which
limitations are fixable now vs future work. The value is one of:

- **a preset**, the name of a file in `config/compute-profiles/` (any case):
  `local` is the local GPU, with no paid compute; `modal` and `lambda` are paid
  cloud GPUs on the account each names, with a budget for the whole run and the
  rules for spending it, which both take from `config/paid-compute.md`;
- **`mats`**, the MATS Slurm cluster, not recommended for new work
  ([COMPUTE-MATS.md](COMPUTE-MATS.md)); it also sets `RESEARCHER_JOB_WAIT_CMD`;
- **profile text** of more than one word, used as the profile itself. A single
  word that names no preset is taken for a misspelt one: the runner exits 2 and
  lists the presets.

A paid preset needs `RESEARCHER_COMPUTE_BUDGET_USD`, the budget in whole US
dollars, which the runner puts into its text; without it, or with a budget for
a profile that takes none, the runner exits 2. `scripts/config.sh
--compute-profile VALUE` prints the profile a value resolves to (not `mats`).

```bash
RESEARCHER_COMPUTE_PROFILE=lambda RESEARCHER_COMPUTE_BUDGET_USD=40 ./scripts/researcher-cron.sh
RESEARCHER_COMPUTE_PROFILE='tinker fine-tuning API (managed training), no local GPU' ./scripts/researcher-cron.sh
```

Paid compute (a Modal deploy or `modal run --detach`, a Lambda instance, a Slurm
`elastic-*` job, an HF endpoint) must be registered with `cloud-watch register`
straight after launch and stopped, then closed with `cloud-watch close`, before
the step ends; the experiment rules in `agents/experiment.md` carry the exact
command. Nothing in the agents or steps assumes a specific device beyond what
the profile states.

## Resuming a run

A run saves its settings in `run-config.json` in its directory, which is
published with it. `settings` holds the value (or null) of each run setting, the
variables `researcher_lib.py run-settings` lists (the backend, models, Claude
login and Codex settings, the email model, the compute profile and budget, the
job-wait command, the knowledge base, and the limits); `resolved` holds what
they came to (the model, the Claude login, the profile's text and preset name,
the job-wait command, the knowledge base); `launches` lists every launch with
its start, timeout, owner and the plugin's commit; `changes` lists the settings
resumes changed.

A resumed run takes each setting its launch does not set from `run-config.json`,
not from the configuration or the resuming shell. A setting the launch gives
with another value is a change, which only the run's owner (a launch whose
`RESEARCHER_OWNER` is the run's `owner:`; agent-board's agent-spare raises a
run's budget this way) or `RESEARCHER_ALLOW_CONFIG_CHANGE=true` may make, and
`RESEARCHER_ALLOW_BACKEND_SWITCH=true` for the backend alone (a switch to
Codex also drops the run's Claude login; see
[A run on a Claude login](#a-run-on-a-claude-login)). The runner logs an
accepted change and adds it to `changes`; it refuses any other one, naming the
setting, and exits 2. A run that predates `run-config.json` keeps the
backend in its `state.md` and takes its other settings from the launch that
first resumes it, which then records them.

## Limitation Triage & Future Work

Steps 6 and 10 triage each limitation by the
[Limitation Triage](WORKFLOW.md#limitation-triage) rubric in WORKFLOW.md,
against the run's compute profile; Step 11 writes the future-work rows into the
paper's Future Work section.

## Next Steps (every run, including failed ones)

Step 11 writes `next-steps.md`: a `## Reflection` on what the round established
or what blocked it, then 2–4 **ranked** next steps (each with what to do, the
hypothesis it tests, the resources it needs, and the result that would kill the
line), plus a `## Not Worth Pursuing` list so a follow-up doesn't re-tread ruled-out
ground.

A run that ends without one (it stopped before Step 11, or Step 11 did not
write it) and is not paused gets one before it is published, from one session
of its backend running `commands/researcher-auto-next-steps.md`, which diagnoses whether the failure was
**orchestration** (the workflow broke, the science is untouched, resume) or
**scientific** (the hypothesis or construct didn't survive, redesign). If that
session fails, the outcome lists `next-steps.md` as missing. Every
results email carries the top steps and a literal, copy-pasteable
"How to Continue This Research" block.

## Knowledge Bases

Optional and non-blocking; see [`KNOWLEDGE-BASE.md`](KNOWLEDGE-BASE.md). The
global wiki (`RESEARCHER_KB_DIR`) is queried before searching (Step 2), for
novelty (Step 3), and for accumulated `lessons/` before the design is committed
(Step 6); sources are ingested after synthesis (Step 2) and the whole run
(result plus process lessons) after the paper (Step 11). Step 11 also writes the
research line's own `knowledge/` directory into the repo, which a follow-up run
clones into `prior/knowledge/` and extends.

Every knowledge-base action is skipped silently when there is no knowledge base;
a failed one is recorded in `state.md` and reported in the results email. It
never fails a step.

## Safety Constraints

- **Compute profile**: experiments must fit the run's `compute_profile`; do not exceed it silently
- **Limits**: at most `RESEARCHER_MAX_EXPERIMENTS` experiments per run, each
  targeting `RESEARCHER_EXPERIMENT_MINUTES`
- **All loops capped at 1 iteration**, except the Step 10 audit-remediation
  loop, which allows up to `RESEARCHER_MAX_AUDIT_ROUNDS` rounds (a runner-owned
  ceiling one round higher and the configured wall-clock timeout as backstops)
- **Run timeout**: `RESEARCHER_TIMEOUT_HOURS` (default 8); what happens when it
  passes depends on the step reached (see `RESEARCHER_TIMEOUT_HOURS` above)
- **Lockfile**: `RESEARCHER_LOCKFILE` keeps one run at a time
- **Read-only outside run dir**: the agent can search `RESEARCHER_CODE_SEARCH_DIR` but never modifies other repos
- **Provider permissions**: autonomous Claude and Codex runs are intentionally
  non-interactive; review the sandbox settings above before enabling cron
- **Cost control**: the compute profile, the experiment cap, the retry cap and
  the timeout; neither backend has a runner-level dollar cap

## GitHub Integration

- **Issue labels**:
  - `list:research-ideas`: eligible for pickup
  - `status:claude-researching`: currently being worked on (prevents double-pickup)
  - `status:claude-processed`: completed
  - `status:codex-researching`: currently being worked on by Codex
  - `status:codex-processed`: completed by Codex
- **Repos**: Created as `<RESEARCHER_GITHUB_OWNER>/research-<slug>`, **private** by default (`RESEARCHER_REPO_VISIBILITY`). The run directory is committed in place on an explicitly named `main` branch and pushed as `HEAD:refs/heads/main`; publishing counts as done only when `git ls-remote` shows the remote branch at exactly the local commit. A slug already holding another run's repo, or an existing empty repo with the wrong visibility, gets a date suffix instead. After creation the visibility is read back from GitHub; on a mismatch nothing is pushed. Oversized files and nested git repositories stay local and are listed as caveats in the outcome.
- **Final outcome**: written to `state.md` (`final_outcome`, `publish_state`) and `run-outcome.json`, whose `success` is true exactly for the outcomes that exit 0 (5 when a deliverable failed; see [Exit codes](#exit-codes)):

  | Outcome | Meaning | Exit |
  |---------|---------|------|
  | `complete` | Workflow finished, ≥1 valid PASS/FAIL verdict (or a theory-only negative result), push verified | 0 |
  | `complete-local` | As complete, but publishing was skipped on purpose | 0 |
  | `unpublished` | Finished with results, but publishing failed (reason recorded: push error, disk nearly full, ...) | 4 |
  | `no-results` | Finished, but no experiment produced a valid verdict (e.g. all `INCONCLUSIVE`) | 4 |
  | `partial` | Stopped early (timeout or failure) with some valid results | 4 |
  | `failed` | Stopped early with no valid results | 4 |
  | `paused` | Resumable hold, including a provider limit or a pending review. See the recorded reason. | 3 |

  A timeout does not overwrite a finished run: if the report completes after the timeout fast-track, the status stays `complete` with `timed_out: true` and the skipped audit listed as a caveat. Only an unfinished run becomes `timed_out` (a terminal status).

  Each experiment in `run-outcome.json` has one of these verdicts (`VERDICTS` in `scripts/researcher_lib.py`); only a valid one counts as a result:

  | Verdict | Meaning | Valid |
  |---------|---------|-------|
  | `PASS`, `FAIL`, `MIXED` | The verdict line of its `results.md` (`PARTIAL` reads as `MIXED`) | yes |
  | `INCONCLUSIVE` | It could not answer its question: a failed pre-flight check, a verdict line of `INCONCLUSIVE` or `INVALID`, or a `FAIL` that names affordability (FAIL-on-affordability) | no |
  | `UNKNOWN` | Its `results.md` has no recognisable verdict line | no |
  | `PLANNED` | Documented before launch; the experiment has not started | No |
  | `MISSING` | Its directory exists, but it wrote no `results.md` (it started and stopped) | no |

  The caveats report the experiments that are not valid, a finished run without `paper/paper.pdf` (with the `paper_compile_error` Step 11 records in `state.md`), and a run that is not paused without `next-steps.md`.
- **Issue comments**: on completion the issue gets a findings comment: the outcome and its caveats, repo / paper / next-steps links (or the local path when nothing was published), the per-experiment verdict table, the audit disposition, and the ranked next steps. A follow-up's parent issue gets the same comment.
- **Duplicates**: the queue skips issues claimed or processed by either backend, issues that already have a run directory here, and follow-ups whose request (follow-up key) was already filed, claimed, processed or run. The labels are re-read right before claiming; if that read fails, the runner exits 1 without running the issue.

## Logs

- `~/.local/state/agent-board/spare/run.log`: wrapper output of agent-spare runs (a hand-set crontab entry appends to `logs/cron.log` instead)
- `logs/step-N-attempt-N-*.log`: per-step provider output
- `logs/next-steps-*.log`: output of the session that writes a missing `next-steps.md`
- `logs/email-*-<login>.log`: each email writer's output; `logs/email-send-*.log`: the helper's, for a draft the wrapper sends
- `output/<run-id>/state.md`: workflow state (authoritative)

## Exit codes

| Exit | Meaning |
|------|---------|
| 0 | The run finished with outcome `complete` or `complete-local`, or there was nothing to do (no queued idea, the GPU is busy, another run holds the lock) |
| 1 | An error stopped the runner; the log says which (e.g. `state.md` could not be written, the picked issue could not be re-read before claiming it, `nvidia-smi` failed) |
| 2 | A setting or request is invalid (e.g. `RESEARCHER_BACKEND`, a numeric setting that is not a whole number without leading zeros, or is 0 where it must be at least 1, a malformed `config/researcher.env` or a key missing from it, a paid compute profile without a budget, a resume that changes a saved setting without leave, a `RESEARCHER_RUN_DIR` that is not resumable, a `RESEARCHER_CLAUDE_LOGIN` that cannot be looked up, does not run the model the launch sets, or is set by the launch of a Codex run) |
| 3 | Paused (provider limit or guard); resumable, nothing published |
| 4 | Finished without a usable result; the outcome table above says which |
| 5 | Finished with a usable result, but a deliverable failed: `run-outcome.json`, the email, the issue comment or the issue labels (the log names which; the others are still attempted). A paused or unusable run exits 3 or 4 even then; `undelivered:` in `state.md` names the failed deliverables (or `none`) whatever the exit code |

## Troubleshooting

**Run stuck (state not advancing)**:
- Check `state.md` for the current step and status
- Check the latest step log in `logs/`
- A lockfile left by a dead process is removed by the next run; if the log says
  another run is active, its PID is in that line and in the file `RESEARCHER_LOCKFILE` names

**Results email not sent** (`undelivered: email` in `state.md`):
- The run log says why: one `WARN: the results email was not delivered by ...`
  line per writer that failed, then `ERROR: nothing was sent ...`; each writer's
  output is in `logs/email-*.log`. The status log has the same outcome
  (`agent-status log`).
- `agent-mail sent` lists what went out; `agent-mail status` checks the mailroom.
- For an unsent report, run `scripts/send-run-report.sh <run-dir>`. It keeps the
  original attribution and uses the remaining [results email](#the-results-email)
  writers if a login is unavailable. It refuses reports already sent or held.
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
- The runner prepends `~/.local/bin` to `PATH`; if `codex` is installed elsewhere,
  set `RESEARCHER_CODEX_BIN` to its path

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

This loads the run's `briefing.md` (auto-generated summary) and lets you ask questions about the results. It reads artifact files on demand (experiment code, challenge analysis, literature, paper sections) to answer your questions.

## Continuing a Run

```bash
/researcher-continue                    # most recent run
/researcher-continue /path/to/run-dir   # specific run
```

The command the results email points at. It reads `next-steps.md`, presents the
ranked options, drafts the follow-up brief from the one you pick, confirms it,
creates the issue, and offers to launch the run immediately, with the prior
run's backend and compute-profile preset from its `run-config.json` (a follow-up
that silently drops from a cloud profile to the local GPU would fail to run the
experiment it proposed).

If the prior run died for orchestration reasons, it offers *resuming* instead
(`RESEARCHER_RUN_DIR=<run dir>`, with the run's saved settings), since a
redesign would answer a question that was never actually asked.

## Follow-Up Runs

`/researcher-continue` is the direct path. `/researcher-review` can also create follow-up research issues: during a review session, say "create a follow-up" or describe what to investigate next, and it will create a GitHub Issue tagged for follow-up.

### How Follow-Ups Work

1. **During review**: You give feedback (e.g., "the training data was too simple, re-run with harder tasks"). The review command calls `scripts/create-followup-issue.sh` to create an issue on the task queue (`RESEARCHER_TASKS_REPO`) with labels `list:research-ideas`, `type:follow-up` and the parent's `importance:` label (`importance:medium` when the parent has none), since agent-spare only starts ideas rated high or medium.

2. **Autonomous pickup**: The cron wrapper picks the follow-up issue like any other research idea. When it detects the `type:follow-up` label, it:
   - Copies key artifacts into a `prior/` subdirectory from a clone of the prior repo (on the output volume, never `/tmp`), or, when the issue names no repo, from the prior run's directory here (`<output dir>/<Run: id>`). If neither can be read, the run does not start: the runner takes the issue's researching label off, so a later run retries it, and exits 1
   - Creates a `followup-context.md` with the feedback
   - Creates a fresh run directory (not inside the prior repo)

3. **Smart fast-forward**: Step 1 reads the prior context and feedback, then decides how much of the workflow to skip:
   - "Re-run experiments differently" → reuses prior context and starts the new methods review before execution
   - "Redesign the approach" → skips to Step 5 (copies prior literature)
   - "Wrong framing, needs new literature" → runs full workflow from Step 2

4. **Results**: Follow-up artifacts push to a new branch on the existing GitHub repo (a follow-up that names no repo gets a repo of its own), published in place: the branch starts from the branch being continued (the prior repo's default branch, or the `/tree/<branch>` in the issue's `Repo:` link for a follow-up of a follow-up) and the run directory is laid over it (`prior/` excluded), so nothing is copied. **A follow-up is not pushed into a prior repo whose visibility differs from `RESEARCHER_REPO_VISIBILITY`** (e.g. an older public repo while the default is private): the run ends `unpublished` with that reason, so making results public stays a deliberate choice. Both the follow-up issue and the parent issue get the findings comment.

`create-followup-issue.sh` is idempotent: it embeds a follow-up key (a hash of the request) in the issue body and reports an existing issue with the same key instead of filing a second one. `--force` files anyway. `--source <backend>` is required. It exits 1 without filing when the parent issue cannot be read, and exits 1 naming the new issue when the link comment on the parent fails.

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
Parent: #42 | Repo: https://github.com/<owner>/research-foo | Run: 2026-04-03-foo
<!-- followup-key: <16 hex digits> -->
```

### Follow-Up Run Directory

```
output/<date>-followup-<slug>/
├── prior/                      # Copied from the prior run's repo (or its run directory)
│   ├── state.md, briefing.md, method-spec.md
│   ├── novelty-assessment.md, success-criteria.md, decomposition.md
│   ├── references.bib, citation-registry.md
│   ├── literature/
│   ├── challenge/
│   ├── next-steps.md           #   the prior round's ranked plan + reflection
│   ├── knowledge/              #   the line's knowledge base; dead-ends.md stops re-treading
│   ├── experiments/exp-*/      #   plan.md and results.md of each
│   └── paper/sections/*.tex
├── followup-context.md         # Feedback + metadata
├── followup-summary.md         # Written by Step 1: what changed and why
├── state.md                    # Fresh state for this run
├── topic.txt
├── experiments/
│   └── exp-f01/                # Follow-up experiments use f-prefix numbering
└── ...                         # Other artifacts as normal
```

## Measurement repairs after fail-fast

An inconclusive prerequisite can receive one repair per run when the auditor
identifies a defect and the current approved experiment plan explicitly
permits the remedy. The hub checks the remaining time, experiment slots
and approved budget. Fresh measurements require a procedure already covered
by the approved plan. A genuine negative goes directly to the report.

Step 10 saves the original result and pre-flight, and stages the repair
under `audit/measurement-repair/`. A retry can recover an existing attempt.
The re-audited result replaces the experiment's standard result.
A verified PASS makes Step 9 resume the remaining approved experiments.
A verified FAIL stops the sequence and is reported alongside the original.

## The results email

The email leads with what the reviewed evidence changes for the original research question. A pilot, an inconclusive primary comparison and a decision to stop can coexist in the first paragraph. When asking the recipient for a decision, the writer adds one agent-mail choices object in `email-choices.json`. The helper appends it to the plain report and lets the Mail tab render buttons. Informational mail uses the HTML draft.

The email goes to `RESEARCHER_EMAIL_TO` from the agents' mail account, like
every agent's mail, never from the recipient's own Gmail. It is written by the
first writer that can: the run's own Claude login, when it has one
(`RESEARCHER_CLAUDE_LOGIN`, on the run's model and with the login's options),
then the agent mailroom's own login order without that login (`agent-usage`;
the mailroom's README, "The login and model order"), which on the desktop is
the personal Claude login, then the Arrow login, then Codex. The mailroom's
paid API key is never used. No writer takes the variables of another login
from the runner's environment (`CLAUDE_LOGIN_ENV` in
`scripts/researcher_lib.py`, and what the mailroom drops).

- **On a Claude login**, the session uses the model selected by the
  `RESEARCHER_EMAIL_CLAUDE_MODEL` rule above. It writes the report and sends it with
  `scripts/send-results-email.sh <run-dir>`, which calls `agent-mail send`.
  The pre-send review applies: if it prints `agent-mail: NOT SENT` (exit 3),
  the session fixes what it lists and runs the helper once more, and that send
  goes out whatever the review says. The recipient's reply comes back to that
  session: the wrapper gives it a known id (`claude --session-id`), and the
  mailroom resumes it on a reply, on whichever login holds it, in the plugin
  directory, with the run's context. A session that stops without sending has
  its draft sent by the wrapper as that session.
- **On Codex**, Codex (`RESEARCHER_CODEX_FAST_MODEL`) only writes it, and the
  wrapper sends it `--unrouted`: not reviewed, and replies go to the
  orchestrator.
- **A writer that fails** passes the email to the next: a usage limit, a
  crash, a draft the helper refuses, or a writer still running after
  `RESEARCHER_EMAIL_TIMEOUT_SECONDS`. Its draft is discarded, and the run log
  says why.
- **With no writer left**, the report is assembled from the run's saved files
  with no model (`scripts/results_report.py template`): the outcome the runner
  recorded, the experiments' verdicts and pre-flight failures, the caveats, the
  ranked next steps, the headline figures `review-figures.json` lists, the
  links and the continuation commands, in the same layout, with a box saying
  why no model wrote it. It goes `--unrouted`. If even that cannot be built, a
  plain-text notice goes instead, saying where the results are and why there
  is no report.
- **The outcome is recorded** in the status log (`agent-status note`): who
  wrote the email, the writers that failed before it, or that nothing was sent
  and how to send it later (`scripts/send-run-report.sh`). An email or notice
  that cannot be sent at all is a failed deliverable.
- **Inline plots**: the composer lists them in `<run>/email-images.txt`
  (`NAME=relative/path.png` per line) and places each as
  `<img src="cid:NAME">`; the helper checks each one (an image inside the run
  directory, placed in the HTML) and sends nothing (exit 2) until all pass, as
  it does when `run-outcome.json` exists but cannot be read.
- The subject starts `[Auto-Research]`, with the outcome in front when the run
  is not `complete` (e.g. `[UNPUBLISHED]`).

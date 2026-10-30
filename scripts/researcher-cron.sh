#!/usr/bin/env bash
# researcher-cron.sh — Autonomous research runner
#
# Picks a research idea from GitHub Issues (or takes one as argument),
# runs the 11-step research workflow via per-step Claude or Codex sessions,
# creates a GitHub repo with artifacts, and emails results.
#
# Usage:
#   researcher-cron.sh [topic]                         # Claude (default)
#   RESEARCHER_BACKEND=codex researcher-cron.sh topic # Codex
#   researcher-cron.sh                                 # Pick from GitHub Issues
#
# Launcher: agent-board's agent-spare (the agent-spare.timer systemd user timer)
# starts this script for one issue in its own systemd unit, and its output goes to
# ~/.local/state/agent-board/spare/run.log; step logs stay in
# /media/titus/big/researcher-output/logs/ (LOG_DIR below). The old
# crontab line is disabled. It can still be run by hand or from cron, e.g.
#   0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Cron and non-login SSH shells often omit user-installed CLIs.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

STORAGE_ROOT="${RESEARCHER_STORAGE_ROOT:-/media/titus/big}"
OUTPUT_DIR="${RESEARCHER_OUTPUT_DIR:-${STORAGE_ROOT}/researcher-output}"
LOG_DIR="${RESEARCHER_LOG_DIR:-${OUTPUT_DIR}/logs}"

LOCKFILE="${RESEARCHER_LOCKFILE:-/tmp/researcher-auto.lock}"
# The numeric settings read below, checked once here: a value that is not an
# integer would otherwise switch a check off without a word (a non-numeric
# `[ -gt ]` is just false). A numeric setting added below goes in this list.
for setting in RESEARCHER_TIMEOUT_HOURS RESEARCHER_TIMEOUT_SECONDS RESEARCHER_RESUME_MAX_AGE_DAYS \
    RESEARCHER_MIN_FREE_MB RESEARCHER_MAX_FILE_MB RESEARCHER_STEP_ATTEMPTS RESEARCHER_RETRY_DELAY_SECONDS \
    RESEARCHER_JOB_WAIT_CMD_TIMEOUT_SECONDS RESEARCHER_JOB_WAIT_POLL_SECONDS RESEARCHER_JOB_WAIT_MAX_SECONDS \
    RESEARCHER_JOB_WAIT_MAX_REFUNDS RESEARCHER_CODEX_MAX_SUBAGENTS; do
    if [ -n "${!setting:-}" ] && ! [[ "${!setting}" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: ${setting} must be an integer, got '${!setting}'." >&2
        exit 2
    fi
done
TIMEOUT_HOURS="${RESEARCHER_TIMEOUT_HOURS:-8}"
TIMEOUT_SECONDS="${RESEARCHER_TIMEOUT_SECONDS:-$(( TIMEOUT_HOURS * 3600 ))}"
# A non-terminal run untouched for this long is not resumed automatically: an
# abandoned run from weeks ago must not silently take over tonight's slot.
# 0 disables the check.
RESUME_MAX_AGE_DAYS="${RESEARCHER_RESUME_MAX_AGE_DAYS:-14}"
# An issue that already has a run directory here is not picked from the queue
# again (tasks#1898 was run twice). RESEARCHER_ISSUE=<n> re-runs one deliberately.
ALLOW_RERUN="${RESEARCHER_ALLOW_RERUN:-false}"

# GitHub publication. Run repos hold unreviewed research and are private unless
# deliberately made public.
REPO_OWNER="${RESEARCHER_GITHUB_OWNER:-tbuckworth}"
TASKS_REPO="${RESEARCHER_TASKS_REPO:-tbuckworth/tasks}"
REPO_VISIBILITY="${RESEARCHER_REPO_VISIBILITY:-private}"
# Where git pushes to. Only tests override this (with a file:// directory of bare repos).
GIT_REMOTE_BASE="${RESEARCHER_GIT_REMOTE_BASE:-https://github.com}"
# Publishing refuses to start below this much free space on the run volume, and
# never publishes a single file at or above MAX_FILE_MB (GitHub rejects files
# over 100 MB, which fails the whole push).
MIN_FREE_MB="${RESEARCHER_MIN_FREE_MB:-1024}"
MAX_FILE_MB="${RESEARCHER_MAX_FILE_MB:-50}"
LIB="${SCRIPT_DIR}/researcher_lib.py"
if ! command -v python3 &>/dev/null || [ ! -f "$LIB" ]; then
    echo "ERROR: python3 and ${LIB} are required. Exiting." >&2
    exit 1
fi
# The workflow steps the runner treats specially (commands/researcher-auto-step.md
# defines them all): it re-enters the audit while its status is
# audit_remediating, and the report is the last step. A run that times out at
# or after FAST_TRACK_MIN_STEP skips the audit and compiles the report from what
# exists; an earlier one ends timed_out.
AUDIT_STEP=10
REPORT_STEP=11
LAST_STEP=$REPORT_STEP
FAST_TRACK_MIN_STEP=5
# Per-step retry: a connection drop mid-step
# leaves state.md un-advanced; re-running the step from current state recovers it.
# Bounded so a genuinely stuck step still fails instead of looping forever.
STEP_MAX_ATTEMPTS="${RESEARCHER_STEP_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${RESEARCHER_RETRY_DELAY_SECONDS:-15}"
# Optional hook: a shell command printing the still-outstanding external
# (e.g. Slurm) job ids for this run; "{run_id}" is substituted. While it prints
# anything, a step that did not advance is WAITING on external compute, not
# failing — so the attempt is refunded instead of spent. Empty = old behaviour.
JOB_WAIT_CMD="${RESEARCHER_JOB_WAIT_CMD:-}"
# Each call of JOB_WAIT_CMD is stopped after this long; it covers the `timeout 90`
# inside the mats profile's command (and agent-board's).
JOB_WAIT_CMD_TIMEOUT_SECONDS="${RESEARCHER_JOB_WAIT_CMD_TIMEOUT_SECONDS:-120}"
JOB_WAIT_POLL_SECONDS="${RESEARCHER_JOB_WAIT_POLL_SECONDS:-120}"
JOB_WAIT_MAX_SECONDS="${RESEARCHER_JOB_WAIT_MAX_SECONDS:-14400}"
JOB_WAIT_MAX_REFUNDS="${RESEARCHER_JOB_WAIT_MAX_REFUNDS:-10}"
# Optional hook: a shell command run before each step ("{run_id}" substituted).
# If it prints anything, its first line is the reason and the run pauses there,
# exactly as on a provider limit: resumable, nothing published. Steps are never
# interrupted, and the run doesn't pause while JOB_WAIT_CMD still reports jobs,
# unless the line starts with "!" (a stop: the jobs keep running and the step
# is redone on resume). agent-board's spare-capacity launcher uses it.
# Empty = old behaviour.
GUARD_CMD="${RESEARCHER_GUARD_CMD:-}"
GUARD_CMD_TIMEOUT_SECONDS=300
# A caller that owns one run (agent-board's spare launcher) pins it: with
# RESEARCHER_RUN_DIR it resumes exactly that run or exits 2, and with
# RESEARCHER_NO_RESUME=true a fresh start never picks up another unfinished run.
# RESEARCHER_OWNER marks the runs it creates (owner: in state.md), and a run
# with an owner is only ever resumed by that owner or through RESEARCHER_RUN_DIR.
PIN_RUN_DIR="${RESEARCHER_RUN_DIR:-}"
NO_RESUME="${RESEARCHER_NO_RESUME:-false}"
RUN_OWNER="${RESEARCHER_OWNER:-}"
case "$RUN_OWNER" in
    *[!A-Za-z0-9_.-]*) echo "ERROR: RESEARCHER_OWNER may only hold letters, digits, '_', '.' and '-'." >&2; exit 2 ;;
esac
TOPIC="${1:-}"

# Provider selection. RESEARCHER_MODEL remains a backwards-compatible
# provider-specific override; the named variables avoid ambiguous saved config.
BACKEND="${RESEARCHER_BACKEND:-claude}"
SKIP_PUBLISH="${RESEARCHER_SKIP_PUBLISH:-false}"
SKIP_EMAIL="${RESEARCHER_SKIP_EMAIL:-false}"
SKIP_GPU_CHECK="${RESEARCHER_SKIP_GPU_CHECK:-false}"
LINK_OUTPUT="${RESEARCHER_LINK_OUTPUT:-true}"
CODEX_IGNORE_USER_CONFIG="${RESEARCHER_CODEX_IGNORE_USER_CONFIG:-true}"
ALLOW_BACKEND_SWITCH="${RESEARCHER_ALLOW_BACKEND_SWITCH:-false}"
PAUSED=false

# One branch per backend in researcher_lib.py BACKENDS (and in runner/provider.sh).
case "$BACKEND" in
    claude)
        PROVIDER_BIN="${RESEARCHER_CLAUDE_BIN:-claude}"
        MODEL="${RESEARCHER_MODEL:-${RESEARCHER_CLAUDE_MODEL:-fable}}"
        AGENT_LABEL="Claude ${MODEL}"
        CONTINUE_COMMAND="/researcher-continue"
        COMMIT_ATTRIBUTION="Co-Authored-By: Claude (autonomous researcher) <noreply@anthropic.com>"
        ;;
    codex)
        PROVIDER_BIN="${RESEARCHER_CODEX_BIN:-codex}"
        MODEL="${RESEARCHER_MODEL:-${RESEARCHER_CODEX_MODEL:-gpt-6-astra}}"
        CODEX_REASONING="${RESEARCHER_CODEX_REASONING:-xhigh}"
        CODEX_FAST_MODEL="${RESEARCHER_CODEX_FAST_MODEL:-gpt-6.1-sol}"
        CODEX_FAST_REASONING="${RESEARCHER_CODEX_FAST_REASONING:-medium}"
        CODEX_DEEP_MODEL="${RESEARCHER_CODEX_DEEP_MODEL:-${MODEL}}"
        CODEX_DEEP_REASONING="${RESEARCHER_CODEX_DEEP_REASONING:-${CODEX_REASONING}}"
        CODEX_SANDBOX="${RESEARCHER_CODEX_SANDBOX:-danger-full-access}"
        CODEX_APPROVAL_POLICY="${RESEARCHER_CODEX_APPROVAL_POLICY:-never}"
        CODEX_MAX_SUBAGENTS="${RESEARCHER_CODEX_MAX_SUBAGENTS:-4}"
        AGENT_LABEL="OpenAI Codex ${MODEL} (${CODEX_REASONING})"
        CONTINUE_COMMAND="\$researcher:researcher-continue"
        COMMIT_ATTRIBUTION="Generated-By: OpenAI Codex (${MODEL}, ${CODEX_REASONING})"
        ;;
    *)
        echo "ERROR: RESEARCHER_BACKEND must be one of: $(python3 "$LIB" backends); got '${BACKEND}'." >&2
        exit 2
        ;;
esac

RESEARCH_IDEAS_LABEL=$(python3 "$LIB" research-ideas-label)
PROCESSING_LABEL=$(python3 "$LIB" status-label "$BACKEND" researching)
PROCESSED_LABEL=$(python3 "$LIB" status-label "$BACKEND" processed)
# The workflow statuses that end a run (is_terminal_status).
TERMINAL_STATUSES=$(python3 "$LIB" terminal-statuses)
EMAIL_TO="${RESEARCHER_EMAIL_TO:-titusbuckworth@gmail.com}"
export RESEARCHER_EMAIL_TO="$EMAIL_TO"
# The results email goes from the agents' mail account (agent-mail), never from
# Titus's own Gmail, and through the mailroom's pre-send review like every
# agent's mail to him. A Claude session writes and sends it, so his reply comes
# back to that session, whichever backend ran the research; a Codex run uses
# EMAIL_CLAUDE_MODEL for it. Only when no Claude session can run does the run's
# own backend write it, and it then goes unrouted (no review, replies to the
# orchestrator).
SEND_EMAIL="${SCRIPT_DIR}/send-results-email.sh"
EMAIL_CLAUDE_BIN="${RESEARCHER_CLAUDE_BIN:-claude}"
if [ "$BACKEND" = "claude" ]; then
    EMAIL_CLAUDE_MODEL="$MODEL"
else
    EMAIL_CLAUDE_MODEL="${RESEARCHER_EMAIL_CLAUDE_MODEL:-sonnet}"
fi

# How the reader of the results email reaches the machine this run executed on, so
# the email's "How to Continue This Research" steps are literally runnable. This is
# an SSH *alias* as configured in the reader's ~/.ssh/config, not a hostname — any
# machine not in the table below must set RESEARCHER_HOST_ALIAS, or the run exits 2.
# The value "local" suppresses the ssh step entirely (run and reader on the same machine).
if [ -z "${RESEARCHER_HOST_ALIAS:-}" ]; then
    RUN_HOSTNAME=$(hostname -s)
    case "$RUN_HOSTNAME" in
        titus-MS-7A59) HOST_ALIAS="desktop" ;;
        *)
            echo "ERROR: host '${RUN_HOSTNAME}' is not in the table; set RESEARCHER_HOST_ALIAS to the SSH alias the email's reader uses for this machine, or to 'local'." >&2
            exit 2
            ;;
    esac
else
    HOST_ALIAS="$RESEARCHER_HOST_ALIAS"
fi

# Compute profile for this run — a human-readable description of the hardware/budget
# experiments may use. Hardware-agnostic: the default describes the local desktop, but
# override it for other backends, e.g.
#   RESEARCHER_COMPUTE_PROFILE='Modal A100 40GB on-demand, ~$3.50/hr, up to $30 budget'
#   RESEARCHER_COMPUTE_PROFILE='Lambda 8xH100 80GB node'
#   RESEARCHER_COMPUTE_PROFILE='tinker fine-tuning API (managed training), no local GPU'
# Paid compute (Modal, Lambda, Slurm elastic-*, HF endpoints) must be registered with
# cloud-watch straight after launch and stopped before the step ends (the experiment
# rules in commands/researcher-auto-step.md and agents/experiment.md say how).
# Every step reads this from state.md (compute_profile:) to size experiments and to triage
# which limitations are fixable now vs genuine future work. Nothing is hard-coded to a 3090.
#
# Short presets expand to a full description (see docs/COMPUTE-MATS.md):
#   RESEARCHER_COMPUTE_PROFILE=local   # local NVIDIA GPU (default)
#   RESEARCHER_COMPUTE_PROFILE=mats    # MATS Slurm cluster (free L40s), submitted remotely over SSH
COMPUTE_PROFILE_LOCAL="Local NVIDIA RTX 3090 (24GB VRAM); CPU fallback available. No cloud GPU or paid API budget provisioned for this run. Prefer lightweight experiments (small open-weight models), each targeting under 30 min runtime. Max 5 experiments."
COMPUTE_PROFILE_MATS="MATS Slurm cluster, driven REMOTELY over SSH from wherever this run is executing (laptop or desktop) - you are NOT on the cluster. Every cluster command is prefixed: ssh mats '<cmd>' for the dev/login node, ssh mats-controller '<cmd>' for the controller (the only place gpu-avail and gpu-cost exist). AUTHORIZED COMPUTE: the FREE 'compute' partition only - one shared always-on node with 8x NVIDIA L40 (48GB VRAM each). Your concurrent cap across all your jobs is 6 GPUs, 124 CPUs, and 384GB RAM; max wall time is 24h per job. Request 1 GPU (--gres=gpu:1) unless the experiment genuinely needs more, and up to 6 when it does (single node, so torchrun/FSDP works). Sizing on 48GB: fp16 inference up to ~20B params, LoRA/QLoRA fine-tuning up to ~7B (13B with care), full fine-tuning only up to ~2-3B. Add --qos=debug for validation runs under 2h to jump the queue. PAID elastic-* partitions (A100/H100) are NOT authorized for autonomous runs (they bill by the hour and need Titus's explicit confirmation): if an experiment needs more than 6 L40s or more VRAM per device, do not attempt it - record a FAIL-on-affordability with the exact resource ask and continue. WORKFLOW for each experiment: (1) write the code and an sbatch script locally under experiments/exp-NNN/; (2) stage it with rsync -avP experiments/exp-NNN/ mats:/mnt/nw/home/t.buckworth/researcher-runs/<run-id>/exp-NNN/; (3) submit with ssh mats 'cd /mnt/nw/home/t.buckworth/researcher-runs/<run-id>/exp-NNN && mkdir -p logs && sbatch run.sbatch' - create logs/ BEFORE sbatch, because Slurm opens the output file at job launch and an in-script mkdir is too late; (4) poll with ssh mats 'squeue -u t.buckworth' until the job leaves the queue (PD pending, R running, CG completing), sleeping 60s between polls rather than busy-looping - the free partition is shared and a PD (Resources) wait of tens of minutes is normal, NOT a failure, so keep waiting; do NOT end the step while a job you submitted is still queued or running - if you must stop, first record the job id and its experiment in state.md so the next attempt resumes waiting instead of resubmitting; and before submitting anything, run squeue and check whether a job for this experiment is already queued or running, because the step may be retried after an interruption and duplicate submissions waste the shared partition; (5) pull results back with rsync -avP mats:.../exp-NNN/ experiments/exp-NNN/ and copy the full slurm log into run.log. NEVER run training, fine-tuning, heavy inference, or long CPU loops in an ssh shell on the dev node - it is the shared login node and that is the cluster's worst etiquette violation. Never run agents or jobs on the controller. The local machine this run executes on is for orchestration, plotting, and light analysis of returned results only - do not silently fall back to a local GPU for experiments under this profile. Job script requirements: all #SBATCH lines must precede the first command (any command above them silently disables every directive below); include --partition=compute, --gres=gpu:1, a realistic --time, --job-name, --cpus-per-task=8, --mem=32G, --output=logs/slurm-%j.out. Storage on the cluster: code, checkpoints, and final results under /mnt/nw/home/t.buckworth (persistent NFS, NOT backed up - pull anything irreplaceable back to this machine); HuggingFace cache, dataset shards, and intermediate outputs under /ephemeral/t.buckworth (fast local scratch, wiped on reboot) via HF_HOME=/ephemeral/t.buckworth/hf. Every job script also exports TMPDIR=/ephemeral/t.buckworth/tmp, XDG_CACHE_HOME=/ephemeral/t.buckworth/cache and WANDB_DIR=/ephemeral/t.buckworth/wandb, and runs mkdir -p on all four first: nothing bulky may go in /tmp, which is the worker's root disk (filling it drains the node for everyone). Inside every job script: source ~/venv/bin/activate (the cluster's shared venv) and run python with -u so logs are not buffered. That venv pins torch 2.5.1+cu121 to match the workers' CUDA 12.2 driver - do NOT upgrade torch or install one from default PyPI, which breaks CUDA on every job. Diagnostics: ssh mats 'scontrol show job <jobid>' explains a stuck job; sacct works only from the controller (it errors with Connection refused on the dev node); nvidia-smi on the dev node fails because there is no GPU there, which is expected; on compute, nvidia-smi inside a job lists all 8 physical GPUs but you only own \$CUDA_VISIBLE_DEVICES; an empty .out file on a running job is usually stdout buffering. scancel anything left idle. Prefer lightweight experiments (small open-weight models), each targeting under 30 min of GPU time. Max 5 experiments."

# COMPUTE_PROFILE_NAME (the preset, or "custom") is for the startup log line.
case "${RESEARCHER_COMPUTE_PROFILE:-}" in
    ""|local|LOCAL) COMPUTE_PROFILE="$COMPUTE_PROFILE_LOCAL"; COMPUTE_PROFILE_NAME=local ;;
    mats|MATS|mats-cluster)
        COMPUTE_PROFILE="$COMPUTE_PROFILE_MATS"
        COMPUTE_PROFILE_NAME=mats
        # A queued/running job for THIS run means the step is waiting, not failing.
        # Its own 90 s timeout must stay below JOB_WAIT_CMD_TIMEOUT_SECONDS (default 120),
        # or run_hook cuts squeue off first and the step looks as if it had no jobs.
        : "${JOB_WAIT_CMD:=timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=20 mats \"squeue -u t.buckworth -h -o '%i %Z'\" | grep -F '{run_id}' || true}"
        ;;
    *) COMPUTE_PROFILE="$RESEARCHER_COMPUTE_PROFILE"; COMPUTE_PROFILE_NAME=custom ;;
esac

# Global research knowledge base (the compounding wiki). Optional: a run works
# identically without one. Set RESEARCHER_KB_DIR=none to disable explicitly, or
# bootstrap one with scripts/kb-init.sh. Only a directory that holds a
# KB-SCHEMA.md is a knowledge base: with RESEARCHER_KB_DIR unset, the default
# path without one means no KB; an explicit path without one exits 2, rather
# than sending agents to write pages into an unstructured directory or quietly
# running without the KB that was asked for.
case "${RESEARCHER_KB_DIR:-}" in
    "")
        KB_DIR="${HOME}/pyg/research-wiki"
        [ -f "${KB_DIR}/KB-SCHEMA.md" ] || KB_DIR=""
        ;;
    none) KB_DIR="" ;;
    *)
        if [ ! -f "${RESEARCHER_KB_DIR}/KB-SCHEMA.md" ]; then
            echo "ERROR: RESEARCHER_KB_DIR=${RESEARCHER_KB_DIR} has no KB-SCHEMA.md. Bootstrap it with scripts/kb-init.sh, or set RESEARCHER_KB_DIR=none." >&2
            exit 2
        fi
        KB_DIR="$RESEARCHER_KB_DIR"
        ;;
esac

# The runner's functions live in scripts/runner/, one file per concern; this file
# holds the configuration and the top-level flow.
# shellcheck source=runner/common.sh
source "${SCRIPT_DIR}/runner/common.sh"
# shellcheck source=runner/runs.sh
source "${SCRIPT_DIR}/runner/runs.sh"
# shellcheck source=runner/state.sh
source "${SCRIPT_DIR}/runner/state.sh"
# shellcheck source=runner/provider.sh
source "${SCRIPT_DIR}/runner/provider.sh"
# shellcheck source=runner/steps.sh
source "${SCRIPT_DIR}/runner/steps.sh"
# shellcheck source=runner/publish.sh
source "${SCRIPT_DIR}/runner/publish.sh"
# shellcheck source=runner/notify.sh
source "${SCRIPT_DIR}/runner/notify.sh"

if [ -z "${RESEARCHER_OUTPUT_DIR:-}" ] && [ ! -d "$STORAGE_ROOT" ]; then
    echo "ERROR: storage root not mounted at ${STORAGE_ROOT}." >&2
    echo "Set RESEARCHER_OUTPUT_DIR to use a different location." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Symlink logs and output into the plugin dir for convenience.
if is_true "$LINK_OUTPUT"; then
    ln -sfn "$OUTPUT_DIR" "${REPO_DIR}/output"
    ln -sfn "$LOG_DIR" "${REPO_DIR}/logs"
fi

# --- Lockfile ---
if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "ERROR: Another run is active (PID $PID). Exiting."
        exit 0
    else
        log "WARN: Stale lockfile found (PID $PID dead). Removing."
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# --- Health checks ---
if ! command -v "$PROVIDER_BIN" &>/dev/null; then
    log "ERROR: ${BACKEND} CLI not found: ${PROVIDER_BIN}. Exiting."
    exit 1
fi

if [ -z "$TOPIC" ] || ! is_true "$SKIP_PUBLISH"; then
    if ! gh auth status &>/dev/null; then
        log "ERROR: gh CLI not authenticated. Run 'gh auth login'. Exiting."
        exit 1
    fi
fi

if [ "$BACKEND" = "codex" ]; then
    case "$CODEX_SANDBOX" in
        read-only|workspace-write|danger-full-access) ;;
        *)
            log "ERROR: invalid RESEARCHER_CODEX_SANDBOX '${CODEX_SANDBOX}'."
            exit 2
            ;;
    esac
    case "$CODEX_APPROVAL_POLICY" in
        untrusted|on-request|never) ;;
        *)
            log "ERROR: invalid RESEARCHER_CODEX_APPROVAL_POLICY '${CODEX_APPROVAL_POLICY}'."
            exit 2
            ;;
    esac
fi

# The same list as researcher_lib.py's REPO_VISIBILITIES.
case "$REPO_VISIBILITY" in
    private|internal|public) ;;
    *)
        log "ERROR: RESEARCHER_REPO_VISIBILITY must be private, internal or public, got '${REPO_VISIBILITY}'."
        exit 2
        ;;
esac

log "Agent backend: ${BACKEND}; model: ${MODEL}; compute profile: ${COMPUTE_PROFILE_NAME}; knowledge base: ${KB_DIR:-none}; owner: ${RUN_OWNER:-none}; pinned run: ${PIN_RUN_DIR:-none}"

# Check if GPU is busy (>500MB VRAM used by any single process = busy). A GPU
# whose use cannot be read is not taken to be idle: the runner stops (exit 1).
if ! is_true "$SKIP_GPU_CHECK" && command -v nvidia-smi &>/dev/null; then
    if ! GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits); then
        log "ERROR: nvidia-smi failed (its error is above), so whether the GPU is busy is unknown. Set RESEARCHER_SKIP_GPU_CHECK=true to run without the check. Exiting."
        exit 1
    fi
    if [ -n "$GPU_PROCS" ]; then
        GPU_MEMS=$(printf '%s\n' "$GPU_PROCS" | awk -F', *' '{print $2}')
        if BAD_MEM=$(printf '%s\n' "$GPU_MEMS" | grep -v -m1 '^[0-9][0-9]*$'); then
            log "ERROR: nvidia-smi reported GPU memory use '${BAD_MEM}', not a number of MiB, so whether the GPU is busy is unknown. Set RESEARCHER_SKIP_GPU_CHECK=true to run without the check. Exiting."
            exit 1
        fi
        MAX_MEM=$(printf '%s\n' "$GPU_MEMS" | sort -n | tail -1)
        if [ "$MAX_MEM" -gt 500 ]; then
            log "GPU busy (process using ${MAX_MEM} MiB). Skipping this run."
            exit 0
        fi
    fi
fi

# --- Find or create run ---
RUN_DIR=""
ISSUE_NUMBER=""
PICKED=""
IS_FOLLOWUP=false
FOLLOWUP_TITLE=""
PARENT_ISSUE=""
PRIOR_REPO_URL=""
PRIOR_RUN_ID=""
FEEDBACK=""
FOLLOWUP_KEY=""

# Check for in-progress run first
IN_PROGRESS=""
if [ -n "$PIN_RUN_DIR" ]; then
    IN_PROGRESS=$(pinned_run) || exit 2
elif ! is_true "$NO_RESUME"; then
    IN_PROGRESS=$(find_in_progress_run) || IN_PROGRESS=""
fi
if [ -n "$IN_PROGRESS" ]; then
    RUN_DIR="$IN_PROGRESS"
    STATE_FILE="${RUN_DIR}/state.md"
    STORED_BACKEND=$(state_field "$STATE_FILE" agent_backend)
    if [ -n "$STORED_BACKEND" ] \
        && [ "$STORED_BACKEND" != "$BACKEND" ] \
        && ! is_true "$ALLOW_BACKEND_SWITCH"; then
        log "ERROR: in-progress run uses backend '${STORED_BACKEND}', requested '${BACKEND}'."
        log "Resume with RESEARCHER_BACKEND=${STORED_BACKEND}, or set RESEARCHER_ALLOW_BACKEND_SWITCH=true deliberately."
        exit 2
    fi
    # The run's own wrapper-owned fields (see runtime_fields in runner/state.sh),
    # which ensure_runtime_state writes back after every step.
    ISSUE_NUMBER=$(state_field "$STATE_FILE" issue_number)
    [ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
    if [ "$(state_field "$STATE_FILE" is_followup)" = true ]; then
        IS_FOLLOWUP=true
        PARENT_ISSUE=$(state_field "$STATE_FILE" parent_issue)
        PRIOR_REPO_URL=$(state_field "$STATE_FILE" prior_repo)
        PRIOR_RUN_ID=$(state_field "$STATE_FILE" prior_run_id)
        FOLLOWUP_KEY=$(state_field "$STATE_FILE" followup_key)
    fi
    if [ -n "${RESEARCHER_ISSUE:-}" ] && [ "${ISSUE_NUMBER:-}" != "$RESEARCHER_ISSUE" ]; then
        # Finishing in-flight work first is right, but doing it silently is not:
        # a scheduled run targeting a specific issue would otherwise look like it
        # ran that issue when it resumed something else entirely.
        log "WARN: RESEARCHER_ISSUE=${RESEARCHER_ISSUE} was requested, but an in-progress run for issue #${ISSUE_NUMBER:-none} exists."
        log "WARN: resuming that run instead. Re-request #${RESEARCHER_ISSUE} once it finishes."
    fi
    log "Resuming in-progress run: ${RUN_DIR}"
elif [ -n "$TOPIC" ]; then
    create_run_dir
else
    pick_issue
    create_run_dir
fi

# --- Step loop ---
START_TIME=$(date +%s)
# Bash-owned ceiling for the Step 10 audit-remediation loop, independent of any
# agent-written field — so a missing or garbage audit_round can never wedge the run.
AUDIT_ROUNDS=0

# A timeout is recorded in state.md, so a run paused during its timeout
# fast-track still reports the skipped audit when it is resumed.
TIMED_OUT=false
if [ "$(state_field "${RUN_DIR}/state.md" timed_out)" = true ]; then
    TIMED_OUT=true
fi

# The run's owner (RESEARCHER_OWNER when it was created) stays in state.md and is
# restored after every step, so a plain cron never resumes a run someone else
# runs under its own guard and budget.
RUN_DIR_OWNER=$(state_field "${RUN_DIR}/state.md" owner)
[ -n "$RUN_DIR_OWNER" ] || RUN_DIR_OWNER="$RUN_OWNER"
if [ -n "$RUN_DIR_OWNER" ]; then
    set_state_field owner "$RUN_DIR_OWNER"
fi

# Main step loop
while true; do
    CURRENT_STEP=$(get_current_step)
    STATUS=$(get_status)

    if is_terminal_status "$STATUS"; then
        log "Run reached terminal state: ${STATUS}"
        break
    fi
    case "$CURRENT_STEP" in
        ''|*[!0-9]*)
            log "ERROR: state.md has no valid current_step ('${CURRENT_STEP}'). Marking the run failed."
            set_status failed
            break
            ;;
    esac

    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ "$ELAPSED" -gt "$TIMEOUT_SECONDS" ]; then
        TIMED_OUT=true
        set_state_field timed_out true
        log "Timeout (${TIMEOUT_SECONDS}s) reached at step ${CURRENT_STEP}."
        STEP_RC=0
        if [ "$CURRENT_STEP" -ge "$FAST_TRACK_MIN_STEP" ]; then
            # Bypass the audit on a timed-out run — never re-enter a
            # multi-hour remediation re-run — and compile whatever exists.
            log "Skipping the results audit and compiling the report from what exists."
            # current_step too, so a pause inside the report resumes at the report
            # rather than re-running the remaining steps and the audit.
            set_state_field current_step "$AUDIT_STEP"
            set_status audit_complete
            run_step "$REPORT_STEP" || STEP_RC=$?
        fi
        if [ "$STEP_RC" -eq 2 ]; then
            pause_run "$REPORT_STEP"
        elif [ "$(get_status)" != "complete" ]; then
            # Only a run whose report did NOT complete is marked timed out. A
            # finished report keeps status complete: the timeout used to
            # overwrite finished runs to "failed" (tasks#1874).
            set_status timed_out
        fi
        break
    fi

    # Audit-remediation re-entry: stay on the audit while the auditor asks for another
    # round. AUDIT_ROUNDS (bash-owned) is the authoritative ceiling — no agent field needed.
    if [ "$CURRENT_STEP" -eq "$AUDIT_STEP" ] && [ "$STATUS" = "audit_remediating" ]; then
        AUDIT_ROUNDS=$((AUDIT_ROUNDS + 1))
        if [ "$AUDIT_ROUNDS" -ge 4 ]; then
            # Hand over to the report like any other audit exit; the report's
            # own success or failure then decides the status. (Forcing
            # "complete" here used to mark runs complete whose report failed.)
            log "Audit-remediation ceiling reached (${AUDIT_ROUNDS} rounds). Forcing the report."
            set_status audit_complete
            continue
        fi
        NEXT_STEP=$AUDIT_STEP
    else
        AUDIT_ROUNDS=0
        NEXT_STEP=$((CURRENT_STEP + 1))
    fi

    if [ "$NEXT_STEP" -gt "$LAST_STEP" ]; then
        log "All steps completed."
        # The last step advanced current_step but left a non-terminal status.
        set_status complete
        break
    fi

    if guard_holds_run; then
        pause_run "$NEXT_STEP"
        break
    fi

    STEP_RC=0
    run_step "$NEXT_STEP" || STEP_RC=$?
    if [ "$STEP_RC" -eq 2 ]; then
        pause_run "$NEXT_STEP"
        break
    elif [ "$STEP_RC" -ne 0 ]; then
        log "Step ${NEXT_STEP} did not complete. Stopping."
        break
    fi
done

# --- Post-completion: publish to GitHub (git init in place, no copying) ---
STATUS=$(get_status)
# The run id is the directory name; ensure_runtime_state keeps run_id in step.
RUN_ID=$(basename "$RUN_DIR")
TOPIC_LINE=$(state_field "${RUN_DIR}/state.md" topic)
[ -n "$TOPIC_LINE" ] || TOPIC_LINE=$(head -1 "${RUN_DIR}/topic.txt" 2>/dev/null || true)
[ -n "$TOPIC_LINE" ] || TOPIC_LINE="$RUN_ID"

# Publication result, consumed by the outcome, the email and the issue comment.
#   PUBLISH_STATE: pushed (the remote branch verifiably holds this run's HEAD),
#                  failed, or skipped (deliberately not published)
PUBLISH_STATE="skipped"
PUBLISH_ERROR=""
REPO_WEB=""
REPO_BRANCH="main"
# The visibility actually read back from GitHub, which is what reports state.
PUBLISHED_VISIBILITY="$REPO_VISIBILITY"
# Caveats from publishing (files left out), passed into the outcome.
PUBLISH_NOTES=()

if is_true "$SKIP_PUBLISH"; then
    log "Skipping GitHub publication (RESEARCHER_SKIP_PUBLISH=${SKIP_PUBLISH})."
else
    # Every path through publishing ends pushed or failed-with-a-reason; an
    # unexpected stop must still be recorded, never a silently missing repo.
    # (publish_run's own reason is kept: it is the useful one.)
    publish_run || true
    cd "$REPO_DIR"
    if [ "$PUBLISH_STATE" = "skipped" ]; then
        publish_fail "publishing stopped before it finished (see log)"
    fi
fi

# --- Post-completion: final outcome ---
# The run's final status, from what actually exists: did the workflow finish,
# are there valid results, and is it on GitHub. Recorded in state.md and
# run-outcome.json, and used verbatim by the email and the issue comment.
NOTE_ARGS=()
for note in ${PUBLISH_NOTES[@]+"${PUBLISH_NOTES[@]}"}; do
    NOTE_ARGS+=(--note "$note")
done
OUTCOME_JSON=$(python3 "$LIB" outcome \
    ${NOTE_ARGS[@]+"${NOTE_ARGS[@]}"} \
    --run-dir "$RUN_DIR" \
    --status "$STATUS" \
    --timed-out "$TIMED_OUT" \
    --publish-state "$PUBLISH_STATE" \
    --publish-error "$PUBLISH_ERROR" \
    --paused "$PAUSED") \
    || OUTCOME_JSON=$(jq -n --arg s "$STATUS" --arg p "$PUBLISH_STATE" \
        '{outcome: "unknown", success: false, status: $s, publish_state: $p, reasons: ["the outcome could not be computed; see the cron log"]}')
# On a full disk these writes fail; that must not stop the email and the
# issue update that report it.
printf '%s\n' "$OUTCOME_JSON" > "${RUN_DIR}/run-outcome.json" \
    || log "WARN: could not write ${RUN_DIR}/run-outcome.json"
FINAL_OUTCOME=$(echo "$OUTCOME_JSON" | jq -r '.outcome')
OUTCOME_REASONS=$(echo "$OUTCOME_JSON" | jq -r '.reasons[]' | sed 's/^/  - /')
upsert_frontmatter_field "final_outcome" "$FINAL_OUTCOME" || true
upsert_frontmatter_field "publish_state" "$PUBLISH_STATE" || true
log "Final outcome: ${FINAL_OUTCOME} (workflow status ${STATUS}, publish ${PUBLISH_STATE})"
[ -n "$OUTCOME_REASONS" ] && printf '%s\n' "$OUTCOME_REASONS"

# --- Post-completion: Send email ---

if is_true "$SKIP_EMAIL"; then
    log "Skipping email (RESEARCHER_SKIP_EMAIL=${SKIP_EMAIL})."
else
    send_email || log "Note: email did not send. Results remain in ${RUN_DIR}."
fi

# --- Post-completion: report back on the GitHub issue ---

if ! is_true "$SKIP_PUBLISH" && [ -n "$ISSUE_NUMBER" ] && [ "$ISSUE_NUMBER" != "none" ]; then
    # The comment is best effort (a full disk can stop even mktemp); the label
    # swap below must happen regardless, or the issue stays claimed forever.
    COMMENT_FILE=$(mktemp "${TMPDIR:-/tmp}/researcher-comment.XXXXXX" 2>/dev/null) || COMMENT_FILE=""
    if [ -n "$COMMENT_FILE" ]; then
        python3 "$LIB" issue-comment \
            ${NOTE_ARGS[@]+"${NOTE_ARGS[@]}"} \
            --run-dir "$RUN_DIR" \
            --status "$STATUS" \
            --timed-out "$TIMED_OUT" \
            --publish-state "$PUBLISH_STATE" \
            --publish-error "$PUBLISH_ERROR" \
            --paused "$PAUSED" \
            --run-id "$RUN_ID" \
            --repo-web "$REPO_WEB" \
            --branch "$REPO_BRANCH" \
            --agent-label "$AGENT_LABEL" \
            --host "$HOST_ALIAS" \
            --followup "$IS_FOLLOWUP" \
            --visibility "$PUBLISHED_VISIBILITY" > "$COMMENT_FILE" \
            || printf 'Autonomous research run `%s` finished with outcome `%s` (the findings summary could not be generated; see the cron log).\n' \
                "$RUN_ID" "$FINAL_OUTCOME" > "$COMMENT_FILE" \
            || true

        post_issue_comment "$ISSUE_NUMBER" "$COMMENT_FILE"
        if [ "$IS_FOLLOWUP" = true ] && [ -n "$PARENT_ISSUE" ] && [ "$PARENT_ISSUE" != "none" ]; then
            if { printf 'Follow-up #%s finished.\n\n' "$ISSUE_NUMBER"; cat "$COMMENT_FILE"; } > "${COMMENT_FILE}.parent"; then
                post_issue_comment "$PARENT_ISSUE" "${COMMENT_FILE}.parent"
            fi
            rm -f "${COMMENT_FILE}.parent"
        fi
        rm -f "$COMMENT_FILE"
    else
        log "WARN: could not create a temporary file for the issue comment (disk full?); skipping the comment."
    fi

    gh issue edit "$ISSUE_NUMBER" --repo "$TASKS_REPO" \
        --remove-label "$PROCESSING_LABEL" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$TASKS_REPO" \
        --add-label "$PROCESSED_LABEL" 2>/dev/null || true

    log "Updated issue #${ISSUE_NUMBER}"
fi

if is_true "$PAUSED"; then
    # Distinct exit code: a paused run must not look like a completed one to
    # cron, `at`, or any wrapper checking the status.
    log "PAUSED (not complete). Run directory: ${RUN_DIR}"
    exit 3
fi

if ! outcome_is_success; then
    # Distinct exit code for a run that finished without a usable, published
    # result, so it cannot pass for a completed one.
    log "Done, but the run is NOT complete (outcome: ${FINAL_OUTCOME}). Run directory: ${RUN_DIR}"
    exit 4
fi

log "Done. Run directory: ${RUN_DIR}"

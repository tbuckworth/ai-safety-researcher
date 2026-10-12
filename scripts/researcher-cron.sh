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
# Crontab example (daily at 2am):
#   0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Cron and non-login SSH shells often omit user-installed CLIs.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

# Research output goes on the HDD (2.7TB) to avoid filling the SSD
HDD="${RESEARCHER_STORAGE_ROOT:-/media/titus/big}"
OUTPUT_DIR="${RESEARCHER_OUTPUT_DIR:-${HDD}/researcher-output}"
LOG_DIR="${RESEARCHER_LOG_DIR:-${OUTPUT_DIR}/logs}"

LOCKFILE="${RESEARCHER_LOCKFILE:-/tmp/researcher-auto.lock}"
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
JOB_WAIT_POLL_SECONDS="${RESEARCHER_JOB_WAIT_POLL_SECONDS:-120}"
JOB_WAIT_MAX_SECONDS="${RESEARCHER_JOB_WAIT_MAX_SECONDS:-14400}"
JOB_WAIT_MAX_REFUNDS="${RESEARCHER_JOB_WAIT_MAX_REFUNDS:-10}"
# Optional hook: a shell command run before each step ("{run_id}" substituted).
# If it prints anything, its first line is the reason and the run pauses there,
# exactly as on a provider limit: resumable, nothing published. Steps are never
# interrupted, and the run never pauses while JOB_WAIT_CMD still reports jobs.
# agent-board's spare-capacity launcher uses it. Empty = old behaviour.
GUARD_CMD="${RESEARCHER_GUARD_CMD:-}"
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
        MODEL="${RESEARCHER_MODEL:-${RESEARCHER_CODEX_MODEL:-gpt-5.6-sol}}"
        CODEX_REASONING="${RESEARCHER_CODEX_REASONING:-xhigh}"
        CODEX_FAST_MODEL="${RESEARCHER_CODEX_FAST_MODEL:-gpt-5.6-terra}"
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
        echo "ERROR: RESEARCHER_BACKEND must be 'claude' or 'codex', got '${BACKEND}'." >&2
        exit 2
        ;;
esac

PROCESSING_LABEL="status:${BACKEND}-researching"
PROCESSED_LABEL="status:${BACKEND}-processed"
EMAIL_TO="${RESEARCHER_EMAIL_TO:-titusbuckworth@gmail.com}"
EMAIL_LABEL="${RESEARCHER_EMAIL_LABEL:-Researcher}"
SEND_EMAIL_SCRIPT="${RESEARCHER_SEND_EMAIL_SCRIPT:-${HOME}/pyg/claude-remote-setup/plugins/report-email/scripts/send_report_email.py}"

# How the reader of the results email reaches the machine this run executed on, so
# the email's "How to Continue This Research" steps are literally runnable. This is
# an SSH *alias* as configured in the reader's ~/.ssh/config, not a hostname — set
# RESEARCHER_HOST_ALIAS explicitly on any machine not in the table below. The value
# "local" suppresses the ssh step entirely (run and reader on the same machine).
if [ -z "${RESEARCHER_HOST_ALIAS:-}" ]; then
    case "$(hostname -s 2>/dev/null || echo unknown)" in
        titus-MS-7A59) HOST_ALIAS="desktop" ;;
        *)             HOST_ALIAS="local" ;;
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
# Every step reads this from state.md (compute_profile:) to size experiments and to triage
# which limitations are fixable now vs genuine future work. Nothing is hard-coded to a 3090.
#
# Short presets expand to a full description (see docs/COMPUTE-MATS.md):
#   RESEARCHER_COMPUTE_PROFILE=local   # local NVIDIA GPU (default)
#   RESEARCHER_COMPUTE_PROFILE=mats    # MATS Slurm cluster (free L40s), submitted remotely over SSH
COMPUTE_PROFILE_LOCAL="Local NVIDIA RTX 3090 (24GB VRAM); CPU fallback available. No cloud GPU or paid API budget provisioned for this run. Prefer lightweight experiments (small open-weight models), each targeting under 30 min runtime. Max 5 experiments."
COMPUTE_PROFILE_MATS="MATS Slurm cluster, driven REMOTELY over SSH from wherever this run is executing (laptop or desktop) - you are NOT on the cluster. Every cluster command is prefixed: ssh mats '<cmd>' for the dev/login node, ssh mats-controller '<cmd>' for the controller (the only place gpu-avail and gpu-cost exist). AUTHORIZED COMPUTE: the FREE 'compute' partition only - one shared always-on node with 8x NVIDIA L40 (48GB VRAM each). Your concurrent cap across all your jobs is 6 GPUs, 124 CPUs, and 384GB RAM; max wall time is 24h per job. Request 1 GPU (--gres=gpu:1) unless the experiment genuinely needs more, and up to 6 when it does (single node, so torchrun/FSDP works). Sizing on 48GB: fp16 inference up to ~20B params, LoRA/QLoRA fine-tuning up to ~7B (13B with care), full fine-tuning only up to ~2-3B. Add --qos=debug for validation runs under 2h to jump the queue. PAID elastic-* partitions (A100/H100) are NOT authorized and the account is not enabled for them: if an experiment needs more than 6 L40s or more VRAM per device, do not attempt it - record a FAIL-on-affordability with the exact resource ask and continue. WORKFLOW for each experiment: (1) write the code and an sbatch script locally under experiments/exp-NNN/; (2) stage it with rsync -avP experiments/exp-NNN/ mats:/mnt/nw/home/t.buckworth/researcher-runs/<run-id>/exp-NNN/; (3) submit with ssh mats 'cd /mnt/nw/home/t.buckworth/researcher-runs/<run-id>/exp-NNN && mkdir -p logs && sbatch run.sbatch' - create logs/ BEFORE sbatch, because Slurm opens the output file at job launch and an in-script mkdir is too late; (4) poll with ssh mats 'squeue -u t.buckworth' until the job leaves the queue (PD pending, R running, CG completing), sleeping 60s between polls rather than busy-looping - the free partition is shared and a PD (Resources) wait of tens of minutes is normal, NOT a failure, so keep waiting; do NOT end the step while a job you submitted is still queued or running - if you must stop, first record the job id and its experiment in state.md so the next attempt resumes waiting instead of resubmitting; and before submitting anything, run squeue and check whether a job for this experiment is already queued or running, because the step may be retried after an interruption and duplicate submissions waste the shared partition; (5) pull results back with rsync -avP mats:.../exp-NNN/ experiments/exp-NNN/ and copy the full slurm log into run.log. NEVER run training, fine-tuning, heavy inference, or long CPU loops in an ssh shell on the dev node - it is the shared login node and that is the cluster's worst etiquette violation. Never run agents or jobs on the controller. The local machine this run executes on is for orchestration, plotting, and light analysis of returned results only - do not silently fall back to a local GPU for experiments under this profile. Job script requirements: all #SBATCH lines must precede the first command (any command above them silently disables every directive below); include --partition=compute, --gres=gpu:1, a realistic --time, --job-name, --cpus-per-task=8, --mem=32G, --output=logs/slurm-%j.out. Storage on the cluster: code, checkpoints, and final results under /mnt/nw/home/t.buckworth (persistent NFS, NOT backed up - pull anything irreplaceable back to this machine); HuggingFace cache, dataset shards, and intermediate outputs under /ephemeral/t.buckworth (fast local scratch, wiped on reboot) via HF_HOME=/ephemeral/t.buckworth/hf. Inside every job script: source ~/venv/bin/activate (the cluster's shared venv) and run python with -u so logs are not buffered. That venv pins torch 2.5.1+cu121 to match the workers' CUDA 12.2 driver - do NOT upgrade torch or install one from default PyPI, which breaks CUDA on every job. Diagnostics: ssh mats 'scontrol show job <jobid>' explains a stuck job; sacct works only from the controller (it errors with Connection refused on the dev node); nvidia-smi on the dev node fails because there is no GPU there, which is expected; on compute, nvidia-smi inside a job lists all 8 physical GPUs but you only own \$CUDA_VISIBLE_DEVICES; an empty .out file on a running job is usually stdout buffering. scancel anything left idle. Prefer lightweight experiments (small open-weight models), each targeting under 30 min of GPU time. Max 5 experiments."

case "${RESEARCHER_COMPUTE_PROFILE:-}" in
    ""|local|LOCAL) COMPUTE_PROFILE="$COMPUTE_PROFILE_LOCAL" ;;
    mats|MATS|mats-cluster)
        COMPUTE_PROFILE="$COMPUTE_PROFILE_MATS"
        # A queued/running job for THIS run means the step is waiting, not failing.
        : "${JOB_WAIT_CMD:=ssh mats \"squeue -u t.buckworth -h -o '%i %Z'\" | grep -F '{run_id}' || true}"
        ;;
    *) COMPUTE_PROFILE="$RESEARCHER_COMPUTE_PROFILE" ;;
esac

# Global research knowledge base (the compounding wiki). Optional: a run works
# identically without one. Set RESEARCHER_KB_DIR=none to disable explicitly, or
# bootstrap one with scripts/kb-init.sh. Only a directory that actually holds a
# KB-SCHEMA.md counts — a path pointing at nothing is treated as "no KB" rather
# than silently sending agents to write pages into an unstructured directory.
KB_DIR="${RESEARCHER_KB_DIR:-${HOME}/pyg/research-wiki}"
if [ "$KB_DIR" = "none" ] || [ ! -f "${KB_DIR}/KB-SCHEMA.md" ]; then
    KB_DIR=""
fi

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Repo URLs come as owner/name, https://github.com/owner/name[.git], or a
# follow-up's https://github.com/owner/name/tree/<branch>.
repo_path_of() {
    local path="${1%/}"
    path="${path#https://github.com/}"
    path=$(printf '%s' "$path" | cut -d/ -f1-2)
    printf '%s\n' "${path%.git}"
}

repo_url_branch() {
    local url="${1%/}"
    case "$url" in
        */tree/*) url="${url#*/tree/}"; printf '%s\n' "${url%%/*}" ;;
    esac
}

# The git remote to fetch from / push to for a repo URL.
git_remote_for() {
    printf '%s/%s.git\n' "$GIT_REMOTE_BASE" "$(repo_path_of "$1")"
}

if [ -z "${RESEARCHER_OUTPUT_DIR:-}" ] && [ ! -d "$HDD" ]; then
    echo "ERROR: storage root not mounted at ${HDD}." >&2
    echo "Set RESEARCHER_OUTPUT_DIR to use a different location." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Symlink logs and output into the plugin dir for convenience.
if is_true "$LINK_OUTPUT"; then
    ln -sfn "$OUTPUT_DIR" "${REPO_DIR}/output"
    ln -sfn "$LOG_DIR" "${REPO_DIR}/logs"
fi

log() { echo "$(date -Iseconds) $*"; }

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

case "$REPO_VISIBILITY" in
    private|internal|public) ;;
    *)
        log "ERROR: RESEARCHER_REPO_VISIBILITY must be private, internal or public, got '${REPO_VISIBILITY}'."
        exit 2
        ;;
esac

if ! command -v python3 &>/dev/null || [ ! -f "$LIB" ]; then
    log "ERROR: python3 and ${LIB} are required. Exiting."
    exit 1
fi

log "Agent backend: ${BACKEND}; model: ${MODEL}"

# Check if GPU is busy (>500MB VRAM used by any single process = busy)
if ! is_true "$SKIP_GPU_CHECK" && command -v nvidia-smi &>/dev/null; then
    GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null || true)
    if [ -n "$GPU_PROCS" ]; then
        MAX_MEM=$(echo "$GPU_PROCS" | awk -F', ' '{print $2}' | sort -n | tail -1)
        if [ "$MAX_MEM" -gt 500 ] 2>/dev/null; then
            log "GPU busy (process using ${MAX_MEM} MiB). Skipping this run."
            exit 0
        fi
    fi
fi

# --- Find or create run ---
RUN_DIR=""
ISSUE_NUMBER=""
IS_FOLLOWUP=false
PARENT_ISSUE=""
PRIOR_REPO_URL=""
PRIOR_RUN_ID=""
FEEDBACK=""
FOLLOWUP_KEY=""

is_terminal_status() {
    case "$1" in
        complete|failed|aborted_rethink|timed_out) return 0 ;;
        *) return 1 ;;
    esac
}

find_in_progress_run() {
    # Prints the run to resume on stdout; everything else goes to stderr.
    local state_file status mode
    # Runs live under machine-generated slug paths without whitespace.
    # shellcheck disable=SC2045
    for state_file in $(ls -1t "$OUTPUT_DIR"/*/state.md 2>/dev/null); do
        status=$(grep '^status:' "$state_file" | head -1 | awk '{print $2}')
        is_terminal_status "$status" && continue
        # An interactive /researcher run shares the output directory; cron must
        # never take one over.
        mode=$(grep '^mode:' "$state_file" | head -1 | awk '{print $2}')
        if [ -n "$mode" ] && [ "$mode" != "autonomous" ]; then
            continue
        fi
        if [ "$RESUME_MAX_AGE_DAYS" -gt 0 ] 2>/dev/null \
            && [ -n "$(find "$state_file" -mmin +"$(( RESUME_MAX_AGE_DAYS * 1440 ))" 2>/dev/null)" ]; then
            log "WARN: not resuming $(dirname "$state_file"): status '${status}', untouched for over ${RESUME_MAX_AGE_DAYS} days. Resume it by hand or set its status to failed." >&2
            continue
        fi
        dirname "$state_file"
        return 0
    done
    return 1
}

issue_is_claimed() {
    # Re-read the issue's labels right before claiming it: the listing may be
    # minutes old, and another runner (the other backend, another machine) may
    # have claimed it since. If it cannot be re-read, treat it as claimed:
    # skipping a night is cheap, a duplicate run is not.
    local number="$1" include_processed="$2" fresh
    fresh=$(gh issue view "$number" --repo "$TASKS_REPO" --json labels,state 2>/dev/null) || return 0
    echo "$fresh" | jq -e --arg p "$include_processed" '
        (.state != "OPEN") or
        (.labels | map(.name) | any(
            . == "status:claude-researching" or . == "status:codex-researching" or
            ($p == "true" and (. == "status:claude-processed" or . == "status:codex-processed"))
        ))' > /dev/null
}

pick_issue() {
    local picked
    if [ -n "${RESEARCHER_ISSUE:-}" ]; then
        # Explicit target: fetch it directly rather than filtering the queue
        # listing, so an issue older than the listing window still resolves.
        # Still refuses one already claimed, so two runs can't collide.
        local target gh_err gh_status
        gh_err="${TMPDIR:-/tmp}/researcher-gh-$$.err"
        target=$(gh issue view "$RESEARCHER_ISSUE" --repo "$TASKS_REPO" \
            --json number,title,body,labels,state 2>"$gh_err") && gh_status=0 || gh_status=$?
        if [ "$gh_status" -ne 0 ] || [ -z "$target" ]; then
            local gh_msg
            gh_msg=$(tr '\n' ' ' < "$gh_err")
            rm -f "$gh_err"
            # gh exits 1 both for "no such issue" and for transport/auth
            # failures; only the former is the user's mistake. Every case here
            # is fatal: unlike the queue path, an explicitly requested issue
            # that doesn't resolve means the run cannot do what was asked.
            if [ "$gh_status" -eq 0 ]; then
                log "ERROR: issue #${RESEARCHER_ISSUE} returned no data from ${TASKS_REPO}."
                exit 1
            fi
            case "$gh_msg" in
                *"Could not resolve to"*|*"Not Found"*|*"not found"*)
                    log "ERROR: issue #${RESEARCHER_ISSUE} not found in ${TASKS_REPO}."
                    ;;
                *)
                    log "ERROR: could not read issue #${RESEARCHER_ISSUE} (gh exit ${gh_status}): ${gh_msg:-no stderr}"
                    log "This is a gh/auth/network failure, not a missing issue. Check 'gh auth status'."
                    ;;
            esac
            exit 1
        fi
        rm -f "$gh_err"
        picked=$(echo "$target" | jq -c '
            select(.state == "OPEN")
            | select(.labels | map(.name) | index("list:research-ideas")) // empty')
        if [ -n "$picked" ]; then
            # Refuses an issue being researched right now or with a run already
            # in progress here; allows a deliberate re-run of a finished one.
            picked=$(echo "$picked" | python3 "$LIB" pick --explicit --output-dir "$OUTPUT_DIR")
        fi
        if [ -z "$picked" ] || [ "$picked" = "null" ]; then
            log "ERROR: issue #${RESEARCHER_ISSUE} is not an open, unclaimed list:research-ideas issue."
            exit 1
        fi
    else
    local issues allow_rerun_flag=()
    issues=$(gh issue list --repo "$TASKS_REPO" \
        --label "list:research-ideas" \
        --state open \
        --json number,title,body,labels \
        --limit 50)

    # Skips claimed/processed issues, issues already run on this machine, and
    # duplicate follow-up requests (tasks#1919/#1920 were the same request filed
    # twice and run on consecutive nights).
    is_true "$ALLOW_RERUN" && allow_rerun_flag=(--allow-rerun)
    picked=$(echo "$issues" | python3 "$LIB" pick --output-dir "$OUTPUT_DIR" ${allow_rerun_flag[@]+"${allow_rerun_flag[@]}"})
    fi

    if [ -z "$picked" ] || [ "$picked" = "null" ]; then
        log "No unprocessed research ideas found. Exiting."
        exit 0
    fi

    ISSUE_NUMBER=$(echo "$picked" | jq -r '.number')
    FOLLOWUP_KEY=$(echo "$picked" | jq -r '.followup_key // ""')
    local title body include_processed=true
    title=$(echo "$picked" | jq -r '.title')
    body=$(echo "$picked" | jq -r '.body // ""')

    [ -n "${RESEARCHER_ISSUE:-}" ] && include_processed=false
    if issue_is_claimed "$ISSUE_NUMBER" "$include_processed"; then
        log "Issue #${ISSUE_NUMBER} was claimed or closed by another runner since the listing (or could not be re-read). Exiting."
        exit 0
    fi

    log "Picked issue #${ISSUE_NUMBER}: ${title}"

    gh label create "$PROCESSING_LABEL" \
        --repo "$TASKS_REPO" \
        --color "0E8A16" \
        --description "Currently being researched by the ${BACKEND} autonomous agent" \
        2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo "$TASKS_REPO" --add-label "$PROCESSING_LABEL"

    TOPIC="$title"
    if [ -n "$body" ] && [ "$body" != "null" ]; then
        TOPIC="${title}

Context from issue body:
${body}"
    fi

    # Detect follow-up issues
    if echo "$picked" | jq -e '.labels[] | select(.name == "type:follow-up")' > /dev/null 2>&1; then
        IS_FOLLOWUP=true
        PRIOR_REPO_URL=$(echo "$body" | sed -n 's/.*Repo: \(https:\/\/[^ ]*\).*/\1/p' | head -1)
        PARENT_ISSUE=$(echo "$body" | sed -n 's/.*Parent: #\([0-9]*\).*/\1/p' | head -1)
        PRIOR_RUN_ID=$(echo "$body" | sed -n 's/.*Run: \([^ ]*\).*/\1/p' | head -1)
        # Feedback is the body minus the metadata footer
        FEEDBACK=$(echo "$body" | sed '/^---$/,$d')
        log "Follow-up detected. Parent: #${PARENT_ISSUE}, Prior repo: ${PRIOR_REPO_URL}"
    fi
}

write_gitignore() {
    # Written into every run directory, which is git-initialised in place at
    # publish time. A follow-up also ignores prior/ (the previous run's copied
    # artifacts, already in the repo it continues).
    local dir="$1"
    cat > "${dir}/.gitignore" << 'GIEOF'
# Model checkpoints and weights (GitHub 100MB hard limit)
*.pt
*.pth
*.bin
*.safetensors
*.ckpt
*.h5
*.onnx

# Python virtual environments
venv/
.venv/
env/

# Python bytecode
__pycache__/
*.pyc
*.pyo

# Training artifacts
wandb/
runs/
tensorboard/
*.tfevents*

# Large data files
*.tar
*.tar.gz
*.zip
*.hdf5
*.pkl
*.npy
*.npz
*.parquet
*.arrow

# OS / temp files
.DS_Store
Thumbs.db
*.tmp
*.bak
*.swp
GIEOF
    if [ -f "${dir}/followup-context.md" ] || [ -d "${dir}/prior" ]; then
        printf '\n# Previous run artifacts copied in for context (already in the repo)\n/prior/\n' >> "${dir}/.gitignore"
    fi
}

unique_run_id() {
    # A second run of the same topic on the same day must not inherit the
    # first one's experiments, paper and repo.
    local base="$1" candidate="$1" n=2
    while [ -e "${OUTPUT_DIR}/${candidate}" ]; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    printf '%s\n' "$candidate"
}

create_run_dir() {
    local slug date_prefix run_id
    date_prefix=$(date +%Y-%m-%d)
    slug=$(echo "$TOPIC" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 60)
    run_id=$(unique_run_id "${date_prefix}-${slug}")
    RUN_DIR="${OUTPUT_DIR}/${run_id}"

    mkdir -p "${RUN_DIR}/literature" "${RUN_DIR}/experiments" "${RUN_DIR}/challenge"

    cat > "${RUN_DIR}/state.md" << STATEEOF
---
run_id: ${run_id}
topic: "$(echo "$TOPIC" | head -1 | sed 's/"/\\"/g')"
current_step: 0
status: initialized
mode: autonomous
agent_backend: ${BACKEND}
agent_model: "${MODEL}"
issue_number: ${ISSUE_NUMBER:-none}
compute_profile: "${COMPUTE_PROFILE}"
knowledge_base: "${KB_DIR:-none}"
clarifications: []
decisions: []
---

Autonomous research run initialized.
Topic: $(echo "$TOPIC" | head -1)
STATEEOF

    echo "$TOPIC" > "${RUN_DIR}/topic.txt"

    write_gitignore "$RUN_DIR"

    log "Created run directory: ${RUN_DIR}"
}

setup_followup_run() {
    local date_prefix slug run_id
    date_prefix=$(date +%Y-%m-%d)
    slug=$(echo "$TOPIC" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 50)
    run_id=$(unique_run_id "${date_prefix}-followup-${slug}")
    RUN_DIR="${OUTPUT_DIR}/${run_id}"

    mkdir -p "${RUN_DIR}/literature" "${RUN_DIR}/experiments" "${RUN_DIR}/challenge" "${RUN_DIR}/prior"

    # Clone the prior repo and copy key artifacts. The clone goes on the output
    # volume, never /tmp: /tmp is on the small root disk.
    if [ -n "$PRIOR_REPO_URL" ]; then
        local tmp_clone
        mkdir -p "${OUTPUT_DIR}/.tmp"
        tmp_clone=$(mktemp -d "${OUTPUT_DIR}/.tmp/prior-clone.XXXXXX")
        log "Cloning prior repo ${PRIOR_REPO_URL} for context..."
        local prior_branch clone_args=(-q --depth 1)
        prior_branch=$(repo_url_branch "$PRIOR_REPO_URL")
        [ -n "$prior_branch" ] && clone_args+=(--branch "$prior_branch")
        if git clone "${clone_args[@]}" "$(git_remote_for "$PRIOR_REPO_URL")" "$tmp_clone" 2>>"${LOG_DIR}/gh-push.log" \
            && git -C "$tmp_clone" rev-parse -q --verify HEAD >/dev/null; then
            # Copy key prior artifacts
            [ -f "$tmp_clone/state.md" ] && cp "$tmp_clone/state.md" "${RUN_DIR}/prior/state.md"
            [ -f "$tmp_clone/briefing.md" ] && cp "$tmp_clone/briefing.md" "${RUN_DIR}/prior/briefing.md"
            [ -f "$tmp_clone/decomposition.md" ] && cp "$tmp_clone/decomposition.md" "${RUN_DIR}/prior/decomposition.md"
            [ -f "$tmp_clone/novelty-assessment.md" ] && cp "$tmp_clone/novelty-assessment.md" "${RUN_DIR}/prior/novelty-assessment.md"
            [ -f "$tmp_clone/success-criteria.md" ] && cp "$tmp_clone/success-criteria.md" "${RUN_DIR}/prior/success-criteria.md"
            [ -f "$tmp_clone/next-steps.md" ] && cp "$tmp_clone/next-steps.md" "${RUN_DIR}/prior/next-steps.md"
            [ -f "$tmp_clone/method-spec.md" ] && cp "$tmp_clone/method-spec.md" "${RUN_DIR}/prior/method-spec.md"
            [ -d "$tmp_clone/literature" ] && cp -r "$tmp_clone/literature" "${RUN_DIR}/prior/literature"
            [ -d "$tmp_clone/challenge" ] && cp -r "$tmp_clone/challenge" "${RUN_DIR}/prior/challenge"
            # The prior repo's own knowledge base — what this research line has
            # established, ruled out, and how to reproduce it. Carried forward and
            # extended at Step 11, not started from scratch.
            [ -d "$tmp_clone/knowledge" ] && cp -r "$tmp_clone/knowledge" "${RUN_DIR}/prior/knowledge"
            # Copy experiment results (not full code) to keep it lightweight
            if [ -d "$tmp_clone/experiments" ]; then
                mkdir -p "${RUN_DIR}/prior/experiments"
                for exp_dir in "$tmp_clone"/experiments/exp-*/; do
                    [ -d "$exp_dir" ] || continue
                    local exp_name
                    exp_name=$(basename "$exp_dir")
                    mkdir -p "${RUN_DIR}/prior/experiments/${exp_name}"
                    [ -f "${exp_dir}/results.md" ] && cp "${exp_dir}/results.md" "${RUN_DIR}/prior/experiments/${exp_name}/"
                    [ -f "${exp_dir}/plan.md" ] && cp "${exp_dir}/plan.md" "${RUN_DIR}/prior/experiments/${exp_name}/"
                done
            fi
            if [ -d "$tmp_clone/paper/sections" ]; then
                mkdir -p "${RUN_DIR}/prior/paper/sections"
                cp "$tmp_clone"/paper/sections/*.tex "${RUN_DIR}/prior/paper/sections/" 2>/dev/null || true
            fi
            log "Prior artifacts copied to ${RUN_DIR}/prior/"
        else
            log "WARN: Failed to clone ${PRIOR_REPO_URL} (unreachable or empty). Proceeding without prior context."
        fi
        rm -rf "$tmp_clone"
    fi

    # Write followup-context.md
    cat > "${RUN_DIR}/followup-context.md" << CTXEOF
---
is_followup: true
parent_issue: ${PARENT_ISSUE}
prior_repo: ${PRIOR_REPO_URL}
prior_run_id: ${PRIOR_RUN_ID}
---

## User Feedback

${FEEDBACK}
CTXEOF

    # Write topic.txt — original topic (from issue title, minus [Follow-up] prefix) + feedback
    local original_topic
    original_topic=$(echo "$TOPIC" | head -1 | sed 's/^\[Follow-up\] *//')
    {
        echo "$original_topic"
        echo
        echo "Follow-up feedback:"
        echo "$FEEDBACK"
    } > "${RUN_DIR}/topic.txt"

    # Write fresh state.md
    local original_topic_yaml
    original_topic_yaml=${original_topic//\"/\\\"}
    cat > "${RUN_DIR}/state.md" << STATEEOF
---
run_id: ${run_id}
topic: "${original_topic_yaml}"
current_step: 0
status: initialized
mode: autonomous
agent_backend: ${BACKEND}
agent_model: "${MODEL}"
issue_number: ${ISSUE_NUMBER:-none}
is_followup: true
parent_issue: ${PARENT_ISSUE:-none}
prior_repo: ${PRIOR_REPO_URL}
prior_run_id: ${PRIOR_RUN_ID}
followup_key: ${FOLLOWUP_KEY:-none}
compute_profile: "${COMPUTE_PROFILE}"
knowledge_base: "${KB_DIR:-none}"
clarifications: []
decisions: []
---

Follow-up research run initialized.
Topic: ${original_topic}
Parent issue: #${PARENT_ISSUE}
STATEEOF

    write_gitignore "$RUN_DIR"

    log "Follow-up run directory ready: ${RUN_DIR}"
}

# Check for in-progress run first
if IN_PROGRESS=$(find_in_progress_run); then
    RUN_DIR="$IN_PROGRESS"
    STORED_BACKEND=$(grep '^agent_backend:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}' || true)
    if [ -n "$STORED_BACKEND" ] \
        && [ "$STORED_BACKEND" != "$BACKEND" ] \
        && ! is_true "$ALLOW_BACKEND_SWITCH"; then
        log "ERROR: in-progress run uses backend '${STORED_BACKEND}', requested '${BACKEND}'."
        log "Resume with RESEARCHER_BACKEND=${STORED_BACKEND}, or set RESEARCHER_ALLOW_BACKEND_SWITCH=true deliberately."
        exit 2
    fi
    ISSUE_NUMBER=$(grep '^issue_number:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}' | tr -d "\"'" || true)
    [ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
    # Check if the in-progress run is a follow-up
    if grep -q '^is_followup: true' "${RUN_DIR}/state.md" 2>/dev/null; then
        IS_FOLLOWUP=true
        PRIOR_REPO_URL=$(grep '^prior_repo:' "${RUN_DIR}/state.md" | head -1 | sed 's/prior_repo: *//' || true)
        PARENT_ISSUE=$(grep '^parent_issue:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}' || true)
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
    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PRIOR_REPO_URL" ]; then
        setup_followup_run
    else
        create_run_dir
    fi
fi

# --- Step loop ---
START_TIME=$(date +%s)
# Bash-owned ceiling for the Step 10 audit-remediation loop, independent of any
# agent-written field — so a missing or garbage audit_round can never wedge the run.
AUDIT_ROUNDS=0

# Both read state.md written by a model; a missing key must not abort the
# wrapper under set -e (that skipped publishing and reporting silently).
get_current_step() {
    { grep '^current_step:' "${RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}'
}

get_status() {
    { grep '^status:' "${RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}'
}

yaml_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

upsert_frontmatter_field() {
    local key="$1"
    local value="$2"
    local state_file="${RUN_DIR}/state.md"
    local temp_file="${state_file}.runtime.tmp"

    if ! awk -v key="$key" -v value="$value" '
        BEGIN {
            delimiter_count = 0
            wrote_field = 0
        }
        /^[[:space:]]*---[[:space:]]*$/ {
            delimiter_count++
            if (delimiter_count == 2 && !wrote_field) {
                print key ": " value
                wrote_field = 1
            }
            print
            next
        }
        delimiter_count == 1 && index($0, key ":") == 1 {
            print key ": " value
            wrote_field = 1
            next
        }
        {
            print
        }
        END {
            if (delimiter_count < 2 || !wrote_field) {
                exit 65
            }
        }
    ' "$state_file" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$state_file"
}

ensure_runtime_state() {
    # These fields are owned by the wrapper, not by a model step. Restore them
    # after every provider call so resumability and compute limits do not depend
    # on an LLM preserving YAML keys during an otherwise valid state rewrite.
    upsert_frontmatter_field "agent_backend" "$BACKEND" \
        && upsert_frontmatter_field "run_id" "$(basename "$RUN_DIR")" \
        && upsert_frontmatter_field "mode" "autonomous" \
        && upsert_frontmatter_field "issue_number" "${ISSUE_NUMBER:-none}" \
        && upsert_frontmatter_field "agent_model" "$(yaml_quote "$MODEL")" \
        && upsert_frontmatter_field "compute_profile" "$(yaml_quote "$COMPUTE_PROFILE")" \
        && upsert_frontmatter_field "knowledge_base" "$(yaml_quote "${KB_DIR:-none}")"
}

set_status() {
    # Frontmatter only: a bare `sed s/^status:/` also rewrote any body line
    # that happened to start with "status:".
    upsert_frontmatter_field "status" "$1" \
        || sed -i.bak "s/^status:.*/status: $1/" "${RUN_DIR}/state.md"
}

build_codex_preamble() {
    cat <<EOF
# Codex Runtime Adapter

This workflow was authored with Claude Code vocabulary. Translate it to Codex
semantics rather than treating the pseudocode as literal shell or API syntax.

- A \`Task(...)\` block means: spawn a Codex leaf subagent, give it the complete
  prompt in the block, wait for it, and use its returned result.
- Keep leaf agents from spawning further agents or interacting with the user.
- Run explicitly parallel Task blocks concurrently and wait for all results.
- Map search-planner and search workers to model \`${CODEX_FAST_MODEL}\` with
  \`${CODEX_FAST_REASONING}\` reasoning when that override is available.
- Map novelty, criteria, decomposition, challenge, experiment, audit, and report
  workers to model \`${CODEX_DEEP_MODEL}\` with \`${CODEX_DEEP_REASONING}\`
  reasoning when that override is available.
- Translate Read/Write/Edit/Glob/Grep/Bash/WebSearch/WebFetch to the available
  Codex filesystem, shell, and web tools.
- The plugin-root placeholder has already been replaced with an absolute path.
- Execute exactly one autonomous workflow step and update state.md before exit.
EOF
}

build_runtime_header() {
    cat <<EOF
# Injected Runtime Configuration

- Agent backend: ${BACKEND}
- Parent model: ${MODEL}
- Plugin root: ${REPO_DIR}
- Run output root: ${OUTPUT_DIR}
- Global knowledge base: ${KB_DIR:-none (this run is not using one)}
EOF
}

# Strip a command file's YAML frontmatter, and NOTHING else.
#
# The obvious `sed '/^---$/,/^---$/d'` is wrong and was wrong here for a long
# time: sed pairs up EVERY `---` in the file, so with markdown section
# separators it deletes alternating sections of the document. That silently
# dropped half the workflow — including whole steps — from every step prompt.
# Match only the frontmatter: a `---` on line 1, up to the next `---`.
strip_frontmatter() {
    awk '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---"   { in_fm = 0; next }
        in_fm                  { next }
        { print }
    ' "$1"
}

build_step_prompt() {
    local step="$1"
    local cmd_file="${REPO_DIR}/commands/researcher-auto-step.md"
    local cmd_body
    cmd_body=$(strip_frontmatter "$cmd_file")
    build_runtime_header
    if [ "$BACKEND" = "codex" ]; then
        build_codex_preamble
    fi
    echo "$cmd_body" | sed "s|{{argument}}|${step} ${RUN_DIR}|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

build_email_prompt() {
    local cmd_file="${REPO_DIR}/commands/researcher-auto-email.md"
    local cmd_body
    cmd_body=$(strip_frontmatter "$cmd_file")
    build_runtime_header
    cat <<EOF

# Autonomous Email Handoff

- Compose only; do not send the email yourself.
- Write the HTML to: ${RUN_DIR}/email-draft.html
- Write the single-line subject to: ${RUN_DIR}/email-subject.txt
- The wrapper will send only to: ${EMAIL_TO}
- Footer agent label: ${AGENT_LABEL}

## Continuation facts (use these verbatim in "How to Continue This Research")

- Run host SSH alias: ${HOST_ALIAS}
  (If this is exactly \`local\`, the reader is already on the run machine: OMIT the
  ssh step and renumber. Otherwise the step is literally \`ssh ${HOST_ALIAS}\`.)
- Plugin directory on the run host: ${REPO_DIR}
- Run directory on the run host: ${RUN_DIR}
- Continue command: ${CONTINUE_COMMAND} ${RUN_DIR}
- Agent to start in the plugin directory: ${PROVIDER_BIN}

These are the real paths on the machine that produced this run. Use them exactly;
never substitute a placeholder, a guessed path, or a different hostname.

## Wrapper-verified outcome (authoritative; state it, never contradict it)

- Final outcome: ${FINAL_OUTCOME:-unknown}
- Workflow status: ${STATUS:-unknown}
- Published: $(if [ "${PUBLISH_STATE:-}" = "pushed" ]; then echo "yes, verified on GitHub (${PUBLISHED_VISIBILITY:-unknown visibility} repo): $(cat "${RUN_DIR}/.repo_url" 2>/dev/null)"; elif [ "${PUBLISH_STATE:-}" = "failed" ]; then echo "NO - ${PUBLISH_ERROR}. Say so near the top of the email and give no repo link."; else echo "no (publishing skipped for this run); give no repo link."; fi)
- Caveats:
${OUTCOME_REASONS:-  - none}

The full machine-readable outcome is in ${RUN_DIR}/run-outcome.json. If the
final outcome is anything other than \`complete\`, the email's first line must
say so plainly (e.g. "This run finished but its results are NOT on GitHub").
EOF
    echo "$cmd_body" | sed "s|{{argument}}|${RUN_DIR}|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

invoke_provider() {
    local purpose="$1"
    case "$BACKEND" in
        claude)
            local allowed_tools
            if [ "$purpose" = "step" ]; then
                allowed_tools="Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch,Task"
            else
                allowed_tools="Read,Write,Glob,Grep,Bash"
            fi
            "$PROVIDER_BIN" --print \
                --dangerously-skip-permissions \
                --model "$MODEL" \
                --allowedTools "$allowed_tools"
            ;;
        codex)
            local codex_args=(
                --search
                --ask-for-approval "$CODEX_APPROVAL_POLICY"
                exec
                --ephemeral
                --cd "$REPO_DIR"
                --add-dir "$OUTPUT_DIR"
                --sandbox "$CODEX_SANDBOX"
            )
            # The knowledge base lives outside the plugin and output roots, so
            # Codex cannot write to it unless it is explicitly granted.
            # (an `[ ... ] && ...` one-liner would return 1 with no KB and, under
            # set -e, abort the run rather than skip the flag)
            if [ -n "$KB_DIR" ]; then
                codex_args+=(--add-dir "$KB_DIR")
            fi
            codex_args+=(
                --model "$MODEL"
                -c "model_reasoning_effort=\"${CODEX_REASONING}\""
                -c "agents.default_subagent_model=\"${CODEX_DEEP_MODEL}\""
                -c "agents.default_subagent_reasoning_effort=\"${CODEX_DEEP_REASONING}\""
                -c "agents.max_concurrent_threads_per_session=${CODEX_MAX_SUBAGENTS}"
            )
            if is_true "$CODEX_IGNORE_USER_CONFIG"; then
                codex_args+=(--ignore-user-config)
            fi
            codex_args+=(-)
            "$PROVIDER_BIN" "${codex_args[@]}"
            ;;
    esac
}

run_step_provider() {
    local step="$1"
    build_step_prompt "$step" | invoke_provider step
}

run_email_provider() {
    build_email_prompt | invoke_provider email
}

outstanding_jobs() {
    [ -n "$JOB_WAIT_CMD" ] || return 0
    local cmd run_id
    run_id=$(basename "$RUN_DIR")
    cmd=${JOB_WAIT_CMD//\{run_id\}/$run_id}
    # A hook that exits non-zero when there is nothing to report (a bare
    # `squeue | grep`, the obvious thing to write) must mean "no jobs", not
    # "abort the run" — which is what pipefail would otherwise do here.
    ( set +e +o pipefail; eval "$cmd" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' ) || true
}

guard_hold() {
    [ -n "$GUARD_CMD" ] || return 0
    local cmd run_id
    run_id=$(basename "$RUN_DIR")
    cmd=${GUARD_CMD//\{run_id\}/$run_id}
    # Output decides, not the exit code: a guard that fails silently holds nothing.
    ( set +e +o pipefail; eval "$cmd" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 ) || true
}

run_step() {
    local step="$1"
    local prev_step
    prev_step=$(get_current_step)

    local attempt=0 refunds=0 total_waited=0
    local exit_code new_step new_status run_log
    while [ "$attempt" -lt "$STEP_MAX_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        run_log="${LOG_DIR}/step-${step}-attempt-${attempt}-$(date +%Y%m%d-%H%M%S).log"
        if [ "$attempt" -eq 1 ]; then
            log "Starting step ${step}..."
        else
            log "Retrying step ${step} (attempt ${attempt}/${STEP_MAX_ATTEMPTS}) after an incomplete run (e.g. a dropped connection)..."
            sleep "$RETRY_DELAY_SECONDS"
        fi

        cd "$REPO_DIR"
        set +e
        run_step_provider "$step" 2>&1 | tee "$run_log"
        exit_code=${PIPESTATUS[0]}
        set -e
        if ! ensure_runtime_state; then
            log "Step ${step} produced invalid state frontmatter; treating it as incomplete."
            exit_code=65
        fi
        new_step=$(get_current_step || true)
        new_status=$(get_status || true)

        # A provider usage/session cap is a pause, not a failure: retrying costs
        # nothing but the remaining attempts, and marking the run failed would
        # block find_in_progress_run from ever resuming it. Stop cleanly and
        # leave the state resumable — a later invocation continues this step.
        # Match only a provider-emitted limit notice: the CLI prints it as its
        # own final line. Scanning the whole transcript would misread a run that
        # merely *writes about* rate limits (e.g. authoring retry logic) as a
        # pause, and such a step would then loop forever, never failing.
        # Both known CLI forms count: the human one ("You've hit your session
        # limit · resets 8pm") and the headless one ("Claude AI usage limit
        # reached|1754060400"). Neither the exit code nor a reset clause is
        # required — the CLI can print the notice and still exit 0.
        # Transient "rate limit exceeded" errors are deliberately excluded:
        # those are retryable, and the retry loop is the right response.
        # Detected BEFORE the success gate: a notice with exit 0 must never
        # pass for a completed audit round (Step 10 keeps current_step at 10).
        local last_line limit_hit=false
        last_line=$({ grep -v '^[[:space:]]*$' "$run_log" || true; } | tail -1)
        if printf '%s\n' "$last_line" | grep -qE "^[[:space:]]*(You've hit your (session|usage) limit\b|(Claude )?(AI )?[Uu]sage limit reached\b)"; then
            limit_hit=true
        fi

        # Success = the step advanced, reached a genuine terminal status, OR (for the
        # audit step, which by design keeps current_step at 10 across rounds) the round
        # actually completed. We proxy "completed" with a clean provider exit and no
        # limit notice: a dropped connection exits non-zero AND leaves the status
        # unchanged, so without this gate a drop during Step 10 would return success
        # here and silently burn an AUDIT_ROUNDS increment upstream instead of retrying.
        if [ "$new_step" != "$prev_step" ] \
            || [ "$new_status" = "complete" ] || [ "$new_status" = "failed" ] \
            || { [ "$limit_hit" = false ] \
                 && [ "$exit_code" -eq 0 ] \
                 && [ "$step" -eq 10 ] \
                 && { [ "$new_status" = "audit_remediating" ] || [ "$new_status" = "audit_complete" ]; }; }; then
            log "Step ${step} completed. State now at step ${new_step}, status: ${new_status}"
            return 0
        fi

        if [ "$limit_hit" = true ]; then
            log "Step ${step} stopped: provider usage/session limit reached."
            log "${last_line}"
            log "Run left resumable at step ${prev_step} (status: ${new_status}). Re-run this script after the limit resets."
            return 2
        fi

        # An agent that submitted cluster work and ended its turn while that work
        # is still queued or running has not failed — it is waiting. Spending
        # attempts here is how a run gets marked failed while its results are
        # still being computed (or, worse, an hour after they landed).
        if [ -n "$JOB_WAIT_CMD" ] && [ "$refunds" -lt "$JOB_WAIT_MAX_REFUNDS" ]; then
            local outstanding waited
            outstanding=$(outstanding_jobs)
            if [ -n "${outstanding// /}" ]; then
                log "Step ${step}: external job(s) still outstanding (${outstanding% }); waiting rather than spending an attempt."
                waited=0
                # The cap is the step's CUMULATIVE wait budget across refunds,
                # not per wait, so waiting can never outrun the run timeout.
                while [ -n "${outstanding// /}" ] \
                    && [ "$total_waited" -lt "$JOB_WAIT_MAX_SECONDS" ] \
                    && [ $(( $(date +%s) - START_TIME )) -lt "$TIMEOUT_SECONDS" ]; do
                    sleep "$JOB_WAIT_POLL_SECONDS"
                    waited=$((waited + JOB_WAIT_POLL_SECONDS))
                    total_waited=$((total_waited + JOB_WAIT_POLL_SECONDS))
                    outstanding=$(outstanding_jobs)
                done
                if [ -n "${outstanding// /}" ]; then
                    log "Step ${step}: job(s) still outstanding after ${waited}s (cumulative ${total_waited}s of ${JOB_WAIT_MAX_SECONDS}s, run timeout ${TIMEOUT_SECONDS}s); giving up on waiting."
                else
                    refunds=$((refunds + 1))
                    attempt=$((attempt - 1))
                    log "Step ${step}: external job(s) finished after ~${waited}s; retrying without spending an attempt (refund ${refunds}/${JOB_WAIT_MAX_REFUNDS})."
                    continue
                fi
            fi
        fi

        log "Step ${step} did not advance state (still at step ${prev_step}, exit ${exit_code}, attempt ${attempt}/${STEP_MAX_ATTEMPTS})."

        # A step may end on purpose without advancing because the guard now
        # holds the run (e.g. it asked for more budget): pause, don't retry.
        local hold
        hold=$(guard_hold)
        if [ -n "$hold" ] && [ -z "$(outstanding_jobs | tr -d ' ')" ]; then
            log "Guard: ${hold}"
            upsert_frontmatter_field "last_pause_reason" "$(yaml_quote "$hold")" || true
            return 2
        fi
    done

    log "Step ${step} failed after ${STEP_MAX_ATTEMPTS} attempts. Marking run failed."
    set_status failed
    return 1
}

pause_run() {
    # Paused on a provider limit, not finished: publishing a partial repo,
    # emailing a non-result, and marking the issue processed would all be
    # wrong, and would strand the run. Leave everything resumable.
    log "Run PAUSED at step $1. Skipping repo publish, email, and issue update."
    log "Resume with the same command once the provider limit resets."
    SKIP_PUBLISH=true
    SKIP_EMAIL=true
    PAUSED=true
}

# A timeout is recorded in state.md, so a run paused during its timeout
# fast-track still reports the skipped audit when it is resumed.
TIMED_OUT=false
grep -q '^timed_out: true' "${RUN_DIR}/state.md" && TIMED_OUT=true

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
        upsert_frontmatter_field "timed_out" "true" || true
        log "Timeout (${TIMEOUT_SECONDS}s) reached at step ${CURRENT_STEP}."
        STEP_RC=0
        if [ "$CURRENT_STEP" -ge 5 ]; then
            # Bypass the audit (Step 10) on a timed-out run — never re-enter a
            # multi-hour remediation re-run — and compile whatever exists (Step 11).
            log "Skipping the results audit and compiling the report from what exists."
            # current_step too, so a pause inside Step 11 resumes at Step 11
            # rather than re-running the remaining steps and the audit.
            upsert_frontmatter_field "current_step" "10" || true
            set_status audit_complete
            run_step 11 || STEP_RC=$?
        fi
        if [ "$STEP_RC" -eq 2 ]; then
            pause_run 11
        elif [ "$(get_status)" != "complete" ]; then
            # Only a run whose report did NOT complete is marked timed out. A
            # finished report keeps status complete: the timeout used to
            # overwrite finished runs to "failed" (tasks#1874).
            set_status timed_out
        fi
        break
    fi

    # Audit-remediation re-entry: stay on Step 10 while the auditor asks for another
    # round. AUDIT_ROUNDS (bash-owned) is the authoritative ceiling — no agent field needed.
    if [ "$CURRENT_STEP" -eq 10 ] && [ "$STATUS" = "audit_remediating" ]; then
        AUDIT_ROUNDS=$((AUDIT_ROUNDS + 1))
        if [ "$AUDIT_ROUNDS" -ge 4 ]; then
            # Hand over to the report like any other audit exit; the report's
            # own success or failure then decides the status. (Forcing
            # "complete" here used to mark runs complete whose report failed.)
            log "Audit-remediation ceiling reached (${AUDIT_ROUNDS} rounds). Forcing the report."
            set_status audit_complete
            continue
        fi
        NEXT_STEP=10
    else
        AUDIT_ROUNDS=0
        NEXT_STEP=$((CURRENT_STEP + 1))
        [ "$CURRENT_STEP" -eq 0 ] && NEXT_STEP=1
    fi

    if [ "$NEXT_STEP" -gt 11 ]; then
        log "All steps completed."
        # Step 11 advanced current_step but left a non-terminal status.
        set_status complete
        break
    fi

    HOLD=$(guard_hold)
    if [ -n "$HOLD" ]; then
        OUTSTANDING=$(outstanding_jobs)
        if [ -n "${OUTSTANDING// /}" ]; then
            # Pausing now would leave this run's cluster jobs unwatched (and a
            # paid one billing); the step that collects them goes ahead.
            log "Guard asked to hold (${HOLD}), but job(s) ${OUTSTANDING% } are still outstanding; carrying on."
        else
            log "Guard: ${HOLD}"
            upsert_frontmatter_field "last_pause_reason" "$(yaml_quote "$HOLD")" || true
            pause_run "$NEXT_STEP"
            break
        fi
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
RUN_ID=$({ grep '^run_id:' "${RUN_DIR}/state.md" || true; } | head -1 | sed 's/run_id: *//')
[ -n "$RUN_ID" ] || RUN_ID=$(basename "$RUN_DIR")
TOPIC_LINE=$({ grep '^topic:' "${RUN_DIR}/state.md" || true; } | head -1 | sed 's/topic: *"*//;s/"*$//')
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

publish_fail() {
    PUBLISH_STATE="failed"
    PUBLISH_ERROR="$1"
    log "ERROR: publishing failed: $1. Results remain local in ${RUN_DIR}; no repo link will be advertised."
}

free_mb() {
    df -Pm "$1" 2>/dev/null | awk 'NR == 2 {print $4}'
}

check_free_space() {
    local free
    free=$(free_mb "$RUN_DIR")
    if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_MB" ] 2>/dev/null; then
        publish_fail "disk nearly full: ${free} MB free on the run volume, publishing needs ${MIN_FREE_MB} MB"
        return 1
    fi
}

prepare_local_repo() {
    # Run inside RUN_DIR. Sets up the repo, the branch and the remote, and keeps
    # wrapper bookkeeping and oversized files out of the commit.
    local branch="$1" remote="$2"
    [ -d .git ] || git init -q
    if git rev-parse -q --verify HEAD >/dev/null; then
        git branch -M "$branch"
    else
        # Name the unborn branch explicitly. Relying on git's default branch
        # name is what left 14 repos empty: runs committed on 'master' and
        # pushed 'main' ("src refspec main does not match any").
        git symbolic-ref HEAD "refs/heads/${branch}"
    fi
    git remote remove origin 2>/dev/null || true
    git remote add origin "$remote"
    load_exclude_notes
    [ -f .gitignore ] || write_gitignore "$RUN_DIR"
    local exclude=".git/info/exclude"
    mkdir -p .git/info
    grep -qxF '/.repo_url' "$exclude" 2>/dev/null \
        || printf '%s\n' '/.repo_url' '/.publish_repo' '/.publish_branch' '/run-outcome.json' '*.runtime.tmp' >> "$exclude"
}

exclude_with_note() {
    # Keep a path out of the commit, and remember why next to the pattern so a
    # later re-publish (when the path is already ignored) still reports it.
    # One line each: a newline in a file name must not leak into a pattern.
    local note pattern
    note=$(printf '%s' "$2" | tr '\n\r' '  ')
    # Escape glob characters first; only then turn newlines into `?` wildcards.
    pattern=$(printf '%s' "$1" | sed 's/[][*?\\!#]/\\&/g' | tr '\n\r' '??')
    printf '# researcher-note: %s\n' "$note" >> .git/info/exclude
    printf '%s\n' "$pattern" >> .git/info/exclude
    PUBLISH_NOTES+=("$note")
}

load_exclude_notes() {
    local line
    [ -f .git/info/exclude ] || return 0
    while IFS= read -r line; do
        case "$line" in
            "# researcher-note: "*) PUBLISH_NOTES+=("${line#\# researcher-note: }") ;;
        esac
    done < .git/info/exclude
}

exclude_large_files() {
    # GitHub rejects any file over 100 MB, and one such file fails the whole
    # push. Leave oversized files out of the commit (they stay on disk) rather
    # than lose the publication.
    local file bytes limit=$(( MAX_FILE_MB * 1024 * 1024 ))
    while IFS= read -r -d '' file; do
        [ -f "$file" ] || continue
        bytes=$(wc -c < "$file" | tr -d ' ')
        if [ "$bytes" -ge "$limit" ]; then
            exclude_with_note "/${file}" "${file} not published: $(( bytes / 1048576 )) MB is over the ${MAX_FILE_MB} MB limit; it is only in the run directory"
            log "WARN: not publishing ${file} ($(( bytes / 1048576 )) MB, limit ${MAX_FILE_MB} MB); it stays in the run directory."
        fi
    done < <(git ls-files --others --modified --exclude-standard -z)
}

commit_all() {
    # $1: add mode ("all" stages deletions; "overlay" keeps files only the
    # remote base has). Returns non-zero unless every change is committed.
    local add_args=(-A)
    [ "$1" = "overlay" ] && add_args=(--ignore-removal .)
    if ! git add "${add_args[@]}"; then
        publish_fail "git add failed (disk full?)"
        return 1
    fi
    git commit -q -m "$2" || true
    local leftover
    leftover=$(git status --porcelain)
    if [ "$1" = "overlay" ]; then
        # Files only the base branch has show as deleted here, by design.
        leftover=$(printf '%s\n' "$leftover" | grep -v '^ D ' || true)
    fi
    if ! git rev-parse -q --verify HEAD >/dev/null || [ -n "$leftover" ]; then
        publish_fail "git commit failed; the run directory is not fully committed (disk full?)"
        return 1
    fi
}

push_and_verify() {
    # Success means the remote branch now points at exactly our HEAD — not
    # just that git push exited 0, and not that the repo is non-empty.
    local branch="$1" head remote_head
    head=$(git rev-parse HEAD)
    if ! git push origin "HEAD:refs/heads/${branch}" 2>&1 | tee -a "${LOG_DIR}/gh-push.log"; then
        publish_fail "git push of ${branch} failed (see ${LOG_DIR}/gh-push.log)"
        return 1
    fi
    remote_head=$(git ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
    if [ "$remote_head" != "$head" ]; then
        publish_fail "push reported success but remote ${branch} is '${remote_head:-missing}', expected ${head}"
        return 1
    fi
}

repo_visibility() {
    # private / public / internal, or nothing when the repo cannot be read.
    gh repo view "$1" --json visibility --jq '.visibility' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

repo_state() {
    # absent | empty | content
    local empty
    empty=$(gh repo view "$1" --json isEmpty --jq '.isEmpty' 2>/dev/null) || { echo absent; return 0; }
    if [ "$empty" = "true" ]; then echo empty; else echo content; fi
}

choose_repo_slug() {
    # Prints the first usable name: one that does not exist yet, or an empty
    # repo that already has the requested visibility. Never another run's
    # repo (the push would be rejected), and never an empty repo left public
    # by the old master/main bug (results would go public while every report
    # said private). Diagnostics go to stderr.
    local slug="$1" candidate state vis
    for candidate in "$slug" "${slug}-$(echo "$RUN_ID" | cut -c1-10 | tr -d '-')" "${slug}-$(date +%H%M%S)"; do
        state=$(repo_state "${REPO_OWNER}/${candidate}")
        case "$state" in
            absent) printf '%s\n' "$candidate"; return 0 ;;
            empty)
                vis=$(repo_visibility "${REPO_OWNER}/${candidate}")
                if [ "$vis" = "$REPO_VISIBILITY" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                log "WARN: ${REPO_OWNER}/${candidate} exists (empty, ${vis:-unknown visibility}, not ${REPO_VISIBILITY}); not reusing it." >&2
                ;;
            *) log "WARN: ${REPO_OWNER}/${candidate} already holds another run; trying a new name." >&2 ;;
        esac
    done
    return 1
}

exclude_nested_repos() {
    # A git repository inside the run (a cloned library, an agent's own
    # `git init`) cannot be committed as files: git records it as a bare
    # pointer, or fails outright. Leave it out and say so.
    local nested dir
    while IFS= read -r -d '' nested; do
        dir=$(dirname "${nested#./}")
        git check-ignore -q "$dir" 2>/dev/null && continue
        exclude_with_note "/${dir}/" "${dir}/ not published: it is a separate git repository inside the run directory"
        log "WARN: not publishing ${dir}/: it is a separate git repository inside the run."
    done < <(find . -path ./.git -prune -o -name .git -prune -print0 2>/dev/null)
}

publish_new_repo() {
    local slug topic_slug repo_desc vis
    if [ -s "${RUN_DIR}/.publish_repo" ]; then
        # Re-publishing this run: reuse the repo it already created.
        slug=$(cat "${RUN_DIR}/.publish_repo")
    else
        # Truncate at word boundary (max ~40 chars for the topic portion)
        topic_slug=$(echo "$TOPIC_LINE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
        if [ "${#topic_slug}" -gt 40 ]; then
            # Cut to 40 chars, then drop the partial word the cut left behind.
            topic_slug=$(echo "$topic_slug" | head -c 40 | sed 's/-[^-]*$//')
        fi
        if ! slug=$(choose_repo_slug "research-${topic_slug}"); then
            publish_fail "no free repo name for research-${topic_slug} (all candidates hold other runs or have the wrong visibility)"
            return 1
        fi
    fi

    log "Publishing to GitHub repo ${REPO_OWNER}/${slug} (${REPO_VISIBILITY})"

    # GitHub caps repo descriptions at 350 chars; the topic can be far longer (a whole
    # paragraph), which makes `gh repo create` fail with a 422. Truncate to stay under.
    repo_desc="AI safety research (autonomous): ${TOPIC_LINE}"
    repo_desc="$(printf '%s' "$repo_desc" | tr '\n' ' ' | head -c 300)"

    # Non-zero when the repo already exists (a re-publish), which is fine:
    # the visibility check and push-and-verify below decide.
    gh repo create "${REPO_OWNER}/${slug}" "--${REPO_VISIBILITY}" --description "$repo_desc" 2>&1 \
        | tee -a "${LOG_DIR}/gh-repo-create.log" \
        || log "WARN: gh repo create returned non-zero for ${REPO_OWNER}/${slug} (may already exist)."
    printf '%s\n' "$slug" > "${RUN_DIR}/.publish_repo"

    vis=$(repo_visibility "${REPO_OWNER}/${slug}")
    if [ "$vis" != "$REPO_VISIBILITY" ]; then
        publish_fail "${REPO_OWNER}/${slug} is ${vis:-unreadable}, not ${REPO_VISIBILITY}; not pushing (to publish under a new name instead, delete ${RUN_DIR}/.publish_repo)"
        return 1
    fi
    PUBLISHED_VISIBILITY="$vis"

    # Generate README
    local abstract=""
    if [ -f "${RUN_DIR}/paper/sections/abstract.tex" ]; then
        abstract=$(sed 's/\\[a-zA-Z]*{[^}]*}//g; s/\\[a-zA-Z]*//g; s/[{}]//g' "${RUN_DIR}/paper/sections/abstract.tex" | head -20)
    fi

    cat > "${RUN_DIR}/README.md" << READMEEOF
# ${TOPIC_LINE}

**Status**: ${STATUS}
**Run ID**: ${RUN_ID}
**Mode**: Autonomous research
**Agent**: ${AGENT_LABEL}

## Summary

${abstract:-See paper/ directory for full results.}

## Structure

- \`paper/\` — LaTeX paper and compiled PDF
- \`literature/\` — Literature review artifacts
- \`experiments/\` — Experiment code, results and pre-flight checks
- \`challenge/\` — Adversarial review (assumptions, mentor-review, pre-mortem)
- \`decomposition.md\` — Steinhardt fail-fast decomposition
- \`next-steps.md\` — Ranked next round
- \`state.md\` — Workflow state log

---

*Generated by the autonomous AI safety researcher agent.*
READMEEOF

    REPO_BRANCH="main"
    cd "$RUN_DIR"
    prepare_local_repo "$REPO_BRANCH" "$(git_remote_for "${REPO_OWNER}/${slug}")"
    exclude_nested_repos
    exclude_large_files
    if commit_all all "$(cat <<COMMITEOF
Research artifacts: ${TOPIC_LINE}

Autonomous research run (${STATUS}).
Run ID: ${RUN_ID}

${COMMIT_ATTRIBUTION}
COMMITEOF
)" && push_and_verify "$REPO_BRANCH"; then
        PUBLISH_STATE="pushed"
        REPO_WEB="https://github.com/${REPO_OWNER}/${slug}"
        echo "$REPO_WEB" > "${RUN_DIR}/.repo_url"
        log "GitHub repo pushed and verified: ${REPO_WEB}"
    fi
    cd "$REPO_DIR"
}

publish_followup() {
    # Follow-ups push a new branch to the existing repo, in place: the branch
    # starts from the branch the follow-up continues (the prior repo's default
    # branch, or the /tree/<branch> a follow-up of a follow-up names) and this
    # run's files are laid over it. Nothing is copied — the old version cloned
    # the prior repo into /tmp and copied the whole run into it, which filled
    # the root disk and lost both 2026-04 follow-ups (tasks#1919/#1920).
    local branch prior_path base_branch vis
    prior_path=$(repo_path_of "$PRIOR_REPO_URL")
    base_branch=$(repo_url_branch "$PRIOR_REPO_URL")
    if [ -s "${RUN_DIR}/.publish_branch" ]; then
        branch=$(cat "${RUN_DIR}/.publish_branch")
    else
        branch="followup-$(date +%Y-%m-%d)-$(echo "$RUN_ID" | tail -c 20 | sed 's/^-//')"
    fi
    REPO_BRANCH="$branch"

    # The prior repo's visibility is not ours to choose. Pushing private-mode
    # results into a public repo would publish them, so refuse and say how.
    vis=$(repo_visibility "$prior_path")
    if [ "$vis" != "$REPO_VISIBILITY" ]; then
        publish_fail "the prior repo ${prior_path} is ${vis:-unreadable} but RESEARCHER_REPO_VISIBILITY is ${REPO_VISIBILITY}, so the follow-up was not pushed there; push it by hand, or re-run with RESEARCHER_REPO_VISIBILITY=${vis:-<visibility>} if that is intended"
        return 1
    fi
    PUBLISHED_VISIBILITY="$vis"

    log "Publishing follow-up results to https://github.com/${prior_path} on branch ${branch} (based on ${base_branch:-its default branch})"
    cd "$RUN_DIR"
    printf '%s\n' "$branch" > .publish_branch
    prepare_local_repo "$branch" "$(git_remote_for "$prior_path")"
    if ! git rev-parse -q --verify HEAD >/dev/null; then
        if git fetch -q --depth 1 origin "${base_branch:-HEAD}" 2>>"${LOG_DIR}/gh-push.log"; then
            # Index = the prior tree; the working tree (this run) is untouched.
            git reset -q --mixed FETCH_HEAD
        else
            local refs
            if ! refs=$(git ls-remote origin 2>/dev/null); then
                publish_fail "could not reach ${prior_path}"
                cd "$REPO_DIR"
                return 1
            elif [ -n "$refs" ]; then
                # Reachable with history, yet the base would not fetch: an
                # orphan branch would cut the line's history, so stop here.
                publish_fail "could not fetch ${base_branch:-the default branch} of ${prior_path}"
                cd "$REPO_DIR"
                return 1
            fi
            log "WARN: ${prior_path} is empty; the branch will hold only this run's files."
        fi
    fi
    exclude_nested_repos
    exclude_large_files
    if commit_all overlay "$(cat <<COMMITEOF
Follow-up research: ${TOPIC_LINE}

Follow-up run (${STATUS}).
Run ID: ${RUN_ID}
Parent issue: #${PARENT_ISSUE}

${COMMIT_ATTRIBUTION}
COMMITEOF
)" && push_and_verify "$branch"; then
        PUBLISH_STATE="pushed"
        REPO_WEB="https://github.com/${prior_path}"
        echo "${REPO_WEB}/tree/${branch}" > "${RUN_DIR}/.repo_url"
        log "Follow-up pushed and verified: ${REPO_WEB}/tree/${branch}"
    fi
    cd "$REPO_DIR"
}

publish_run() {
    # A stale link from an earlier attempt must never outlive a failed one.
    rm -f "${RUN_DIR}/.repo_url"
    check_free_space || return 0
    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PRIOR_REPO_URL" ]; then
        publish_followup
    else
        publish_new_repo
    fi
}

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
        '{outcome: "unknown", status: $s, publish_state: $p, reasons: ["the outcome could not be computed; see the cron log"]}')
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

outcome_is_success() {
    case "$FINAL_OUTCOME" in
        complete|complete-local) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Post-completion: Send email ---
send_email() {
    local email_log compose_status send_status subject
    email_log="${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S).log"
    log "Composing results email with ${BACKEND}..."
    cd "$REPO_DIR"
    rm -f "${RUN_DIR}/email-draft.html" "${RUN_DIR}/email-subject.txt"
    set +e
    run_email_provider 2>&1 | tee "$email_log"
    compose_status=${PIPESTATUS[0]}
    set -e

    if [ "$compose_status" -ne 0 ]; then
        log "Note: email composition failed with provider exit ${compose_status}."
        return 1
    fi
    if [ ! -s "${RUN_DIR}/email-draft.html" ] || [ ! -s "${RUN_DIR}/email-subject.txt" ]; then
        log "Note: email composer did not produce email-draft.html and email-subject.txt."
        return 1
    fi
    if [ ! -f "$SEND_EMAIL_SCRIPT" ]; then
        log "Note: shared email helper not found at ${SEND_EMAIL_SCRIPT}; draft retained."
        return 1
    fi

    subject=$(head -1 "${RUN_DIR}/email-subject.txt")
    if ! outcome_is_success; then
        # Deterministic, whatever the composer wrote: an unpublished or
        # result-less run is visible from the inbox.
        subject="[$(printf '%s' "$FINAL_OUTCOME" | tr '[:lower:]' '[:upper:]')] ${subject}"
    fi
    set +e
    python3 "$SEND_EMAIL_SCRIPT" \
        --to "$EMAIL_TO" \
        --subject "$subject" \
        --html "${RUN_DIR}/email-draft.html" \
        --label "$EMAIL_LABEL" \
        2>&1 | tee -a "$email_log"
    send_status=${PIPESTATUS[0]}
    set -e
    if [ "$send_status" -ne 0 ]; then
        log "Note: email helper failed with exit ${send_status}; draft retained."
        return 1
    fi
    log "Email sent to ${EMAIL_TO}."
}

if is_true "$SKIP_EMAIL"; then
    log "Skipping email (RESEARCHER_SKIP_EMAIL=${SKIP_EMAIL})."
else
    send_email || log "Note: email did not send. Results remain in ${RUN_DIR}."
fi

# --- Post-completion: report back on the GitHub issue ---
post_issue_comment() {
    local number="$1" body_file="$2"
    gh issue comment "$number" --repo "$TASKS_REPO" --body-file "$body_file" >/dev/null \
        || log "WARN: could not comment on issue #${number}."
}

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

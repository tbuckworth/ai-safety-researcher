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

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
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

find_in_progress_run() {
    # Runs live under machine-generated slug paths without whitespace.
    # shellcheck disable=SC2045
    for state_file in $(ls -1t "$OUTPUT_DIR"/*/state.md 2>/dev/null); do
        local status
        status=$(grep '^status:' "$state_file" | head -1 | awk '{print $2}')
        if [ "$status" != "complete" ] && [ "$status" != "failed" ] && [ "$status" != "aborted_rethink" ]; then
            dirname "$state_file"
            return 0
        fi
    done
    return 1
}

pick_issue() {
    local picked
    if [ -n "${RESEARCHER_ISSUE:-}" ]; then
        # Explicit target: fetch it directly rather than filtering the queue
        # listing, so an issue older than the listing window still resolves.
        # Still refuses one already claimed, so two runs can't collide.
        local target gh_err gh_status
        gh_err="${TMPDIR:-/tmp}/researcher-gh-$$.err"
        target=$(gh issue view "$RESEARCHER_ISSUE" --repo tbuckworth/tasks \
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
                log "ERROR: issue #${RESEARCHER_ISSUE} returned no data from tbuckworth/tasks."
                exit 1
            fi
            case "$gh_msg" in
                *"Could not resolve to"*|*"Not Found"*|*"not found"*)
                    log "ERROR: issue #${RESEARCHER_ISSUE} not found in tbuckworth/tasks."
                    ;;
                *)
                    log "ERROR: could not read issue #${RESEARCHER_ISSUE} (gh exit ${gh_status}): ${gh_msg:-no stderr}"
                    log "This is a gh/auth/network failure, not a missing issue. Check 'gh auth status'."
                    ;;
            esac
            exit 1
        fi
        rm -f "$gh_err"
        picked=$(echo "$target" | jq -r '
            select(.state == "OPEN")
            | select(.labels | map(.name) | index("list:research-ideas"))
            | select(
                (.labels | map(.name) | index("status:claude-researching") | not) and
                (.labels | map(.name) | index("status:codex-researching") | not)
              ) // empty')
        if [ -z "$picked" ] || [ "$picked" = "null" ]; then
            log "ERROR: issue #${RESEARCHER_ISSUE} is not an open, unclaimed list:research-ideas issue."
            exit 1
        fi
    else
    local issues
    issues=$(gh issue list --repo tbuckworth/tasks \
        --label "list:research-ideas" \
        --state open \
        --json number,title,body,labels \
        --limit 50)

    picked=$(echo "$issues" | jq -r '
        [.[] | select(
            (.labels | map(.name) | index("status:claude-researching") | not) and
            (.labels | map(.name) | index("status:claude-processed") | not) and
            (.labels | map(.name) | index("status:codex-researching") | not) and
            (.labels | map(.name) | index("status:codex-processed") | not)
        )] | first // empty')
    fi

    if [ -z "$picked" ] || [ "$picked" = "null" ]; then
        log "No unprocessed research ideas found. Exiting."
        exit 0
    fi

    ISSUE_NUMBER=$(echo "$picked" | jq -r '.number')
    local title body
    title=$(echo "$picked" | jq -r '.title')
    body=$(echo "$picked" | jq -r '.body // ""')

    log "Picked issue #${ISSUE_NUMBER}: ${title}"

    gh label create "$PROCESSING_LABEL" \
        --repo tbuckworth/tasks \
        --color "0E8A16" \
        --description "Currently being researched by the ${BACKEND} autonomous agent" \
        2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks --add-label "$PROCESSING_LABEL"

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

create_run_dir() {
    local slug date_prefix run_id
    date_prefix=$(date +%Y-%m-%d)
    slug=$(echo "$TOPIC" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 60)
    run_id="${date_prefix}-${slug}"
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
clarifications: []
decisions: []
---

Autonomous research run initialized.
Topic: $(echo "$TOPIC" | head -1)
STATEEOF

    echo "$TOPIC" > "${RUN_DIR}/topic.txt"

    # .gitignore for when we git-init this directory later
    cat > "${RUN_DIR}/.gitignore" << 'GIEOF'
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

    log "Created run directory: ${RUN_DIR}"
}

setup_followup_run() {
    local date_prefix slug run_id
    date_prefix=$(date +%Y-%m-%d)
    slug=$(echo "$TOPIC" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 50)
    run_id="${date_prefix}-followup-${slug}"
    RUN_DIR="${OUTPUT_DIR}/${run_id}"

    mkdir -p "${RUN_DIR}/literature" "${RUN_DIR}/experiments" "${RUN_DIR}/challenge" "${RUN_DIR}/prior"

    # Clone the prior repo into a temp dir and copy key artifacts
    if [ -n "$PRIOR_REPO_URL" ]; then
        local tmp_clone
        tmp_clone=$(mktemp -d)
        log "Cloning prior repo ${PRIOR_REPO_URL} for context..."
        if gh repo clone "$PRIOR_REPO_URL" "$tmp_clone" -- --depth 1 2>/dev/null; then
            # Copy key prior artifacts
            [ -f "$tmp_clone/state.md" ] && cp "$tmp_clone/state.md" "${RUN_DIR}/prior/state.md"
            [ -f "$tmp_clone/briefing.md" ] && cp "$tmp_clone/briefing.md" "${RUN_DIR}/prior/briefing.md"
            [ -f "$tmp_clone/decomposition.md" ] && cp "$tmp_clone/decomposition.md" "${RUN_DIR}/prior/decomposition.md"
            [ -f "$tmp_clone/novelty-assessment.md" ] && cp "$tmp_clone/novelty-assessment.md" "${RUN_DIR}/prior/novelty-assessment.md"
            [ -f "$tmp_clone/success-criteria.md" ] && cp "$tmp_clone/success-criteria.md" "${RUN_DIR}/prior/success-criteria.md"
            [ -d "$tmp_clone/literature" ] && cp -r "$tmp_clone/literature" "${RUN_DIR}/prior/literature"
            [ -d "$tmp_clone/challenge" ] && cp -r "$tmp_clone/challenge" "${RUN_DIR}/prior/challenge"
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
            log "WARN: Failed to clone ${PRIOR_REPO_URL}. Proceeding without prior context."
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
compute_profile: "${COMPUTE_PROFILE}"
clarifications: []
decisions: []
---

Follow-up research run initialized.
Topic: ${original_topic}
Parent issue: #${PARENT_ISSUE}
STATEEOF

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
    ISSUE_NUMBER=$(grep '^issue_number:' "${RUN_DIR}/state.md" | awk '{print $2}')
    [ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
    # Check if the in-progress run is a follow-up
    if grep -q '^is_followup: true' "${RUN_DIR}/state.md" 2>/dev/null; then
        IS_FOLLOWUP=true
        PRIOR_REPO_URL=$(grep '^prior_repo:' "${RUN_DIR}/state.md" | sed 's/prior_repo: *//')
        PARENT_ISSUE=$(grep '^parent_issue:' "${RUN_DIR}/state.md" | awk '{print $2}')
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

get_current_step() {
    grep '^current_step:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
}

get_status() {
    grep '^status:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
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
        && upsert_frontmatter_field "agent_model" "$(yaml_quote "$MODEL")" \
        && upsert_frontmatter_field "compute_profile" "$(yaml_quote "$COMPUTE_PROFILE")"
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
EOF
}

build_step_prompt() {
    local step="$1"
    local cmd_file="${REPO_DIR}/commands/researcher-auto-step.md"
    local cmd_body
    cmd_body=$(sed '1,/^---$/{ /^---$/!d; /^---$/d; }' "$cmd_file" | sed '/^---$/,/^---$/d')
    build_runtime_header
    if [ "$BACKEND" = "codex" ]; then
        build_codex_preamble
    fi
    echo "$cmd_body" | sed "s|{{argument}}|${step} ${RUN_DIR}|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

build_email_prompt() {
    local cmd_file="${REPO_DIR}/commands/researcher-auto-email.md"
    local cmd_body
    cmd_body=$(sed '1,/^---$/{ /^---$/!d; /^---$/d; }' "$cmd_file" | sed '/^---$/,/^---$/d')
    build_runtime_header
    cat <<EOF

# Autonomous Email Handoff

- Compose only; do not send the email yourself.
- Write the HTML to: ${RUN_DIR}/email-draft.html
- Write the single-line subject to: ${RUN_DIR}/email-subject.txt
- The wrapper will send only to: ${EMAIL_TO}
- Footer agent label: ${AGENT_LABEL}
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

        # Success = the step advanced, reached a genuine terminal status, OR (for the
        # audit step, which by design keeps current_step at 10 across rounds) the round
        # actually completed. We proxy "completed" with a clean provider exit: a dropped
        # connection exits non-zero AND leaves the status unchanged, so without this gate
        # a drop during Step 10/11 would return success here and silently burn an
        # AUDIT_ROUNDS increment upstream instead of retrying. With the gate it retries.
        if [ "$new_step" != "$prev_step" ] \
            || [ "$new_status" = "complete" ] || [ "$new_status" = "failed" ] \
            || { [ "$exit_code" -eq 0 ] \
                 && { [ "$new_status" = "audit_remediating" ] || [ "$new_status" = "audit_complete" ]; }; }; then
            log "Step ${step} completed. State now at step ${new_step}, status: ${new_status}"
            return 0
        fi

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
        local last_line
        last_line=$(grep -v '^[[:space:]]*$' "$run_log" | tail -1)
        if printf '%s\n' "$last_line" | grep -qE "^[[:space:]]*(You've hit your (session|usage) limit\b|(Claude )?(AI )?[Uu]sage limit reached\b)"; then
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
                    && [ $(( $(date +%s) - START_TIME )) -lt $(( TIMEOUT_HOURS * 3600 )) ]; do
                    sleep "$JOB_WAIT_POLL_SECONDS"
                    waited=$((waited + JOB_WAIT_POLL_SECONDS))
                    total_waited=$((total_waited + JOB_WAIT_POLL_SECONDS))
                    outstanding=$(outstanding_jobs)
                done
                if [ -n "${outstanding// /}" ]; then
                    log "Step ${step}: job(s) still outstanding after ${waited}s (cumulative ${total_waited}s of ${JOB_WAIT_MAX_SECONDS}s, run timeout ${TIMEOUT_HOURS}h); giving up on waiting."
                else
                    refunds=$((refunds + 1))
                    attempt=$((attempt - 1))
                    log "Step ${step}: external job(s) finished after ~${waited}s; retrying without spending an attempt (refund ${refunds}/${JOB_WAIT_MAX_REFUNDS})."
                    continue
                fi
            fi
        fi

        log "Step ${step} did not advance state (still at step ${prev_step}, exit ${exit_code}, attempt ${attempt}/${STEP_MAX_ATTEMPTS})."
    done

    log "Step ${step} failed after ${STEP_MAX_ATTEMPTS} attempts. Marking run failed."
    sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
    return 1
}

# Main step loop
while true; do
    CURRENT_STEP=$(get_current_step)
    STATUS=$(get_status)

    case "$STATUS" in
        complete|failed|aborted_rethink)
            log "Run reached terminal state: ${STATUS}"
            break
            ;;
    esac

    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ $ELAPSED -gt $(( TIMEOUT_HOURS * 3600 )) ]; then
        log "Timeout (${TIMEOUT_HOURS}h) reached at step ${CURRENT_STEP}. Fast-tracking to the report."
        if [ "$CURRENT_STEP" -ge 5 ]; then
            # Bypass the audit (Step 10) on a timed-out run — never re-enter a
            # multi-hour remediation re-run — and compile whatever exists (Step 11).
            sed -i.bak "s/^status:.*/status: audit_complete/" "${RUN_DIR}/state.md"
            run_step 11 || true
        fi
        sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
        break
    fi

    # Audit-remediation re-entry: stay on Step 10 while the auditor asks for another
    # round. AUDIT_ROUNDS (bash-owned) is the authoritative ceiling — no agent field needed.
    if [ "$CURRENT_STEP" -eq 10 ] && [ "$STATUS" = "audit_remediating" ]; then
        AUDIT_ROUNDS=$((AUDIT_ROUNDS + 1))
        if [ "$AUDIT_ROUNDS" -ge 4 ]; then
            log "Audit-remediation ceiling reached (${AUDIT_ROUNDS} rounds). Forcing the report."
            sed -i.bak "s/^status:.*/status: audit_complete/" "${RUN_DIR}/state.md"
            run_step 11 || true
            sed -i.bak "s/^status:.*/status: complete/" "${RUN_DIR}/state.md"
            break
        fi
        NEXT_STEP=10
    else
        AUDIT_ROUNDS=0
        NEXT_STEP=$((CURRENT_STEP + 1))
        [ "$CURRENT_STEP" -eq 0 ] && NEXT_STEP=1
    fi

    if [ "$NEXT_STEP" -gt 11 ]; then
        log "All steps completed."
        break
    fi

    STEP_RC=0
    run_step "$NEXT_STEP" || STEP_RC=$?
    if [ "$STEP_RC" -eq 2 ]; then
        # Paused on a provider limit, not finished: publishing a partial repo,
        # emailing a non-result, and marking the issue processed would all be
        # wrong, and would strand the run. Leave everything resumable.
        log "Run PAUSED at step ${NEXT_STEP}. Skipping repo publish, email, and issue update."
        log "Resume with the same command once the provider limit resets."
        SKIP_PUBLISH=true
        SKIP_EMAIL=true
        PAUSED=true
        break
    elif [ "$STEP_RC" -ne 0 ]; then
        log "Step ${NEXT_STEP} did not complete. Stopping."
        break
    fi
done

# --- Post-completion: Create GitHub repo (git init in place, no copying) ---
STATUS=$(get_status)
RUN_ID=$(grep '^run_id:' "${RUN_DIR}/state.md" | head -1 | sed 's/run_id: *//')
TOPIC_LINE=$(grep '^topic:' "${RUN_DIR}/state.md" | head -1 | sed 's/topic: *"*//;s/"*$//')
REPO_URL=""

create_github_repo() {
    # Follow-up runs push to the existing repo on a new branch
    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PRIOR_REPO_URL" ]; then
        push_followup_results
        return
    fi

    local slug
    # Truncate at word boundary (max ~40 chars for the topic portion)
    local topic_slug
    topic_slug=$(echo "$TOPIC_LINE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    # Cut to 40 chars then remove any trailing partial word
    topic_slug=$(echo "$topic_slug" | head -c 40 | sed 's/-[^-]*$//')
    slug="research-${topic_slug}"

    log "Creating GitHub repo: tbuckworth/${slug}"

    # GitHub caps repo descriptions at 350 chars; the topic can be far longer (a whole
    # paragraph), which makes `gh repo create` fail with a 422. Truncate to stay under.
    local repo_desc
    repo_desc="AI safety research (autonomous): ${TOPIC_LINE}"
    repo_desc="$(printf '%s' "$repo_desc" | tr '\n' ' ' | head -c 300)"

    # Do NOT swallow the error silently — log it. If the repo already exists this returns
    # non-zero too, which is fine: the push+verify below is the real success signal.
    gh repo create "tbuckworth/${slug}" --public --description "$repo_desc" 2>&1 \
        | tee -a "${LOG_DIR}/gh-repo-create.log" \
        || log "WARN: gh repo create returned non-zero for tbuckworth/${slug} (may already exist); will still attempt push."

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
- \`experiments/\` — Experiment code and results
- \`challenge/\` — Adversarial review (assumptions, mentor-review, pre-mortem)
- \`decomposition.md\` — Steinhardt fail-fast decomposition
- \`state.md\` — Workflow state log

---

*Generated by the autonomous AI safety researcher agent.*
READMEEOF

    # Git init in place — .gitignore already excludes large files
    cd "$RUN_DIR"
    git init -q
    git remote remove origin 2>/dev/null || true
    git remote add origin "https://github.com/tbuckworth/${slug}.git"
    git add -A
    git commit -q -m "$(cat <<COMMITEOF
Research artifacts: ${TOPIC_LINE}

Autonomous research run (${STATUS}).
Run ID: ${RUN_ID}

${COMMIT_ATTRIBUTION}
COMMITEOF
)" || log "WARN: git commit produced no commit (nothing to commit?)."

    # Rename the just-committed branch to 'main' regardless of git's default (older git
    # inits 'master', so `git push origin main` was silently failing with
    # 'src refspec main does not match any' — leaving every repo empty).
    git branch -M main 2>/dev/null || true

    cd "$REPO_DIR"

    # Only advertise the repo link if the push actually succeeded AND the remote is
    # non-empty. Previously the URL was written unconditionally, so a failed push still
    # produced an email/issue-comment linking to an empty (or nonexistent) repo.
    if ( cd "$RUN_DIR" && git push -u origin main ) 2>&1 | tee -a "${LOG_DIR}/gh-push.log"; then
        if gh repo view "tbuckworth/${slug}" --json isEmpty --jq '.isEmpty' 2>/dev/null | grep -q '^false$'; then
            REPO_URL="https://github.com/tbuckworth/${slug}"
            echo "$REPO_URL" > "${RUN_DIR}/.repo_url"
            log "GitHub repo pushed and verified: ${REPO_URL}"
        else
            log "ERROR: push reported success but tbuckworth/${slug} is still empty. Not advertising a repo link."
        fi
    else
        log "ERROR: git push to tbuckworth/${slug} failed. Results remain local in ${RUN_DIR}; no repo link will be advertised."
    fi
}

push_followup_results() {
    local date_slug branch tmp_clone
    date_slug=$(date +%Y-%m-%d)
    branch="followup-${date_slug}-$(echo "$RUN_ID" | tail -c 20 | sed 's/^-//')"

    log "Pushing follow-up results to ${PRIOR_REPO_URL} on branch ${branch}"

    tmp_clone=$(mktemp -d)
    if ! gh repo clone "$PRIOR_REPO_URL" "$tmp_clone" -- --depth 1 2>/dev/null; then
        log "WARN: Failed to clone ${PRIOR_REPO_URL} for push. Results stay local."
        rm -rf "$tmp_clone"
        return 1
    fi

    cd "$tmp_clone"
    git checkout -b "$branch"

    # Copy new artifacts from the run directory (excluding prior/ to avoid duplication)
    for item in "$RUN_DIR"/*; do
        local basename
        basename=$(basename "$item")
        [ "$basename" = "prior" ] && continue
        [ "$basename" = ".git" ] && continue
        cp -r "$item" "$tmp_clone/" 2>/dev/null || true
    done

    git add -A
    git commit -m "$(cat <<COMMITEOF
Follow-up research: ${TOPIC_LINE}

Follow-up run (${STATUS}).
Run ID: ${RUN_ID}
Parent issue: #${PARENT_ISSUE}

${COMMIT_ATTRIBUTION}
COMMITEOF
)" || true

    # Only advertise the branch link if the push actually succeeded.
    if git push -u origin "$branch" 2>&1 | tee -a "${LOG_DIR}/gh-push.log"; then
        REPO_URL="${PRIOR_REPO_URL}/tree/${branch}"
        echo "$REPO_URL" > "${RUN_DIR}/.repo_url"
        log "Follow-up pushed: ${REPO_URL}"
    else
        log "ERROR: git push of follow-up branch ${branch} to ${PRIOR_REPO_URL} failed. No branch link will be advertised."
    fi
    cd "$REPO_DIR"
    rm -rf "$tmp_clone"
}

if is_true "$SKIP_PUBLISH"; then
    log "Skipping GitHub publication (RESEARCHER_SKIP_PUBLISH=${SKIP_PUBLISH})."
else
    create_github_repo || log "Note: GitHub repo creation did not complete. Continuing to email."
fi

# --- Post-completion: Send email ---
send_email() {
    local email_log compose_status send_status subject
    email_log="${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S).log"
    log "Composing results email with ${BACKEND}..."
    cd "$REPO_DIR"
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

# --- Post-completion: Update GitHub issue ---
if ! is_true "$SKIP_PUBLISH" && [ -n "$ISSUE_NUMBER" ] && [ "$ISSUE_NUMBER" != "none" ]; then
    REPO_URL=$(cat "${RUN_DIR}/.repo_url" 2>/dev/null || echo "N/A")

    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PARENT_ISSUE" ] && [ "$PARENT_ISSUE" != "none" ]; then
        # Follow-up: comment on both the follow-up issue and the parent
        gh issue comment "$ISSUE_NUMBER" --repo tbuckworth/tasks \
            --body "Follow-up research complete (${STATUS}, ${AGENT_LABEL}).
Branch: ${REPO_URL}
Run: ${RUN_ID}
Parent: #${PARENT_ISSUE}" 2>/dev/null || true

        gh issue comment "$PARENT_ISSUE" --repo tbuckworth/tasks \
            --body "Follow-up #${ISSUE_NUMBER} completed (${STATUS}, ${AGENT_LABEL}).
Branch: ${REPO_URL}" 2>/dev/null || true
    else
        gh issue comment "$ISSUE_NUMBER" --repo tbuckworth/tasks \
            --body "Autonomous research complete (${STATUS}, ${AGENT_LABEL}).
Repo: ${REPO_URL}
Run: ${RUN_ID}" 2>/dev/null || true
    fi

    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --remove-label "$PROCESSING_LABEL" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --add-label "$PROCESSED_LABEL" 2>/dev/null || true

    log "Updated issue #${ISSUE_NUMBER}"
fi

if is_true "$PAUSED"; then
    # Distinct exit code: a paused run must not look like a completed one to
    # cron, `at`, or any wrapper checking the status.
    log "PAUSED (not complete). Run directory: ${RUN_DIR}"
    exit 3
fi

log "Done. Run directory: ${RUN_DIR}"

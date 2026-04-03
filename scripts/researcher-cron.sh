#!/usr/bin/env bash
# researcher-cron.sh — Autonomous research runner
#
# Picks a research idea from GitHub Issues (or takes one as argument),
# runs the 10-step research workflow via per-step Claude sessions,
# creates a GitHub repo with artifacts, and emails results.
#
# Usage:
#   researcher-cron.sh [topic]        # Run on a specific topic
#   researcher-cron.sh                # Pick from GitHub Issues
#
# Crontab example (daily at 2am):
#   0 2 * * * /home/titus/pyg/researcher/scripts/researcher-cron.sh >> /home/titus/pyg/researcher/logs/cron.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Research output goes on the HDD (2.7TB) to avoid filling the SSD
HDD="/media/titus/big"
OUTPUT_DIR="${HDD}/researcher-output"
LOG_DIR="${OUTPUT_DIR}/logs"

LOCKFILE="/tmp/researcher-auto.lock"
TIMEOUT_HOURS=4
TOPIC="${1:-}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Symlink logs and output into the plugin dir for convenience
ln -sfn "$OUTPUT_DIR" "${REPO_DIR}/output"
ln -sfn "$LOG_DIR" "${REPO_DIR}/logs"

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
if ! gh auth status &>/dev/null; then
    log "ERROR: gh CLI not authenticated. Run 'gh auth login'. Exiting."
    exit 1
fi

if ! command -v claude &>/dev/null; then
    log "ERROR: claude CLI not found in PATH. Exiting."
    exit 1
fi

# Check if GPU is busy (>500MB VRAM used by any single process = busy)
if command -v nvidia-smi &>/dev/null; then
    GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null || true)
    if [ -n "$GPU_PROCS" ]; then
        MAX_MEM=$(echo "$GPU_PROCS" | awk -F', ' '{print $2}' | sort -n | tail -1)
        if [ "$MAX_MEM" -gt 500 ] 2>/dev/null; then
            log "GPU busy (process using ${MAX_MEM} MiB). Skipping this run."
            exit 0
        fi
    fi
fi

if [ ! -d "$HDD" ]; then
    log "ERROR: HDD not mounted at ${HDD}. Exiting."
    exit 1
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
    for state_file in $(ls -1t "$OUTPUT_DIR"/*/state.md 2>/dev/null); do
        local status
        status=$(grep '^status:' "$state_file" | head -1 | awk '{print $2}')
        if [ "$status" != "complete" ] && [ "$status" != "failed" ] && [ "$status" != "aborted_rethink" ]; then
            echo "$(dirname "$state_file")"
            return 0
        fi
    done
    return 1
}

pick_issue() {
    local issues
    issues=$(gh issue list --repo tbuckworth/tasks \
        --label "list:research-ideas" \
        --state open \
        --json number,title,body,labels \
        --limit 50)

    local picked
    picked=$(echo "$issues" | jq -r '
        [.[] | select(
            (.labels | map(.name) | index("status:claude-researching") | not) and
            (.labels | map(.name) | index("status:claude-processed") | not)
        )] | first // empty')

    if [ -z "$picked" ] || [ "$picked" = "null" ]; then
        log "No unprocessed research ideas found. Exiting."
        exit 0
    fi

    ISSUE_NUMBER=$(echo "$picked" | jq -r '.number')
    local title body
    title=$(echo "$picked" | jq -r '.title')
    body=$(echo "$picked" | jq -r '.body // ""')

    log "Picked issue #${ISSUE_NUMBER}: ${title}"

    gh label create "status:claude-researching" \
        --repo tbuckworth/tasks \
        --color "0E8A16" \
        --description "Currently being researched by autonomous agent" \
        2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks --add-label "status:claude-researching"

    TOPIC="$title"
    if [ -n "$body" ] && [ "$body" != "null" ]; then
        TOPIC="${title}

Context from issue body:
${body}"
    fi

    # Detect follow-up issues
    if echo "$picked" | jq -e '.labels[] | select(.name == "type:follow-up")' > /dev/null 2>&1; then
        IS_FOLLOWUP=true
        PRIOR_REPO_URL=$(echo "$body" | grep -oP '(?<=Repo: )https://\S+' || true)
        PARENT_ISSUE=$(echo "$body" | grep -oP '(?<=Parent: #)\d+' || true)
        PRIOR_RUN_ID=$(echo "$body" | grep -oP '(?<=Run: )\S+' || true)
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
issue_number: ${ISSUE_NUMBER:-none}
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
    echo "$original_topic" > "${RUN_DIR}/topic.txt"
    echo "" >> "${RUN_DIR}/topic.txt"
    echo "Follow-up feedback:" >> "${RUN_DIR}/topic.txt"
    echo "$FEEDBACK" >> "${RUN_DIR}/topic.txt"

    # Write fresh state.md
    cat > "${RUN_DIR}/state.md" << STATEEOF
---
run_id: ${run_id}
topic: "$(echo "$original_topic" | sed 's/"/\\"/g')"
current_step: 0
status: initialized
mode: autonomous
issue_number: ${ISSUE_NUMBER:-none}
is_followup: true
parent_issue: ${PARENT_ISSUE:-none}
prior_repo: ${PRIOR_REPO_URL}
prior_run_id: ${PRIOR_RUN_ID}
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
    ISSUE_NUMBER=$(grep '^issue_number:' "${RUN_DIR}/state.md" | awk '{print $2}')
    [ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
    # Check if the in-progress run is a follow-up
    if grep -q '^is_followup: true' "${RUN_DIR}/state.md" 2>/dev/null; then
        IS_FOLLOWUP=true
        PRIOR_REPO_URL=$(grep '^prior_repo:' "${RUN_DIR}/state.md" | sed 's/prior_repo: *//')
        PARENT_ISSUE=$(grep '^parent_issue:' "${RUN_DIR}/state.md" | awk '{print $2}')
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

get_current_step() {
    grep '^current_step:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
}

get_status() {
    grep '^status:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
}

build_step_prompt() {
    local step="$1"
    local cmd_file="${REPO_DIR}/commands/researcher-auto-step.md"
    local cmd_body
    cmd_body=$(sed '1,/^---$/{ /^---$/!d; /^---$/d; }' "$cmd_file" | sed '/^---$/,/^---$/d')
    echo "$cmd_body" | sed "s|{{argument}}|${step} ${RUN_DIR}|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

build_email_prompt() {
    local cmd_file="${REPO_DIR}/commands/researcher-auto-email.md"
    local cmd_body
    cmd_body=$(sed '1,/^---$/{ /^---$/!d; /^---$/d; }' "$cmd_file" | sed '/^---$/,/^---$/d')
    echo "$cmd_body" | sed "s|{{argument}}|${RUN_DIR}|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

run_step() {
    local step="$1"
    local run_log="${LOG_DIR}/step-${step}-$(date +%Y%m%d-%H%M%S).log"
    local prev_step
    prev_step=$(get_current_step)

    log "Starting step ${step}..."

    cd "$REPO_DIR"
    build_step_prompt "$step" | claude --print \
        --dangerously-skip-permissions \
        --model claude-opus-4-6 \
        --allowedTools 'Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch,Task' \
        2>&1 | tee "$run_log"

    local exit_code=${PIPESTATUS[0]}
    local new_step
    new_step=$(get_current_step)
    local new_status
    new_status=$(get_status)

    if [ "$new_step" = "$prev_step" ] && [ "$new_status" != "complete" ] && [ "$new_status" != "failed" ]; then
        log "ERROR: Step ${step} did not advance state (still at step ${prev_step}). Exit code: ${exit_code}"
        sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
        return 1
    fi

    log "Step ${step} completed. State now at step ${new_step}, status: ${new_status}"
    return 0
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
        log "WARN: Timeout (${TIMEOUT_HOURS}h) reached at step ${CURRENT_STEP}. Fast-tracking to report."
        if [ "$CURRENT_STEP" -ge 5 ]; then
            run_step 10 || true
        fi
        sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
        break
    fi

    NEXT_STEP=$((CURRENT_STEP + 1))
    [ "$CURRENT_STEP" -eq 0 ] && NEXT_STEP=1

    if [ "$NEXT_STEP" -gt 10 ]; then
        log "All steps completed."
        break
    fi

    if ! run_step "$NEXT_STEP"; then
        log "ERROR: Step ${NEXT_STEP} failed. Stopping."
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

    gh repo create "tbuckworth/${slug}" --public \
        --description "AI safety research: ${TOPIC_LINE} (autonomous)" 2>/dev/null || true

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

## Summary

${abstract:-See paper/ directory for full results.}

## Structure

- \`paper/\` — LaTeX paper and compiled PDF
- \`literature/\` — Literature review artifacts
- \`experiments/\` — Experiment code and results
- \`challenge/\` — Adversarial review (assumptions, steelman, pre-mortem)
- \`decomposition.md\` — Steinhardt fail-fast decomposition
- \`state.md\` — Workflow state log

---

*Generated by the autonomous AI safety researcher agent.*
READMEEOF

    # Git init in place — .gitignore already excludes large files
    cd "$RUN_DIR"
    git init
    git remote add origin "https://github.com/tbuckworth/${slug}.git"
    git add -A
    git commit -m "$(cat <<COMMITEOF
Research artifacts: ${TOPIC_LINE}

Autonomous research run (${STATUS}).
Run ID: ${RUN_ID}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
COMMITEOF
)" || true

    git push -u origin main || true

    cd "$REPO_DIR"

    REPO_URL="https://github.com/tbuckworth/${slug}"
    echo "$REPO_URL" > "${RUN_DIR}/.repo_url"
    log "GitHub repo: ${REPO_URL}"
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

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
COMMITEOF
)" || true

    git push -u origin "$branch" || true
    cd "$REPO_DIR"

    REPO_URL="${PRIOR_REPO_URL}/tree/${branch}"
    echo "$REPO_URL" > "${RUN_DIR}/.repo_url"
    rm -rf "$tmp_clone"
    log "Follow-up pushed: ${REPO_URL}"
}

create_github_repo || log "WARN: GitHub repo creation failed. Continuing to email."

# --- Post-completion: Send email ---
send_email() {
    log "Sending results email..."
    cd "$REPO_DIR"
    build_email_prompt | claude --print \
        --dangerously-skip-permissions \
        --model claude-opus-4-6 \
        --allowedTools 'Read,Glob,Bash,mcp__gmail__send_email,mcp__claude_ai_Gmail__gmail_get_profile' \
        2>&1 | tee "${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S).log"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "WARN: Email sending failed."
        return 1
    fi
    log "Email sent."
}

send_email || log "WARN: Email failed. Results in ${RUN_DIR} and GitHub repo."

# --- Post-completion: Update GitHub issue ---
if [ -n "$ISSUE_NUMBER" ] && [ "$ISSUE_NUMBER" != "none" ]; then
    REPO_URL=$(cat "${RUN_DIR}/.repo_url" 2>/dev/null || echo "N/A")

    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PARENT_ISSUE" ] && [ "$PARENT_ISSUE" != "none" ]; then
        # Follow-up: comment on both the follow-up issue and the parent
        gh issue comment "$ISSUE_NUMBER" --repo tbuckworth/tasks \
            --body "Follow-up research complete (${STATUS}).
Branch: ${REPO_URL}
Run: ${RUN_ID}
Parent: #${PARENT_ISSUE}" 2>/dev/null || true

        gh issue comment "$PARENT_ISSUE" --repo tbuckworth/tasks \
            --body "Follow-up #${ISSUE_NUMBER} completed (${STATUS}).
Branch: ${REPO_URL}" 2>/dev/null || true
    else
        gh issue comment "$ISSUE_NUMBER" --repo tbuckworth/tasks \
            --body "Autonomous research complete (${STATUS}).
Repo: ${REPO_URL}
Run: ${RUN_ID}" 2>/dev/null || true
    fi

    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --remove-label "status:claude-researching" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --add-label "status:claude-processed" 2>/dev/null || true

    log "Updated issue #${ISSUE_NUMBER}"
fi

log "Done. Run directory: ${RUN_DIR}"

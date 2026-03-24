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
LOG_DIR="${REPO_DIR}/logs"
OUTPUT_DIR="${REPO_DIR}/output"
LOCKFILE="/tmp/researcher-auto.lock"
TIMEOUT_HOURS=4
TOPIC="${1:-}"

mkdir -p "$LOG_DIR" "$OUTPUT_DIR"

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

# --- Find or create run ---
RUN_DIR=""
ISSUE_NUMBER=""

find_in_progress_run() {
    # Look for most recent run with non-terminal status
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
    # Get research ideas that aren't already being researched or processed
    local issues
    issues=$(gh issue list --repo tbuckworth/tasks \
        --label "list:research-ideas" \
        --state open \
        --json number,title,body,labels \
        --limit 50)

    # Filter out issues with status:claude-researching or status:claude-processed
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

    # Tag the issue — create label if needed (idempotent)
    gh label create "status:claude-researching" \
        --repo tbuckworth/tasks \
        --color "0E8A16" \
        --description "Currently being researched by autonomous agent" \
        2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks --add-label "status:claude-researching"

    # Set TOPIC from issue
    TOPIC="$title"
    if [ -n "$body" ] && [ "$body" != "null" ]; then
        TOPIC="${title}

Context from issue body:
${body}"
    fi
}

create_run_dir() {
    local slug date_prefix run_id
    date_prefix=$(date +%Y-%m-%d)
    slug=$(echo "$TOPIC" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 60)
    run_id="${date_prefix}-${slug}"
    RUN_DIR="${OUTPUT_DIR}/${run_id}"

    mkdir -p "${RUN_DIR}/literature" "${RUN_DIR}/experiments" "${RUN_DIR}/challenge"

    # Write initial state.md
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

    # Write the full topic (including issue body) to a separate file
    echo "$TOPIC" > "${RUN_DIR}/topic.txt"

    log "Created run directory: ${RUN_DIR}"
}

# Check for in-progress run first
if IN_PROGRESS=$(find_in_progress_run); then
    RUN_DIR="$IN_PROGRESS"
    ISSUE_NUMBER=$(grep '^issue_number:' "${RUN_DIR}/state.md" | awk '{print $2}')
    [ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
    log "Resuming in-progress run: ${RUN_DIR}"
elif [ -n "$TOPIC" ]; then
    create_run_dir
else
    pick_issue
    create_run_dir
fi

# --- Step loop ---
START_TIME=$(date +%s)

get_current_step() {
    grep '^current_step:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
}

get_status() {
    grep '^status:' "${RUN_DIR}/state.md" | head -1 | awk '{print $2}'
}

run_step() {
    local step="$1"
    local run_log="${LOG_DIR}/step-${step}-$(date +%Y%m%d-%H%M%S).log"

    log "Starting step ${step}..."

    cd "$REPO_DIR"
    claude --print \
        --dangerously-skip-permissions \
        --model claude-opus-4-6 \
        --allowedTools 'Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch,Task' \
        "/researcher-auto-step ${step} ${RUN_DIR}" \
        2>&1 | tee "$run_log"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -ne 0 ]; then
        log "WARN: Step ${step} exited with code ${exit_code}"
        local new_step
        new_step=$(get_current_step)
        if [ "$new_step" = "$step" ] || [ "$new_step" = "$((step - 1))" ]; then
            log "ERROR: Step ${step} failed without advancing state. Marking as failed."
            sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
            return 1
        fi
    fi

    log "Step ${step} completed."
    return 0
}

# Main step loop
while true; do
    CURRENT_STEP=$(get_current_step)
    STATUS=$(get_status)

    # Terminal states
    case "$STATUS" in
        complete|failed|aborted_rethink)
            log "Run reached terminal state: ${STATUS}"
            break
            ;;
    esac

    # Timeout check
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ $ELAPSED -gt $(( TIMEOUT_HOURS * 3600 )) ]; then
        log "WARN: Timeout (${TIMEOUT_HOURS}h) reached at step ${CURRENT_STEP}. Fast-tracking to report."
        if [ "$CURRENT_STEP" -ge 5 ]; then
            run_step 10 || true
        fi
        sed -i.bak "s/^status:.*/status: failed/" "${RUN_DIR}/state.md"
        break
    fi

    # Determine next step
    NEXT_STEP=$((CURRENT_STEP + 1))
    [ "$CURRENT_STEP" -eq 0 ] && NEXT_STEP=1

    # Step 10 is the last research step
    if [ "$NEXT_STEP" -gt 10 ]; then
        log "All steps completed."
        break
    fi

    if ! run_step "$NEXT_STEP"; then
        log "ERROR: Step ${NEXT_STEP} failed. Stopping."
        break
    fi
done

# --- Post-completion: Create GitHub repo ---
STATUS=$(get_status)
RUN_ID=$(grep '^run_id:' "${RUN_DIR}/state.md" | head -1 | sed 's/run_id: *//')
TOPIC_LINE=$(grep '^topic:' "${RUN_DIR}/state.md" | head -1 | sed 's/topic: *"*//;s/"*$//')
REPO_URL=""

create_github_repo() {
    local slug
    slug="research-$(echo "$TOPIC_LINE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 40)"

    log "Creating GitHub repo: tbuckworth/${slug}"

    gh repo create "tbuckworth/${slug}" --public \
        --description "AI safety research: ${TOPIC_LINE} (autonomous)" 2>/dev/null || true

    local tmp_repo="/tmp/researcher-repo-$$"
    rm -rf "$tmp_repo"

    if ! gh repo clone "tbuckworth/${slug}" "$tmp_repo" 2>/dev/null; then
        log "ERROR: Could not clone repo. Skipping GitHub push."
        return 1
    fi

    # Copy artifacts
    cp -r "${RUN_DIR}"/* "$tmp_repo/" 2>/dev/null || true

    # Generate README
    local abstract=""
    if [ -f "${RUN_DIR}/paper/sections/abstract.tex" ]; then
        abstract=$(sed 's/\\[a-zA-Z]*{[^}]*}//g; s/\\[a-zA-Z]*//g; s/[{}]//g' "${RUN_DIR}/paper/sections/abstract.tex" | head -20)
    fi

    cat > "${tmp_repo}/README.md" << READMEEOF
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

    cd "$tmp_repo"
    git add -A
    git commit -m "$(cat <<'COMMITEOF'
Research artifacts: automated research run

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
COMMITEOF
)" || true

    git push origin main || true

    # PR for audit trail
    git checkout -b research/artifacts
    git push -u origin research/artifacts 2>/dev/null || true
    gh pr create \
        --title "Research: ${TOPIC_LINE}" \
        --body "Autonomous research run (${STATUS}). See paper/ for results." \
        2>/dev/null || true
    gh pr merge --squash --auto 2>/dev/null || true

    cd "$REPO_DIR"
    rm -rf "$tmp_repo"

    REPO_URL="https://github.com/tbuckworth/${slug}"
    echo "$REPO_URL" > "${RUN_DIR}/.repo_url"
    log "GitHub repo: ${REPO_URL}"
}

create_github_repo || log "WARN: GitHub repo creation failed. Continuing to email."

# --- Post-completion: Send email ---
send_email() {
    log "Sending results email..."
    cd "$REPO_DIR"
    claude --print \
        --dangerously-skip-permissions \
        --model claude-opus-4-6 \
        --allowedTools 'Read,Glob,Bash,mcp__gmail__send_email,mcp__claude_ai_Gmail__gmail_get_profile' \
        "/researcher-auto-email ${RUN_DIR}" \
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

    gh issue comment "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --body "Autonomous research complete (${STATUS}).
Repo: ${REPO_URL}
Run: ${RUN_ID}" 2>/dev/null || true

    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --remove-label "status:claude-researching" 2>/dev/null || true
    gh issue edit "$ISSUE_NUMBER" --repo tbuckworth/tasks \
        --add-label "status:claude-processed" 2>/dev/null || true

    log "Updated issue #${ISSUE_NUMBER}"
fi

log "Done. Run directory: ${RUN_DIR}"

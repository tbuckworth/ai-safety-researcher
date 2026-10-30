# shellcheck shell=bash
# Choosing the run: resuming an unfinished one, picking and claiming a GitHub issue, creating a run directory.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

is_terminal_status() {
    case "$1" in
        complete|failed|timed_out) return 0 ;;
        *) return 1 ;;
    esac
}

find_in_progress_run() {
    # Prints the run to resume on stdout; everything else goes to stderr.
    local state_file status mode owner
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
        # Nor one another caller owns (it runs it under its own guard and budget).
        owner=$({ grep '^owner:' "$state_file" || true; } | head -1 | awk '{print $2}')
        if [ "$owner" != "$RUN_OWNER" ]; then
            log "Not resuming $(dirname "$state_file"): it belongs to ${owner:-no owner}." >&2
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

pinned_run() {
    local status mode
    if [ ! -f "${PIN_RUN_DIR}/state.md" ]; then
        log "ERROR: RESEARCHER_RUN_DIR=${PIN_RUN_DIR} has no state.md." >&2
        return 1
    fi
    status=$({ grep '^status:' "${PIN_RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}')
    mode=$({ grep '^mode:' "${PIN_RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}')
    if is_terminal_status "$status" || { [ -n "$mode" ] && [ "$mode" != "autonomous" ]; }; then
        log "ERROR: RESEARCHER_RUN_DIR=${PIN_RUN_DIR} is not a resumable autonomous run (status '${status}', mode '${mode:-?}')." >&2
        return 1
    fi
    printf '%s\n' "${PIN_RUN_DIR%/}"
}

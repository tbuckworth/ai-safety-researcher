# shellcheck shell=bash
# Choosing the run: resuming an unfinished one, picking and claiming a GitHub issue, creating a run directory.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

is_terminal_status() {
    # TERMINAL_STATUSES comes from researcher_lib.py, which holds the list.
    case " ${TERMINAL_STATUSES} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

is_followup_run() {
    # A follow-up issue that names the prior run's repo: the run copies that
    # run's artifacts and publishes as a branch of its repo.
    [ "$IS_FOLLOWUP" = true ] && [ -n "$PRIOR_REPO_URL" ]
}

find_in_progress_run() {
    # Prints the run to resume on stdout; everything else goes to stderr.
    local state_file status mode owner
    # Runs live under machine-generated slug paths without whitespace.
    # shellcheck disable=SC2045
    for state_file in $(ls -1t "$OUTPUT_DIR"/*/state.md 2>/dev/null); do
        status=$(state_field "$state_file" status)
        is_terminal_status "$status" && continue
        # An interactive /researcher run shares the output directory; cron must
        # never take one over.
        mode=$(state_field "$state_file" mode)
        if [ -n "$mode" ] && [ "$mode" != "autonomous" ]; then
            continue
        fi
        # Nor one another caller owns (it runs it under its own guard and budget).
        owner=$(state_field "$state_file" owner)
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

pick_issue() {
    # Chooses the issue to run and claims it (or exits), then sets ISSUE_NUMBER,
    # TOPIC and the follow-up fields from it.
    select_issue
    claim_issue "$(jq -r '.number' <<< "$PICKED")"
    read_picked_issue
}

select_issue() {
    # Sets PICKED to the issue to run, as gh JSON: RESEARCHER_ISSUE when it is an
    # open, unclaimed research idea (otherwise exits 1), else the first queued
    # issue researcher_lib.py's pick accepts (exits 0 when there is none).
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
        picked=$(echo "$target" | jq -c --arg queue "$RESEARCH_IDEAS_LABEL" '
            select(.state == "OPEN")
            | select(.labels | map(.name) | index($queue)) // empty')
        if [ -n "$picked" ]; then
            # Refuses an issue being researched right now or with a run already
            # in progress here; allows a deliberate re-run of a finished one.
            picked=$(echo "$picked" | python3 "$LIB" pick --explicit --output-dir "$OUTPUT_DIR")
        fi
        if [ -z "$picked" ] || [ "$picked" = "null" ]; then
            log "ERROR: issue #${RESEARCHER_ISSUE} is not an open, unclaimed ${RESEARCH_IDEAS_LABEL} issue."
            exit 1
        fi
    else
    local issues allow_rerun_flag=()
    issues=$(gh issue list --repo "$TASKS_REPO" \
        --label "$RESEARCH_IDEAS_LABEL" \
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
    PICKED="$picked"
}

claim_issue() {
    # Labels issue $1 as being researched by this backend. The issue is re-read
    # first: the listing may be minutes old, and another runner (the other
    # backend, another machine) may have claimed it since. Exits 0 without
    # claiming when it is taken, and 1 when it cannot be re-read (gh's error is
    # in the log): it is never run unchecked.
    local number="$1" fresh reason explicit=()
    [ -z "${RESEARCHER_ISSUE:-}" ] || explicit=(--explicit)
    if ! fresh=$(gh issue view "$number" --repo "$TASKS_REPO" --json labels,state); then
        log "ERROR: issue #${number} could not be re-read before claiming it (gh's error is above). Exiting without running it."
        exit 1
    fi
    reason=$(printf '%s' "$fresh" | python3 "$LIB" claimed ${explicit[@]+"${explicit[@]}"})
    if [ -n "$reason" ]; then
        log "Issue #${number} was taken since the listing (${reason}). Exiting."
        exit 0
    fi

    gh label create "$PROCESSING_LABEL" \
        --repo "$TASKS_REPO" \
        --color "0E8A16" \
        --description "Currently being researched by the ${BACKEND} autonomous agent" \
        2>/dev/null || true
    gh issue edit "$number" --repo "$TASKS_REPO" --add-label "$PROCESSING_LABEL"
}

read_picked_issue() {
    # Sets ISSUE_NUMBER, FOLLOWUP_KEY and TOPIC (the title, then the body as
    # context) from PICKED and, for a follow-up issue, the follow-up fields that
    # researcher_lib.py's followup-meta reads from its title and footer.
    local title body meta
    ISSUE_NUMBER=$(jq -r '.number' <<< "$PICKED")
    FOLLOWUP_KEY=$(jq -r '.followup_key // ""' <<< "$PICKED")
    title=$(jq -r '.title' <<< "$PICKED")
    body=$(jq -r '.body // ""' <<< "$PICKED")
    log "Picked issue #${ISSUE_NUMBER}: ${title}"

    TOPIC="$title"
    if [ -n "$body" ] && [ "$body" != "null" ]; then
        TOPIC="${title}

Context from issue body:
${body}"
    fi

    meta=$(python3 "$LIB" followup-meta <<< "$PICKED")
    if [ "$(jq -r '.is_followup' <<< "$meta")" = true ]; then
        IS_FOLLOWUP=true
        FOLLOWUP_TITLE=$(jq -r '.title' <<< "$meta")
        PRIOR_REPO_URL=$(jq -r '.prior_repo' <<< "$meta")
        PARENT_ISSUE=$(jq -r '.parent_issue' <<< "$meta")
        PRIOR_RUN_ID=$(jq -r '.prior_run_id' <<< "$meta")
        FEEDBACK=$(jq -r '.feedback' <<< "$meta")
        log "Follow-up detected. Parent: #${PARENT_ISSUE}, Prior repo: ${PRIOR_REPO_URL:-none}"
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
    # Creates RUN_DIR for TOPIC: <date>-<slug of the title>, or
    # <date>-followup-<slug> for a follow-up run, made unique, with the workflow's
    # subdirectories, topic.txt, a fresh state.md and .gitignore. A follow-up run
    # also gets the prior run's artifacts in prior/ and its feedback in
    # followup-context.md.
    local title stem topic_text body
    if is_followup_run; then
        title="$FOLLOWUP_TITLE"
        stem="followup-$(python3 "$LIB" slug --max-length 50 -- "$title")"
        topic_text=$(printf '%s\n\nFollow-up feedback:\n%s' "$title" "$FEEDBACK")
        body=$(printf 'Follow-up research run initialized.\nTopic: %s\nParent issue: #%s' "$title" "$PARENT_ISSUE")
    else
        title=$(printf '%s\n' "$TOPIC" | head -1)
        stem=$(python3 "$LIB" slug --max-length 60 -- "$title")
        topic_text="$TOPIC"
        body=$(printf 'Autonomous research run initialized.\nTopic: %s' "$title")
    fi
    RUN_DIR="${OUTPUT_DIR}/$(unique_run_id "$(date +%Y-%m-%d)-${stem}")"

    mkdir -p "${RUN_DIR}/literature" "${RUN_DIR}/experiments" "${RUN_DIR}/challenge"
    printf '%s\n' "$topic_text" > "${RUN_DIR}/topic.txt"
    write_new_state "$title" "$body"
    if is_followup_run; then
        mkdir -p "${RUN_DIR}/prior"
        copy_prior_artifacts
        write_followup_context
    fi
    write_gitignore "$RUN_DIR"
    log "Created run directory: ${RUN_DIR}"
}

copy_prior_artifacts() {
    # Clones the prior run's repo (on the output volume, never /tmp: /tmp is on
    # the small root disk) and copies the artifacts later steps read into prior/.
    # A clone that fails leaves prior/ empty, and the run goes on without it.
    local tmp_clone prior_branch clone_args=(-q --depth 1) pattern path relative
    # Paths in the prior repo, globs allowed. knowledge/ is the research line's
    # own knowledge base (what it has established, ruled out, and how to
    # reproduce it), carried forward and extended at Step 11. Of the
    # experiments, only the plans and results are copied, to keep it light.
    local artifacts=(
        state.md briefing.md decomposition.md novelty-assessment.md success-criteria.md
        next-steps.md method-spec.md references.bib citation-registry.md
        literature challenge knowledge
        'experiments/exp-*/results.md' 'experiments/exp-*/plan.md' 'paper/sections/*.tex'
    )
    mkdir -p "${OUTPUT_DIR}/.tmp"
    tmp_clone=$(mktemp -d "${OUTPUT_DIR}/.tmp/prior-clone.XXXXXX")
    log "Cloning prior repo ${PRIOR_REPO_URL} for context..."
    prior_branch=$(repo_url_branch "$PRIOR_REPO_URL")
    [ -z "$prior_branch" ] || clone_args+=(--branch "$prior_branch")
    if git clone "${clone_args[@]}" "$(git_remote_for "$PRIOR_REPO_URL")" "$tmp_clone" 2>>"${LOG_DIR}/gh-push.log" \
        && git -C "$tmp_clone" rev-parse -q --verify HEAD >/dev/null; then
        for pattern in "${artifacts[@]}"; do
            # The pattern is left unquoted so that it globs inside the clone.
            for path in "$tmp_clone"/$pattern; do
                [ -e "$path" ] || continue
                relative="${path#"$tmp_clone"/}"
                mkdir -p "$(dirname "${RUN_DIR}/prior/${relative}")"
                cp -r "$path" "${RUN_DIR}/prior/${relative}"
            done
        done
        log "Prior artifacts copied to ${RUN_DIR}/prior/"
    else
        log "WARN: Failed to clone ${PRIOR_REPO_URL} (unreachable or empty). Proceeding without prior context."
    fi
    rm -rf "$tmp_clone"
}

write_followup_context() {
    # followup-context.md: the follow-up fields, as state.md has them, and the feedback.
    local key value fields
    fields=$(followup_fields)
    {
        echo "---"
        while IFS=$'\t' read -r key value; do
            printf '%s: %s\n' "$key" "$value"
        done <<< "$fields"
        printf -- '---\n\n## User Feedback\n\n%s\n' "$FEEDBACK"
    } > "${RUN_DIR}/followup-context.md"
}

pinned_run() {
    local status mode
    if [ ! -f "${PIN_RUN_DIR}/state.md" ]; then
        log "ERROR: RESEARCHER_RUN_DIR=${PIN_RUN_DIR} has no state.md." >&2
        return 1
    fi
    status=$(state_field "${PIN_RUN_DIR}/state.md" status)
    mode=$(state_field "${PIN_RUN_DIR}/state.md" mode)
    if is_terminal_status "$status" || { [ -n "$mode" ] && [ "$mode" != "autonomous" ]; }; then
        log "ERROR: RESEARCHER_RUN_DIR=${PIN_RUN_DIR} is not a resumable autonomous run (status '${status}', mode '${mode:-?}')." >&2
        return 1
    fi
    printf '%s\n' "${PIN_RUN_DIR%/}"
}

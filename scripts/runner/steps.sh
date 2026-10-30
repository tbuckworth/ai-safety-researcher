# shellcheck shell=bash
# Running one workflow step: retries, waiting on external jobs, guard holds and pausing.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

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
    # Output decides, not the exit code: a guard that fails silently holds nothing
    # (a guard that must hold on failure says so itself). Bounded, so a hung
    # guard cannot stall the run between steps for ever.
    ( set +e +o pipefail; timeout 300 bash -c "$cmd" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 ) || true
}

hold_applies() {
    # A hold waits for this run's outstanding jobs (pausing mid-experiment is
    # what the guard must not do), unless it starts with "!": then it applies at
    # once, and the jobs keep running for the step that is redone on resume.
    case "$1" in
        !*) return 0 ;;
    esac
    [ -z "$(outstanding_jobs | tr -d ' ')" ]
}

hold_text() {
    local text="${1#!}"
    printf '%s\n' "${text# }"
}

run_step() {
    local step="$1"
    local prev_step
    prev_step=$(get_current_step)

    local attempt=0 refunds=0 total_waited=0
    local exit_code new_step new_status run_log hold
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

        # Success = the step advanced, reached a terminal status, OR (for the
        # audit step, which by design keeps current_step at 10 across rounds) the round
        # actually completed. We proxy "completed" with a clean provider exit and no
        # limit notice: a dropped connection exits non-zero AND leaves the status
        # unchanged, so without this gate a drop during Step 10 would return success
        # here and silently burn an AUDIT_ROUNDS increment upstream instead of retrying.
        if [ "$new_step" != "$prev_step" ] \
            || is_terminal_status "$new_status" \
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
                    # a stop ("!") doesn't wait for the jobs
                    hold=$(guard_hold)
                    if [ "${hold#!}" != "$hold" ]; then
                        hold=$(hold_text "$hold")
                        log "Guard: ${hold} (job(s) ${outstanding% } keep running; this step is redone on resume)"
                        upsert_frontmatter_field "last_pause_reason" "$(yaml_quote "$hold")" || true
                        return 2
                    fi
                    outstanding=$(outstanding_jobs)
                done
                if [ -n "${outstanding// /}" ]; then
                    log "Step ${step}: job(s) still outstanding after ${waited}s (cumulative ${total_waited}s of ${JOB_WAIT_MAX_SECONDS}s, run timeout ${TIMEOUT_SECONDS}s); giving up on waiting."
                else
                    refunds=$((refunds + 1))
                    attempt=$((attempt - 1))
                    log "Step ${step}: external job(s) finished after ~${waited}s; retrying without spending an attempt (refund ${refunds}/${JOB_WAIT_MAX_REFUNDS})."
                    hold=$(guard_hold)
                    if [ -n "$hold" ] && hold_applies "$hold"; then
                        hold=$(hold_text "$hold")
                        log "Guard: ${hold}"
                        upsert_frontmatter_field "last_pause_reason" "$(yaml_quote "$hold")" || true
                        return 2
                    fi
                    continue
                fi
            fi
        fi

        log "Step ${step} did not advance state (still at step ${prev_step}, exit ${exit_code}, attempt ${attempt}/${STEP_MAX_ATTEMPTS})."

        # A step may end on purpose without advancing because the guard now
        # holds the run (e.g. it asked for more budget): pause, don't retry.
        hold=$(guard_hold)
        if [ -n "$hold" ] && hold_applies "$hold"; then
            hold=$(hold_text "$hold")
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

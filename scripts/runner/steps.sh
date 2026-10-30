# shellcheck shell=bash
# Running one workflow step: retries, waiting on external jobs, guard holds and pausing.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

run_hook() {
    # run_hook CMD TIMEOUT: runs the hook command CMD (JOB_WAIT_CMD, GUARD_CMD)
    # in bash with "{run_id}" replaced by this run's id, stops it after TIMEOUT
    # seconds, prints its output and returns its exit status (124 when it was
    # stopped, which is also logged on stderr); an empty CMD prints nothing and
    # returns 0. The hook's stderr goes to HOOK_STDERR_FILE (see hook_error).
    local cmd="$1" limit="$2" run_id rc=0
    : > "$HOOK_STDERR_FILE"
    [ -n "$cmd" ] || return 0
    run_id=$(basename "$RUN_DIR")
    cmd=${cmd//\{run_id\}/$run_id}
    timeout "$limit" bash -c "$cmd" 2>"$HOOK_STDERR_FILE" || rc=$?
    if [ "$rc" -eq 124 ]; then
        log "WARN: hook stopped at its ${limit}s limit: ${cmd}" >&2
    fi
    return "$rc"
}

hook_error() {
    # The first non-blank line of the last hook's stderr (run_hook keeps it), or nothing.
    grep -v -m1 '^[[:space:]]*$' "$HOOK_STDERR_FILE" || true
}

outstanding_jobs() {
    # This run's outstanding external job ids (the first word of each line
    # JOB_WAIT_CMD prints), space-separated. When the hook fails, logs its error
    # on stderr and returns 1: whether jobs are outstanding is then unknown.
    local out rc=0
    out=$(run_hook "$JOB_WAIT_CMD" "$JOB_WAIT_CMD_TIMEOUT_SECONDS") || rc=$?
    if [ "$rc" -ne 0 ]; then
        log "WARN: the job-wait hook failed (exit ${rc}): $(hook_error); whether this run's jobs are outstanding is unknown." >&2
        return 1
    fi
    printf '%s\n' "$out" | awk '{print $1}' | tr '\n' ' '
}

guard_hold() {
    # The first non-blank line GUARD_CMD prints, or nothing. A guard that fails
    # (a non-zero exit, or stopped at its time limit) holds the run with
    # "guard failed: " and its first stderr line, "timed out" or its exit status.
    local out rc=0 why
    out=$(run_hook "$GUARD_CMD" "$GUARD_CMD_TIMEOUT_SECONDS") || rc=$?
    case "$rc" in
        0) printf '%s\n' "$out" | grep -v -m1 '^[[:space:]]*$' || true ;;
        124) echo "guard failed: timed out" ;;
        *)
            why=$(hook_error)
            echo "guard failed: ${why:-exit ${rc}}"
            ;;
    esac
}

pause_for_guard() {
    # pause_for_guard HOLD [DETAIL]: logs the guard's hold, without its leading
    # "!", and records it in state.md as last_pause_reason. The caller pauses.
    local reason="${1#!}"
    reason="${reason# }"
    log "Guard: ${reason}${2:+ ($2)}"
    set_state_field last_pause_reason "$(yaml_quote "$reason")"
}

guard_holds_run() {
    # True when the guard holds the run now, after pause_for_guard has recorded
    # why. A hold waits for this run's outstanding jobs (pausing mid-experiment
    # is what the guard must not do), and for an answer when the job-wait hook
    # cannot give one: it is logged, and the run carries on, so the step that
    # collects the jobs goes ahead. A hold starting with "!" applies at once,
    # and the jobs keep running for the step that is redone on resume.
    local hold outstanding
    hold=$(guard_hold)
    [ -n "$hold" ] || return 1
    case "$hold" in
        !*) pause_for_guard "$hold"; return 0 ;;
    esac
    if ! outstanding=$(outstanding_jobs); then
        log "Guard asked to hold (${hold}), but this run's jobs could not be checked; carrying on."
        return 1
    fi
    if [ -z "${outstanding// /}" ]; then
        pause_for_guard "$hold"
        return 0
    fi
    log "Guard asked to hold (${hold}), but job(s) ${outstanding% } are still outstanding; carrying on."
    return 1
}

wait_for_jobs() {
    # wait_for_jobs STEP: waits while this run's external jobs are outstanding,
    # or the job-wait hook cannot say whether they are ("unknown" below),
    # polling every JOB_WAIT_POLL_SECONDS, until they finish, the run times out,
    # or the step's waits add up to JOB_WAIT_MAX_SECONDS (counted in
    # STEP_JOB_WAITED, which run_step resets for each step). A stop from the
    # guard ("!") ends the wait at once through pause_for_guard, which logs the
    # stop and records last_pause_reason in state.md (run_step relies on this and
    # records nothing itself): the jobs keep running, and the step is redone on
    # resume. Sets JOB_WAIT_RESULT to none (no jobs were
    # outstanding), finished, gave-up or stopped.
    local step="$1" outstanding hold waited=0
    outstanding=$(outstanding_jobs) || outstanding="unknown"
    if [ -z "${outstanding// /}" ]; then
        JOB_WAIT_RESULT=none
        return 0
    fi
    log "Step ${step}: external job(s) still outstanding (${outstanding% }); waiting rather than spending an attempt."
    while [ -n "${outstanding// /}" ] \
        && [ "$STEP_JOB_WAITED" -lt "$JOB_WAIT_MAX_SECONDS" ] \
        && [ $(( $(date +%s) - START_TIME )) -lt "$TIMEOUT_SECONDS" ]; do
        sleep "$JOB_WAIT_POLL_SECONDS"
        waited=$((waited + JOB_WAIT_POLL_SECONDS))
        STEP_JOB_WAITED=$((STEP_JOB_WAITED + JOB_WAIT_POLL_SECONDS))
        hold=$(guard_hold)
        if [ "${hold#!}" != "$hold" ]; then
            pause_for_guard "$hold" "job(s) ${outstanding% } keep running; this step is redone on resume"
            JOB_WAIT_RESULT=stopped
            return 0
        fi
        outstanding=$(outstanding_jobs) || outstanding="unknown"
    done
    if [ -n "${outstanding// /}" ]; then
        log "Step ${step}: job(s) still outstanding after ${waited}s (cumulative ${STEP_JOB_WAITED}s of ${JOB_WAIT_MAX_SECONDS}s, run timeout ${TIMEOUT_SECONDS}s); giving up on waiting."
        JOB_WAIT_RESULT=gave-up
    else
        log "Step ${step}: external job(s) finished after ~${waited}s."
        JOB_WAIT_RESULT=finished
    fi
}

run_step() {
    local step="$1"
    local prev_step
    prev_step=$(get_current_step)

    # An attempt is spent when the step ends without advancing, unless it ended
    # while this run's external jobs were running and they have since finished
    # (at most JOB_WAIT_MAX_REFUNDS times): then the attempt is made again.
    local spent=0 refunds=0 attempt
    local exit_code new_step new_status run_log incomplete
    STEP_JOB_WAITED=0
    while [ "$spent" -lt "$STEP_MAX_ATTEMPTS" ]; do
        attempt=$((spent + 1))
        run_log="${LOG_DIR}/step-${step}-attempt-${attempt}-$(date +%Y%m%d-%H%M%S).log"
        if [ "$attempt" -eq 1 ]; then
            log "Starting step ${step}..."
        else
            log "Retrying step ${step} (attempt ${attempt}/${STEP_MAX_ATTEMPTS}) after an incomplete run (e.g. a dropped connection)..."
            sleep "$RETRY_DELAY_SECONDS"
        fi

        # A step that stops without progress says why in step_incomplete (the
        # general rules of commands/researcher-auto-step.md); each attempt
        # starts without it.
        if [ -n "$(state_field "${RUN_DIR}/state.md" step_incomplete)" ]; then
            set_state_field step_incomplete '""'
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
        incomplete=$(state_field "${RUN_DIR}/state.md" step_incomplete || true)

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
        # pass for a completed audit round (the audit keeps current_step at AUDIT_STEP).
        local last_line limit_hit=false
        last_line=$({ grep -v '^[[:space:]]*$' "$run_log" || true; } | tail -1)
        if printf '%s\n' "$last_line" | grep -qE "^[[:space:]]*(You've hit your (session|usage) limit\b|(Claude )?(AI )?[Uu]sage limit reached\b)"; then
            limit_hit=true
        fi

        # Success = the step advanced, reached a terminal status, OR (for the
        # audit step, which by design keeps current_step at AUDIT_STEP across rounds) the round
        # actually completed. We proxy "completed" with a clean provider exit and no
        # limit notice: a dropped connection exits non-zero AND leaves the status
        # unchanged, so without this gate a drop during the audit would return success
        # here and silently burn an AUDIT_ROUNDS increment upstream instead of retrying.
        # A step that recorded step_incomplete did not finish, whatever its status.
        if [ -n "$incomplete" ]; then
            log "Step ${step} stopped without progress: ${incomplete}"
        elif [ "$new_step" != "$prev_step" ] \
            || is_terminal_status "$new_status" \
            || { [ "$limit_hit" = false ] \
                 && [ "$exit_code" -eq 0 ] \
                 && [ "$step" -eq "$AUDIT_STEP" ] \
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
        JOB_WAIT_RESULT=none
        if [ "$refunds" -lt "$JOB_WAIT_MAX_REFUNDS" ]; then
            wait_for_jobs "$step"
        fi
        case "$JOB_WAIT_RESULT" in
            stopped) return 2 ;;
            finished)
                refunds=$((refunds + 1))
                log "Step ${step}: retrying without spending an attempt (refund ${refunds}/${JOB_WAIT_MAX_REFUNDS})."
                ;;
            *)
                spent=$attempt
                log "Step ${step} did not advance state (still at step ${prev_step}, exit ${exit_code}, attempt ${attempt}/${STEP_MAX_ATTEMPTS})."
                ;;
        esac

        # A step may end on purpose without advancing because the guard now
        # holds the run (e.g. it asked for more budget): pause, don't retry.
        if guard_holds_run; then
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

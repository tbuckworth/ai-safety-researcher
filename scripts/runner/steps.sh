# shellcheck shell=bash
# Running one workflow step: retries, waiting on external jobs, guard holds and
# pausing; and the session that writes next-steps.md for a run that ended without one.
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

review_run() {
    python3 "${SCRIPT_DIR}/methods_review.py" "$1" "$RUN_DIR"
}

has_experiment_results() {
    compgen -G "${RUN_DIR}/experiments/exp-*/results.md" > /dev/null
}

review_evidence() {
    # A scientific objection is a completed critique for the auditor/reader.
    # A process error leaves the evidence unchecked.
    local rc=0
    has_experiment_results || return 0
    review_run evidence || rc=$?
    case "$rc" in
        0) return 0 ;;
        3|4) log "Evidence reviewer raised objections; the audit and final reader must resolve or disclose them." ;;
        *) return "$rc" ;;
    esac
}

set_review_hold() {
    log "Holding the run for review: $1"
    set_state_field last_pause_reason "$(yaml_quote "$1")"
}

reopen_declined_methods() {
    # On a resume: a methods-stop.md that only the automatic approver's former
    # one-revision limit wrote (methods_review.py reopen-declined decides, and
    # moves it and the deliverables written after it into superseded/<time>/)
    # no longer stands: the run re-enters Step 8, which takes the approver's last
    # decision under the current rule (docs/AUTONOMOUS.md, Resuming a run).
    # Returns 0 when it reopened the run, 1 when the stop stands or there is
    # none, and 2, after logging why, when the check failed: the run is then
    # left as it was, since resuming it under the former stop is what this
    # check is for.
    local out
    [ -f "${RUN_DIR}/methods-stop.md" ] || return 1
    if ! out=$(review_run reopen-declined); then
        log "ERROR: could not check whether methods-stop.md came only from the approver's former revision limit (the error is above). The run is left as it was; resume it once the check works."
        return 2
    fi
    if [ "$(jq -r '.reopened' <<< "$out")" != true ]; then
        log "methods-stop.md stands: $(jq -r '.why' <<< "$out")."
        return 1
    fi
    log "Re-entering Step 8 under the current rule: $(jq -r '.reason' <<< "$out"). The superseded files are in $(jq -r '.moved_to' <<< "$out")."
    set_state_field methods_reopened "$(yaml_quote "$(jq -r '"\(.reason); superseded files in \(.moved_to)"' <<< "$out")")"
    set_state_field current_step 7
    set_status methods_reopened
    set_state_field review_hold '""'
    set_state_field audit_round 0
    set_state_field audit_exit_reason '""'
}

release_held_report() {
    # On a resume: a run whose Step 11 held its draft at the final reader's round
    # cap (the former rule set review_hold there) has finished Step 11 but for the
    # release. When the current draft is the one the reader's last round read
    # (verify-presentation exits 5), Step 11 is marked done, and the runner then
    # releases that draft with its open blocking findings.
    local rc=0
    [ "$(get_current_step)" = "$AUDIT_STEP" ] && [ "$(get_status)" = audit_complete ] || return 0
    review_run verify-presentation > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 5 ] || return 0
    log "Step 11 held its draft at the final reader's round cap; under the current rule that draft is released with its open blocking findings."
    set_state_field current_step "$REPORT_STEP"
    set_status complete
}

release_at_review_cap() {
    # After the final reader's check exited 5 (its round cap, blocking findings
    # open): true when the current draft is the one its last round read
    # (verify-presentation exits 5 as well; a review receipt recorded since, such
    # as the release-time evidence round's, leaves it the draft the reader read),
    # which an autonomous run releases with those findings listed, and the open
    # ones of such a later review (record_cap_findings); false when the draft
    # changed after that round, so that no reviewed draft is left to release.
    local rc=0
    review_run verify-presentation > /dev/null || rc=$?
    [ "$rc" -eq 5 ] || return 1
    log "The final reader reached its round cap with blocking findings open: releasing the draft it read, with those findings (and those of any review recorded since) listed in open-review-findings.md."
}

# shellcheck disable=SC2034 # CAP_NOTES is read by researcher-cron.sh (the outcome's notes).
record_cap_findings() {
    # Lists the blocking findings the run went past at a round cap (the
    # automatic approver's, when the experiments ran on the revision it reviewed
    # last; the final reader's, when its last draft was released) from
    # methods_review.py cap-findings: in open-review-findings.md, in state.md
    # (open_review_findings) and in CAP_NOTES, the outcome's notes, which the
    # email and the issue comment carry. When the listing fails, the run goes on
    # and CAP_NOTES says so instead.
    local out ids
    CAP_NOTES=()
    if ! out=$(review_run cap-findings); then
        log "ERROR: could not list the review findings left open at a round cap (the error is above)."
        CAP_NOTES=("the review findings left open at a round cap could not be listed (methods_review.py cap-findings failed; see the run log)")
        return 0
    fi
    [ -n "$(jq -r '.markdown' <<< "$out")" ] || return 0
    jq -r '.markdown' <<< "$out" > "${RUN_DIR}/open-review-findings.md"
    ids=$(jq -r '.ids | join(", ")' <<< "$out")
    set_state_field open_review_findings "$(yaml_quote "$ids")"
    mapfile -t CAP_NOTES < <(jq -r '.notes[]' <<< "$out")
    log "Review findings left open at a round cap: ${ids} (open-review-findings.md)."
}

run_step() {
    local step="$1"
    local prev_step
    prev_step=$(get_current_step)

    # An attempt is spent when the step ends without advancing, unless it ended
    # while this run's external jobs were running and they have since finished
    # (at most JOB_WAIT_MAX_REFUNDS times): then the attempt is made again.
    local spent=0 refunds=0 attempt
    local exit_code new_step new_status run_log incomplete evidence_pid retained_data_only
    STEP_JOB_WAITED=0
    while [ "$spent" -lt "$STEP_MAX_ATTEMPTS" ]; do
        attempt=$((spent + 1))
        run_log="${LOG_DIR}/step-${step}-attempt-${attempt}-$(date +%Y%m%d-%H%M%S).log"
        # shellcheck disable=SC2034 # provider.sh includes the path in the next-steps handoff.
        LAST_STEP_LOG="$run_log"
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
        if [ "$step" = 1 ]; then
            local weekly
            if weekly=$(python3 "${SCRIPT_DIR}/harness_lessons.py" weekly "$RUN_DIR"); then
                log "Weekly harness lesson review: ${weekly}"
            else
                log "WARN: could not check the weekly harness lesson register."
                set_state_field kb_weekly_step1 '"failed (could not read the weekly harness lesson register)"'
            fi
        fi

        # Check on every attempt, including a resumed or manually advanced run.
        if [ "$step" = 9 ] && ! review_run verify; then
            if ! has_experiment_results && ! compgen -G "${RUN_DIR}/experiments/exp-*/started" >/dev/null \
                && [ "$(state_field "${RUN_DIR}/state.md" methods_gate_replanned)" != true ]; then
                log "No current methods approval; returning to design before any experiment launch."
                set_state_field methods_gate_replanned true
                set_state_field current_step 5
                set_status methods_review_required
                return 0
            fi
            set_review_hold "No approval for the current methods. Review the changed design before further execution."
            return 2
        fi
        retained_data_only=false
        if [ "$step" = "$AUDIT_STEP" ] && has_experiment_results && ! review_run verify; then
            log "Prospective methods approval could not be verified. Running a retrospective audit of retained data only."
            retained_data_only=true
        fi
        if [ "$step" = "$REPORT_STEP" ] && ! review_evidence; then
            set_review_hold "The independent evidence review could not run. Resume the report once the reviewer is available."
            return 2
        fi
        # Start the read-only critique alongside the active audit. The step
        # hub reads the same cached review before deciding on any remediation.
        evidence_pid=""
        if [ "$step" = "$AUDIT_STEP" ] && has_experiment_results; then
            review_evidence > "${run_log%.log}-evidence.log" 2>&1 &
            evidence_pid=$!
        fi
        cd "$REPO_DIR"
        set +e
        run_step_provider "$step" "$retained_data_only" 2>&1 | tee "$run_log"
        exit_code=${PIPESTATUS[0]}
        set -e
        if [ -n "$evidence_pid" ] && ! wait "$evidence_pid"; then
            set_review_hold "The independent evidence review failed. See ${run_log%.log}-evidence.log."
            return 2
        fi
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
        # leave the state resumable: a later invocation continues this step.
        # Match only a provider-emitted limit notice: the CLI prints it as its
        # own final line. Scanning the whole transcript would misread a run that
        # merely *writes about* rate limits (e.g. authoring retry logic) as a
        # pause, and such a step would then loop forever, never failing.
        # The CLI reports session and weekly caps as "You've hit your ...
        # limit", and may also print "Claude AI usage limit reached|1754060400".
        # Neither the exit code nor a reset clause is required: the CLI can
        # print the notice and still exit 0.
        # Transient "rate limit exceeded" errors are deliberately excluded:
        # those are retryable, and the retry loop is the right response.
        # Detected BEFORE the success gate: a notice with exit 0 must never
        # pass for a completed audit round (the audit keeps current_step at AUDIT_STEP).
        local last_line limit_hit=false
        last_line=$({ grep -v '^[[:space:]]*$' "$run_log" || true; } | tail -1)
        if printf '%s\n' "$last_line" | grep -qE "^[[:space:]]*(You've hit your (session|usage|weekly) limit\b|(Claude )?(AI )?[Uu]sage limit reached\b)"; then
            limit_hit=true
        fi

        # Success = the step advanced, reached a terminal status, OR (for the
        # audit step, which by design keeps current_step at AUDIT_STEP across rounds) the round
        # actually completed. We proxy "completed" with a clean provider exit and no
        # limit notice: a dropped connection exits non-zero AND leaves the status
        # unchanged, so without this gate a drop during the audit would return success
        # here and silently burn an AUDIT_ROUNDS increment upstream instead of retrying.
        # A step that recorded step_incomplete did not finish, whatever its status.
        if [ -n "$(state_field "${RUN_DIR}/state.md" review_hold)" ]; then
            local reason
            reason=$(state_field "${RUN_DIR}/state.md" review_hold)
            set_state_field review_hold '""'
            set_review_hold "$reason"
            return 2
        fi
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
            set_state_field last_pause_reason '"provider usage/session limit reached"'
            log "Step ${step} stopped: provider usage/session limit reached."
            log "${last_line}"
            log "Run left resumable at step ${prev_step} (status: ${new_status}). Re-run this script after the limit resets."
            return 2
        fi

        # An agent that submitted cluster work and ended its turn while that work
        # is still queued or running has not failed: it is waiting. Spending
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

write_next_steps() {
    # Runs one session of the run's backend that writes RUN_DIR/next-steps.md
    # (commands/researcher-auto-next-steps.md), for a run that ended without
    # one, and logs it; its output goes to LOG_DIR/next-steps-<time>.log.
    # Returns non-zero, after logging why, when the session fails or writes no
    # next-steps.md, or an empty one; what a failed session wrote is removed,
    # so that it is not published as the run's plan.
    local session_log rc=0
    session_log="${LOG_DIR}/next-steps-$(date +%Y%m%d-%H%M%S).log"
    log "No next-steps.md after the workflow (status ${STATUS}); writing it with ${BACKEND} ${MODEL} (output in ${session_log})..."
    cd "$REPO_DIR"
    set +e
    run_next_steps_provider 2>&1 | tee "$session_log"
    rc=${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
        rm -f "${RUN_DIR}/next-steps.md"
        log "ERROR: the next-steps session failed (exit ${rc}; its output is in ${session_log}); removed what it wrote, so the run has no next-steps.md."
        return 1
    fi
    if [ ! -s "${RUN_DIR}/next-steps.md" ]; then
        rm -f "${RUN_DIR}/next-steps.md"
        log "ERROR: the next-steps session wrote no next-steps.md, or an empty one (its output is in ${session_log})."
        return 1
    fi
    log "Wrote ${RUN_DIR}/next-steps.md."
}

# shellcheck disable=SC2034 # These three flags control the wrapper after the step loop.
pause_run() {
    # Keep provider, guard and review holds resumable and preserve the issue claim.
    log "Run PAUSED at step $1. Skipping repo publish, email, and issue update."
    log "Resume with the same command after the recorded hold is resolved."
    SKIP_PUBLISH=true
    SKIP_EMAIL=true
    PAUSED=true
}

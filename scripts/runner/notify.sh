# shellcheck shell=bash
# Reporting the outcome: the results email and the GitHub issue comment and labels.
# Sourced by scripts/researcher-cron.sh and scripts/send-run-report.sh (the
# email alone); the functions use their globals.

outcome_is_success() {
    # researcher_lib.py's compute_outcome decides which outcomes succeed.
    [ "$(jq -r '.success' <<< "$OUTCOME_JSON")" = true ]
}

# shellcheck disable=SC2034 # The globals it sets are read by provider.sh and the scripts.
email_settings() {
    # Sets the globals of the results email: EMAIL_TO (RESEARCHER_EMAIL_TO, an
    # address or agent-mail's `titus`), SEND_EMAIL (the helper that sends a
    # draft), REPORT_LIB, the mailroom's commands (AGENT_MAIL, AGENT_USAGE,
    # AGENT_STATUS; mailroom_tool), the Claude writer's CLI and model (a Claude
    # run's own model, else RESEARCHER_EMAIL_CLAUDE_MODEL) and each writer's
    # time limit, EMAIL_TIMEOUT_SECONDS. Needs select_backend first; exits 2,
    # saying why, when a setting is missing or the time limit is not a whole
    # number of at least 1.
    require_config RESEARCHER_EMAIL_TO RESEARCHER_EMAIL_CLAUDE_MODEL RESEARCHER_EMAIL_TIMEOUT_SECONDS || exit 2
    if ! [[ "$RESEARCHER_EMAIL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: RESEARCHER_EMAIL_TIMEOUT_SECONDS must be a whole number of at least 1, got '${RESEARCHER_EMAIL_TIMEOUT_SECONDS}'." >&2
        exit 2
    fi
    EMAIL_TO="$RESEARCHER_EMAIL_TO"
    EMAIL_TIMEOUT_SECONDS="$RESEARCHER_EMAIL_TIMEOUT_SECONDS"
    SEND_EMAIL="${SCRIPT_DIR}/send-results-email.sh"
    REPORT_LIB="${SCRIPT_DIR}/results_report.py"
    AGENT_MAIL=$(mailroom_tool agent-mail)
    AGENT_USAGE=$(mailroom_tool agent-usage)
    AGENT_STATUS=$(mailroom_tool agent-status)
    EMAIL_CLAUDE_BIN="$RESEARCHER_CLAUDE_BIN"
    if [ "$BACKEND" = "claude" ]; then
        EMAIL_CLAUDE_MODEL="$MODEL"
    else
        EMAIL_CLAUDE_MODEL="$RESEARCHER_EMAIL_CLAUDE_MODEL"
    fi
}

# shellcheck disable=SC2034 # EMAIL_WRITER is read by researcher-cron.sh.
send_email() {
    # The results email, from the agents' mail account (agent-mail), never from
    # the recipient's own Gmail. It is written by the first writer that can, in
    # the mailroom's login order (read_report_logins): on a Claude login, a
    # session writes it and sends it itself (reviewed; Titus's reply comes back
    # to it); on Codex, Codex writes it and it is sent unrouted (no review,
    # replies go to the orchestrator). A writer that fails, a usage limit or a
    # time limit included, passes it to the next, and why is logged. When none
    # is left, the report is assembled from the run's saved files with no model
    # (results_report.py template) and sent unrouted; if even that fails, a
    # plain-text notice goes. Records the outcome as a status note. The writers
    # run in CONTINUE_DIR, the checkout in which the email says to continue the
    # run, so that a reply resumes the session there. Sets EMAIL_WRITER (who
    # wrote what went out); returns non-zero, after logging why, only when
    # nothing was sent.
    local entry kind name config_dir RUN_LABEL="run ${RUN_ID}"
    EMAIL_FAILURES=()
    EMAIL_WRITER=""
    if [ -n "$(issue_url)" ]; then
        RUN_LABEL="run ${RUN_ID} for #${ISSUE_NUMBER}"
    fi
    cd "$CONTINUE_DIR"
    if read_report_logins; then
        for entry in ${REPORT_LOGINS[@]+"${REPORT_LOGINS[@]}"}; do
            IFS=$'\t' read -r kind name config_dir <<< "$entry"
            if write_email_with "$kind" "$name" "$config_dir"; then
                EMAIL_WRITER="$name"
                note_status "Results email for ${RUN_LABEL} sent (outcome ${FINAL_OUTCOME}), written on the ${name} login$(failures_note)."
                return 0
            fi
        done
    fi
    if [ "${#EMAIL_FAILURES[@]}" -eq 0 ]; then
        EMAIL_FAILURES+=("the mailroom's login order names no login")
    fi
    if send_template_email; then
        EMAIL_WRITER=template
        note_status "Results email for ${RUN_LABEL} sent (outcome ${FINAL_OUTCOME}), assembled without a model$(failures_note)."
        return 0
    fi
    if send_plain_notice; then
        EMAIL_WRITER=notice
        note_status "Results email for ${RUN_LABEL} NOT written; a plain-text notice went instead$(failures_note). Re-send: ${CONTINUE_DIR}/scripts/send-run-report.sh ${RUN_DIR}"
        return 0
    fi
    log "ERROR: nothing was sent to ${EMAIL_TO} about this run. Results remain in ${RUN_DIR}; ${CONTINUE_DIR}/scripts/send-run-report.sh ${RUN_DIR} sends the report once the cause is fixed."
    note_status "Results email for ${RUN_LABEL} NOT SENT$(failures_note). Results remain in ${RUN_DIR}; re-send with ${CONTINUE_DIR}/scripts/send-run-report.sh ${RUN_DIR}"
    return 1
}

# shellcheck disable=SC2034 # REPORT_UNSET is read by provider.sh (without_inherited_session).
read_report_logins() {
    # Sets REPORT_LOGINS (one "kind<TAB>name<TAB>config dir" per writer) and
    # REPORT_UNSET (the inherited variables a writer's CLI must not take) from
    # the mailroom's login order (results_report.py logins, through AGENT_USAGE).
    # Returns non-zero, after logging why and adding it to EMAIL_FAILURES, when
    # the order cannot be read.
    local out
    REPORT_LOGINS=()
    REPORT_UNSET=()
    if [ ! -x "$AGENT_USAGE" ]; then
        email_failed "login order" "agent-usage (the mailroom's ${AGENT_USAGE}) is not installed, so no login can be chosen"
        return 1
    fi
    if ! out=$(python3 "$REPORT_LIB" logins --agent-usage "$AGENT_USAGE" 2>&1); then
        email_failed "login order" "the mailroom's login order could not be read: $(printf '%s\n' "$out" | tail -1)"
        return 1
    fi
    mapfile -t REPORT_UNSET < <(jq -r '.unset[]' <<< "$out")
    mapfile -t REPORT_LOGINS < <(jq -r '.logins[] | [.kind, .name, .config_dir] | @tsv' <<< "$out")
    log "The results email's writers, in the mailroom's login order: $(jq -r '[.logins[].name] | join(", ")' <<< "$out"), then the report with no model."
}

clear_email_draft() {
    rm -f "${RUN_DIR}/email-draft.html" "${RUN_DIR}/email-subject.txt" "${RUN_DIR}/email-images.txt" \
        "${RUN_DIR}/email-choices.json" "${RUN_DIR}/.email-sent" "${RUN_DIR}/.email-held"
}

email_failed() {
    # email_failed WRITER WHY [LOG]: logs that WRITER could not deliver the
    # email, and where its output is (LOG), and adds "WRITER: WHY" to
    # EMAIL_FAILURES, which the report with no model shows the reader.
    log "WARN: the results email was not delivered by ${1}: ${2}${3:+; its output is in ${3}}"
    EMAIL_FAILURES+=("${1}: ${2}")
}

failures_note() {
    # The failures so far, for a status note: "; before it: A; B", or nothing.
    local joined
    if [ "${#EMAIL_FAILURES[@]}" -eq 0 ]; then
        return 0
    fi
    printf -v joined '%s; ' "${EMAIL_FAILURES[@]}"
    printf '; before it: %s' "${joined%; }"
}

write_email_with() {
    # write_email_with KIND NAME CONFIG_DIR: the email written by one writer of
    # the login order (KIND claude or codex; NAME the login; CONFIG_DIR a Claude
    # login's config dir) and sent. A Claude session that stops without sending
    # has its draft sent as that session; a Codex draft goes unrouted. Returns 0
    # when it went (or the review holds it: the mailroom then sends it after its
    # fallback wait); otherwise 1, after email_failed, with any draft removed so
    # the next writer starts afresh.
    local kind="$1" name="$2" config_dir="$3" email_log rc
    email_log="${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S)-${name}.log"
    clear_email_draft
    EMAIL_SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
    set +e
    case "$kind" in
        claude)
            log "Writing and sending the results email with Claude ${EMAIL_CLAUDE_MODEL} on the ${name} login (session ${EMAIL_SESSION})..."
            run_email_claude "$config_dir" 2>&1 | tee "$email_log"
            rc=${PIPESTATUS[0]}
            ;;
        codex)
            log "Writing the results email with Codex ${CODEX_FAST_MODEL}, to send unrouted..."
            run_email_codex 2>&1 | tee "$email_log"
            rc=${PIPESTATUS[0]}
            ;;
        *)
            set -e
            email_failed "$name" "unknown kind of writer '${kind}'"
            return 1
            ;;
    esac
    set -e
    if email_delivered; then
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        email_failed "$name" "the writer failed (exit ${rc}: $(tail -1 "$email_log" | cut -c1-200))" "$email_log"
        clear_email_draft
        return 1
    fi
    if [ ! -s "${RUN_DIR}/email-draft.html" ] || [ ! -s "${RUN_DIR}/email-subject.txt" ]; then
        email_failed "$name" "the writer wrote no email-draft.html and email-subject.txt"
        clear_email_draft
        return 1
    fi
    if [ "$kind" = claude ]; then
        log "The email session stopped without sending; sending its draft as that session."
        send_draft "$name" session
    else
        send_draft "$name" unrouted
    fi
}

email_delivered() {
    # True, after logging it, when the helper recorded a sent email
    # (.email-sent) or one the pre-send review holds (.email-held).
    if [ -s "${RUN_DIR}/.email-sent" ]; then
        log "Email sent to ${EMAIL_TO} from the agents' account: $(cut -f2 "${RUN_DIR}/.email-sent")"
        return 0
    fi
    if [ -s "${RUN_DIR}/.email-held" ]; then
        log "Note: the pre-send review held the email; the mailroom sends it unchanged after its fallback wait."
        return 0
    fi
    return 1
}

send_draft() {
    # send_draft WRITER MODE: sends the run's draft with the helper, as the
    # email session (MODE session) or unrouted. Returns 0 when it went or is
    # held, else 1 after email_failed; the draft stays in the run directory.
    local writer="$1" mode="$2" email_log rc
    email_log="${LOG_DIR}/email-send-$(date +%Y%m%d-%H%M%S)-${writer}.log"
    set +e
    if [ "$mode" = session ]; then
        CLAUDE_CODE_SESSION_ID="$EMAIL_SESSION" "$SEND_EMAIL" "$RUN_DIR" 2>&1 | tee "$email_log"
    else
        "$SEND_EMAIL" "$RUN_DIR" --unrouted 2>&1 | tee "$email_log"
    fi
    rc=${PIPESTATUS[0]}
    set -e
    if email_delivered; then
        return 0
    fi
    case "$rc" in
        2) email_failed "$writer" "send-results-email.sh refused to send it (exit 2): an input is missing or invalid" "$email_log" ;;
        *) email_failed "$writer" "sending it failed (exit ${rc})" "$email_log" ;;
    esac
    return 1
}

send_template_email() {
    # The report assembled with no model from the run's saved files
    # (results_report.py template), sent unrouted. Returns 0 when it went, else
    # 1 after email_failed.
    local why=() failure
    log "WARN: no model could write the results email; assembling it from the run's saved files."
    clear_email_draft
    for failure in "${EMAIL_FAILURES[@]}"; do
        why+=(--why "$failure")
    done
    if ! python3 "$REPORT_LIB" template --run-dir "$RUN_DIR" --issue-url "$(issue_url)" \
            --host-alias "$HOST_ALIAS" --plugin-dir "$CONTINUE_DIR" --agent "$PROVIDER_BIN" \
            --continue-command "$CONTINUE_COMMAND" --agent-label "$AGENT_LABEL" "${why[@]}"; then
        email_failed template "the report could not be assembled (results_report.py's error is above)"
        clear_email_draft
        return 1
    fi
    send_draft template unrouted
}

send_plain_notice() {
    # A plain-text notice in place of the report, sent unrouted with agent-mail
    # directly: what ran, its outcome, where the results are and why no report
    # was written. Built from the runner's own facts, so it goes even when the
    # run directory's files cannot be read. Returns 0 when it went, else 1
    # after email_failed.
    local body rc url=""
    if ! body=$(mktemp "${TMPDIR:-/tmp}/researcher-notice.XXXXXX"); then
        email_failed notice "could not create a temporary file for the notice"
        return 1
    fi
    [ -s "${RUN_DIR}/.repo_url" ] && url=$(cat "${RUN_DIR}/.repo_url")
    {
        printf '**What this is:** the autonomous researcher finished %s with the outcome %s, but its results report could not be written, so this notice stands in for it.\n\n' \
            "$RUN_LABEL" "${FINAL_OUTCOME:-unknown}"
        if [ -n "$url" ]; then
            printf '**Where the results are:** %s (code, paper and records).\n\n' "$url"
        else
            printf '**Where the results are:** only in the run directory on %s: %s\n\n' "$HOST_ALIAS" "$RUN_DIR"
        fi
        printf '**Why there is no report:**\n\n'
        printf -- '- %s\n' "${EMAIL_FAILURES[@]}"
        # shellcheck disable=SC2016 # Backticks fence the command in the Markdown notice.
        printf '\n**To send the report once that is fixed**, on %s:\n\n```\n%s/scripts/send-run-report.sh %s\n```\n' \
            "$HOST_ALIAS" "$CONTINUE_DIR" "$RUN_DIR"
    } > "$body"
    set +e
    "$AGENT_MAIL" send --to "$EMAIL_TO" --subject "[Auto-Research] Results report not written: ${RUN_LABEL} (${FINAL_OUTCOME:-unknown})" \
        --body-file "$body" --unrouted
    rc=$?
    set -e
    rm -f "$body"
    if [ "$rc" -ne 0 ]; then
        email_failed notice "agent-mail failed (exit ${rc}; its error is above)"
        return 1
    fi
    log "A plain-text notice went to ${EMAIL_TO} in place of the results email."
}

note_status() {
    # note_status TEXT: records TEXT in the mailroom's status log (agent-status
    # note, from the run directory, so no session in the plugin directory is
    # credited with it); logs a warning when it cannot.
    log "$1"
    if [ ! -x "$AGENT_STATUS" ]; then
        log "WARN: agent-status (${AGENT_STATUS}) is not installed; the line above is not in the status log."
        return 0
    fi
    if ! (cd "$RUN_DIR" && "$AGENT_STATUS" note "researcher: $1") >/dev/null 2>&1; then
        log "WARN: agent-status note failed; the line above is not in the status log."
    fi
}

post_issue_comment() {
    # post_issue_comment NUMBER FILE: posts FILE as a comment on issue NUMBER;
    # returns non-zero, after logging, when gh fails (its error is in the log).
    local number="$1" body_file="$2"
    if ! gh issue comment "$number" --repo "$TASKS_REPO" --body-file "$body_file" >/dev/null; then
        log "ERROR: could not comment on issue #${number} (gh's error is above)."
        return 1
    fi
}

comment_on_issues() {
    # Posts the findings comment (researcher_lib.py issue-comment) on
    # ISSUE_NUMBER and, for a follow-up, on PARENT_ISSUE. Every part is
    # attempted; returns non-zero, after logging, when any of them failed. When
    # the findings cannot be written up, a short note saying so is posted.
    local file rc=0 on_branch=false
    # The results are on a branch only when the follow-up continued the prior repo.
    continues_prior_repo && on_branch=true
    if ! file=$(mktemp "${TMPDIR:-/tmp}/researcher-comment.XXXXXX"); then
        log "ERROR: could not create a temporary file for the issue comment; no comment was posted."
        return 1
    fi
    if ! python3 "$LIB" issue-comment \
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
            --followup "$on_branch" \
            --visibility "$PUBLISHED_VISIBILITY" > "$file"; then
        log "ERROR: the findings comment could not be written (the error is above); posting a short note instead."
        rc=1
        # shellcheck disable=SC2016 # Backticks mark code spans in the Markdown comment.
        printf 'Autonomous research run `%s` finished with outcome `%s` (the findings summary could not be generated; see the cron log).\n' \
            "$RUN_ID" "$FINAL_OUTCOME" > "$file" \
            || { log "ERROR: could not write the note either; no comment was posted."; rm -f "$file"; return 1; }
    fi
    post_issue_comment "$ISSUE_NUMBER" "$file" || rc=1
    if [ "$IS_FOLLOWUP" = true ] && [ -n "$PARENT_ISSUE" ] && [ "$PARENT_ISSUE" != "none" ]; then
        if { printf 'Follow-up #%s finished.\n\n' "$ISSUE_NUMBER"; cat "$file"; } > "${file}.parent"; then
            post_issue_comment "$PARENT_ISSUE" "${file}.parent" || rc=1
        else
            log "ERROR: could not write the comment for parent issue #${PARENT_ISSUE}; it was not posted."
            rc=1
        fi
        rm -f "${file}.parent"
    fi
    rm -f "$file"
    return "$rc"
}

mark_issue_processed() {
    # Swaps ISSUE_NUMBER's PROCESSING_LABEL for PROCESSED_LABEL. Both edits are
    # attempted; returns non-zero, after logging, when either failed.
    local rc=0
    gh issue edit "$ISSUE_NUMBER" --repo "$TASKS_REPO" --remove-label "$PROCESSING_LABEL" || rc=1
    gh issue edit "$ISSUE_NUMBER" --repo "$TASKS_REPO" --add-label "$PROCESSED_LABEL" || rc=1
    if [ "$rc" -ne 0 ]; then
        log "ERROR: could not move issue #${ISSUE_NUMBER} from ${PROCESSING_LABEL} to ${PROCESSED_LABEL} (gh's error is above)."
        return 1
    fi
    log "Updated issue #${ISSUE_NUMBER}: ${PROCESSING_LABEL} -> ${PROCESSED_LABEL}"
}

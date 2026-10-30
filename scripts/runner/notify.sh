# shellcheck shell=bash
# Reporting the outcome: the results email and the GitHub issue comment and labels.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

outcome_is_success() {
    # researcher_lib.py's compute_outcome decides which outcomes succeed.
    [ "$(jq -r '.success' <<< "$OUTCOME_JSON")" = true ]
}

send_email() {
    # A Claude session (EMAIL_CLAUDE_BIN) writes the results email and sends it;
    # a draft it wrote but did not send is sent as that session. Only when the
    # Claude CLI is not installed does a Codex run write it with Codex, sent
    # --unrouted. Returns non-zero, after logging why, when nothing was sent (a
    # failed email session counts, whatever it wrote); any draft is kept.
    local email_log compose_status send_status
    email_log="${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S).log"
    cd "$REPO_DIR"
    rm -f "${RUN_DIR}/email-draft.html" "${RUN_DIR}/email-subject.txt" "${RUN_DIR}/email-images.txt" \
        "${RUN_DIR}/.email-sent"
    EMAIL_SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
    set +e
    if command -v "$EMAIL_CLAUDE_BIN" >/dev/null 2>&1; then
        log "Writing and sending the results email with Claude ${EMAIL_CLAUDE_MODEL} (session ${EMAIL_SESSION})..."
        run_email_claude 2>&1 | tee "$email_log"
        compose_status=${PIPESTATUS[0]}
        EMAIL_MODE=session
    else
        # Only a Codex run gets here: a Claude run's CLI was checked at startup.
        log "WARN: no Claude CLI (${EMAIL_CLAUDE_BIN}) to write the email; writing it with ${BACKEND}, to send unreviewed."
        run_email_provider 2>&1 | tee "$email_log"
        compose_status=${PIPESTATUS[0]}
        EMAIL_MODE=unrouted
    fi
    set -e

    if [ -s "${RUN_DIR}/.email-sent" ]; then
        log "Email sent to ${EMAIL_TO} from the agents' account: $(cut -f2 "${RUN_DIR}/.email-sent")"
        return 0
    fi
    if [ "$compose_status" -ne 0 ]; then
        log "ERROR: the email writer (${EMAIL_MODE}) failed (exit ${compose_status}; its output is in ${email_log}); nothing was sent."
        return 1
    fi
    if [ ! -s "${RUN_DIR}/email-draft.html" ] || [ ! -s "${RUN_DIR}/email-subject.txt" ]; then
        log "ERROR: email composition failed (exit ${compose_status}); no email-draft.html and email-subject.txt."
        return 1
    fi
    # Written but not sent: the session stopped first, or a Codex draft.
    set +e
    if [ "$EMAIL_MODE" = "session" ]; then
        log "The email session stopped without sending; sending its draft as that session."
        CLAUDE_CODE_SESSION_ID="$EMAIL_SESSION" "$SEND_EMAIL" "$RUN_DIR" 2>&1 | tee -a "$email_log"
    else
        "$SEND_EMAIL" "$RUN_DIR" --unrouted 2>&1 | tee -a "$email_log"
    fi
    send_status=${PIPESTATUS[0]}
    set -e
    if [ "$send_status" -eq 3 ]; then
        log "Note: the pre-send review held the email; the mailroom sends it unchanged after its fallback wait."
        return 0
    fi
    if [ "$send_status" -eq 2 ]; then
        log "ERROR: send-results-email.sh refused to send (exit 2): an input named above is missing or invalid; nothing was sent, and the draft stays in ${RUN_DIR}."
        return 1
    fi
    if [ "$send_status" -ne 0 ]; then
        log "ERROR: sending failed with exit ${send_status} (see above); nothing was sent, and the draft stays in ${RUN_DIR}."
        return 1
    fi
    log "Email sent to ${EMAIL_TO} from the agents' account: $(cut -f2 "${RUN_DIR}/.email-sent")"
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

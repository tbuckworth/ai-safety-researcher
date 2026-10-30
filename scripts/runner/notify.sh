# shellcheck shell=bash
# Reporting the outcome: the results email and the GitHub issue comment.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

outcome_is_success() {
    case "$FINAL_OUTCOME" in
        complete|complete-local) return 0 ;;
        *) return 1 ;;
    esac
}

send_email() {
    local email_log compose_status=127 send_status
    email_log="${LOG_DIR}/email-$(date +%Y%m%d-%H%M%S).log"
    cd "$REPO_DIR"
    rm -f "${RUN_DIR}/email-draft.html" "${RUN_DIR}/email-subject.txt" "${RUN_DIR}/email-images.txt" \
        "${RUN_DIR}/.email-sent"
    EMAIL_SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
    EMAIL_MODE=session
    set +e
    if command -v "$EMAIL_CLAUDE_BIN" >/dev/null 2>&1; then
        log "Writing and sending the results email with Claude ${EMAIL_CLAUDE_MODEL} (session ${EMAIL_SESSION})..."
        run_email_claude 2>&1 | tee "$email_log"
        compose_status=${PIPESTATUS[0]}
    fi
    if [ ! -s "${RUN_DIR}/email-draft.html" ] && [ "$BACKEND" = "codex" ]; then
        log "Note: no Claude session wrote the email (exit ${compose_status}); writing it with ${BACKEND}, to send unreviewed."
        run_email_provider 2>&1 | tee -a "$email_log"
        compose_status=${PIPESTATUS[0]}
        EMAIL_MODE=unrouted
    fi
    set -e

    if [ -s "${RUN_DIR}/.email-sent" ]; then
        log "Email sent to ${EMAIL_TO} from the agents' account: $(cut -f2 "${RUN_DIR}/.email-sent")"
        return 0
    fi
    if [ ! -s "${RUN_DIR}/email-draft.html" ] || [ ! -s "${RUN_DIR}/email-subject.txt" ]; then
        log "Note: email composition failed (exit ${compose_status}); no email-draft.html and email-subject.txt."
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
    if [ "$send_status" -ne 0 ]; then
        log "Note: sending failed with exit ${send_status}; draft retained."
        return 1
    fi
    log "Email sent to ${EMAIL_TO} from the agents' account: $(cut -f2 "${RUN_DIR}/.email-sent")"
}

post_issue_comment() {
    local number="$1" body_file="$2"
    gh issue comment "$number" --repo "$TASKS_REPO" --body-file "$body_file" >/dev/null \
        || log "WARN: could not comment on issue #${number}."
}

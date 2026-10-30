#!/usr/bin/env bash
# Send a run's results email to Titus from the agents' mail account (agent-mail),
# as the session that runs it, so his reply comes back to that session.
#
#   send-results-email.sh RUN_DIR [--unrouted]
#
# Reads, in RUN_DIR: email-subject.txt (one line), email-draft.html,
# run-outcome.json (a run whose `success` is false gets its outcome in front of
# the subject, e.g. "[UNPUBLISHED] ...") and the optional email-images.txt
# (NAME=relative/path.png per line, placed in the HTML as <img src="cid:NAME">).
#
# Mail to Titus is reviewed before it leaves (agent-mail's pre-send review).
# Exit 3 with "agent-mail: NOT SENT" and the fixes means nothing was sent:
# revise the draft and run this once more; that send goes out whatever the
# review says. A held draft nobody revises is sent unchanged by the mailroom
# after its fallback wait. Exit 0: sent, recorded in RUN_DIR/.email-sent. Exit 2:
# nothing was sent because an input is missing or invalid (no draft or subject,
# a run-outcome.json jq cannot read, a bad email-images.txt line); fix it and
# run this again.
#
# --unrouted: no session, so no review, and replies go to the orchestrator.
# Only the wrapper uses it, when the Claude CLI is not installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/researcher_lib.py"
RUN_DIR="${1:?usage: send-results-email.sh RUN_DIR [--unrouted]}"
UNROUTED="${2:-}"
TO="${RESEARCHER_EMAIL_TO:-titusbuckworth@gmail.com}"
AGENT_MAIL="${RESEARCHER_AGENT_MAIL:-$(command -v agent-mail || echo "${HOME}/.local/bin/agent-mail")}"

if [ -n "$UNROUTED" ] && [ "$UNROUTED" != "--unrouted" ]; then
    echo "error: unknown option ${UNROUTED}" >&2
    exit 2
fi
for f in email-draft.html email-subject.txt; do
    if [ ! -s "${RUN_DIR}/${f}" ]; then
        echo "error: ${RUN_DIR}/${f} is missing or empty; write it first" >&2
        exit 2
    fi
done
if [ ! -x "$AGENT_MAIL" ]; then
    echo "error: agent-mail not found (${AGENT_MAIL}); the email was not sent" >&2
    exit 2
fi

subject=$(head -1 "${RUN_DIR}/email-subject.txt" | tr -d '\r')
# The outcome of a run that did not succeed (run-outcome.json's `success`). An
# interactive run has no run-outcome.json; one that jq cannot read stops the send.
outcome=""
if [ -e "${RUN_DIR}/run-outcome.json" ] \
        && ! outcome=$(jq -r 'select(.success != true) | .outcome // empty' "${RUN_DIR}/run-outcome.json"); then
    echo "error: ${RUN_DIR}/run-outcome.json could not be read (jq's error is above); the email was not sent" >&2
    exit 2
fi
if [ -n "$outcome" ]; then
    # Deterministic, whatever the composer wrote: an unpublished or
    # result-less run is visible from the inbox.
    prefix="[$(printf '%s' "$outcome" | tr '[:lower:]' '[:upper:]')]"
    case "$subject" in "$prefix"*) ;; *) subject="${prefix} ${subject}" ;; esac
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/researcher-email.XXXXXX")
trap 'rm -rf "$work"' EXIT
python3 "$LIB" html-text "${RUN_DIR}/email-draft.html" > "${work}/body.txt"
if ! images=$(python3 "$LIB" email-images --run-dir "$RUN_DIR"); then
    echo "error: fix ${RUN_DIR}/email-images.txt (problems above) and run this again; the email was not sent" >&2
    exit 2
fi
image_args=()
while IFS= read -r image; do
    [ -n "$image" ] && image_args+=(--image "$image")
done <<< "$images"

send_args=(send --to "$TO" --subject "$subject" --body-file "${work}/body.txt" --html "${RUN_DIR}/email-draft.html")
[ -n "$UNROUTED" ] && send_args+=(--unrouted)
set +e
out=$("$AGENT_MAIL" "${send_args[@]}" ${image_args[@]+"${image_args[@]}"} 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
if [ "$rc" -eq 0 ]; then
    printf '%s\t%s\n' "$(date -Iseconds)" "$(printf '%s\n' "$out" | head -1)" > "${RUN_DIR}/.email-sent"
fi
exit "$rc"

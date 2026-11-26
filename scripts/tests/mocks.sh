# shellcheck shell=bash
# Mock executables shared by scripts/test-researcher-backends.sh and
# scripts/test-researcher-lifecycle.sh, which source this file. They stand in for
# boundaries a test must not cross: agent-mail sends real mail, and the model CLIs
# (claude, codex) call paid models.

# install_mock_agent_mail DIR: writes DIR/agent-mail. Each send is appended to
# $MOCK_EMAIL_LOG instead of mailed. With MOCK_REVIEW_PUSHBACK=true the first
# send from each session is held (exit 3, "agent-mail: NOT SENT") the way the
# pre-send review holds a draft; held sessions are listed in $MOCK_EMAIL_LOG.held.
install_mock_agent_mail() {
    cat > "$1/agent-mail" <<'MOCK_AGENT_MAIL'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
subject="" html="" unrouted=false images=""
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        --subject) subject="${args[$((i + 1))]}" ;;
        --html) html="${args[$((i + 1))]}" ;;
        --image) images="${images} ${args[$((i + 1))]##*/}" ;;
        --unrouted) unrouted=true ;;
    esac
done
[ "${1:-}" = "send" ] || { echo "mock agent-mail: only send" >&2; exit 2; }
[ -s "$html" ] || { echo "mock agent-mail: missing HTML" >&2; exit 2; }
who="${CLAUDE_CODE_SESSION_ID:-}"
[ "$unrouted" = true ] && who=unrouted
[ -n "$who" ] || { echo "agent-mail: not inside a Claude session and no --session given." >&2; exit 1; }
if [ "${MOCK_REVIEW_PUSHBACK:-false}" = "true" ] && [ "$who" != "unrouted" ] \
        && ! grep -qxF "$who" "${MOCK_EMAIL_LOG}.held" 2>/dev/null; then
    printf '%s\n' "$who" >> "${MOCK_EMAIL_LOG}.held"
    echo "agent-mail: NOT SENT: a reviewer with no context expects Titus to ask what this is."
    echo "Fix before sending:"
    echo "  1. Put the headline result in the first line."
    exit 3
fi
printf -- '--subject %s | from=%s | images=%s | %s\n' "$subject" "$who" "${images# }" "$*" >> "$MOCK_EMAIL_LOG"
echo "sent to self@example.test | subject '${subject}' | thread mock-thread | tag mocktag1 | from researcher (claude)"
MOCK_AGENT_MAIL
    chmod +x "$1/agent-mail"
}

# install_mock_email_composer DIR: writes DIR/mock-email-composer, the email half
# of a mock provider. A mock provider hands it the email prompt on stdin and its
# own arguments. It saves the prompt as <run>/.email-prompt.txt, writes the draft
# and subject, and, when the prompt says to send it, runs the helper the prompt
# names as the --session-id session, revising the draft once if the review holds
# it. MOCK_EMAIL_NO_SEND=true stops it before sending; MOCK_EMAIL_BAD_IMAGE=true
# also lists an image that does not exist in email-images.txt.
install_mock_email_composer() {
    cat > "$1/mock-email-composer" <<'MOCK_EMAIL_COMPOSER'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
run_dir=$(printf '%s\n' "$prompt" | sed -n 's/^The run directory is: \*\*\(.*\)\*\*$/\1/p' | head -1)
if [ -z "$run_dir" ]; then
    echo "mock email composer could not parse the run directory" >&2
    exit 64
fi
printf '%s\n' "$prompt" > "${run_dir}/.email-prompt.txt"
printf '%s\n' '<html><body>Mock research report</body></html>' > "${run_dir}/email-draft.html"
printf '%s\n' '[Auto-Research] Mock result — 1 pass, 0 fail' > "${run_dir}/email-subject.txt"
if [ "${MOCK_EMAIL_BAD_IMAGE:-false}" = "true" ]; then
    printf '%s\n' 'missing=figures/none.png' > "${run_dir}/email-images.txt"
fi
if [[ "$prompt" == *"Send it yourself"* ]] && [ "${MOCK_EMAIL_NO_SEND:-false}" != "true" ]; then
    sid=""
    prev=""
    for arg in "$@"; do
        [ "$prev" = "--session-id" ] && sid="$arg"
        prev="$arg"
    done
    helper=$(printf '%s\n' "$prompt" | sed -n 's/^ *\(\/.*send-results-email\.sh\) .*$/\1/p' | head -1)
    set +e
    CLAUDE_CODE_SESSION_ID="$sid" "$helper" "$run_dir"
    rc=$?
    if [ "$rc" -eq 3 ]; then
        printf '%s\n' '<p>Revised after the review.</p>' >> "${run_dir}/email-draft.html"
        CLAUDE_CODE_SESSION_ID="$sid" "$helper" "$run_dir"
        rc=$?
    fi
    set -e
    [ "$rc" -eq 0 ] || exit "$rc"
fi
echo "Mock email composition complete."
MOCK_EMAIL_COMPOSER
    chmod +x "$1/mock-email-composer"
}

# install_mock_next_steps_writer DIR: writes DIR/mock-next-steps-writer, the
# next-steps half of a mock provider. A mock provider hands it the prompt on
# stdin; it writes <run>/next-steps.md for the run directory the prompt names.
# MOCK_NEXT_STEPS_FAIL=true makes it fail after writing part of the file, as a
# session that drops mid-write does.
install_mock_next_steps_writer() {
    cat > "$1/mock-next-steps-writer" <<'MOCK_NEXT_STEPS_WRITER'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
run_dir=$(printf '%s\n' "$prompt" | sed -n 's/^The run directory is: \*\*\(.*\)\*\*$/\1/p' | head -1)
if [ -z "$run_dir" ]; then
    echo "mock next-steps writer could not parse the run directory" >&2
    exit 64
fi
printf '# Proposed Next Steps: mock\n\n**Run ID**: %s\n' "$(basename "$run_dir")" > "${run_dir}/next-steps.md"
if [ "${MOCK_NEXT_STEPS_FAIL:-false}" = "true" ]; then
    echo "stream disconnected while writing next-steps.md" >&2
    exit 1
fi
printf '%s\n' '**Outcome**: The run stopped before it could answer its question.' '' '## Reflection' '' \
    'An orchestration failure: a step failed; the science is untouched.' '' '## Ranked Next Steps' '' \
    '### 1. Resume the run after fixing the failed step' '- **Do**: resume' >> "${run_dir}/next-steps.md"
echo "Mock next-steps.md written."
MOCK_NEXT_STEPS_WRITER
    chmod +x "$1/mock-next-steps-writer"
}

# The real methods helper still hashes inputs, validates the structured response
# and persists receipts. Only the external model and the planning hub are mocked.
install_mock_reviews() {
    local bin="$1"
    cat > "${bin}/mock-review" <<'MOCK_REVIEW'
#!/usr/bin/env bash
set -euo pipefail
output=""
schema=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output-last-message ]; then output=$2; shift; fi
    if [ "$1" = --output-schema ]; then schema=$2; shift; fi
    shift
done
[ -n "$output" ] && [ -n "$schema" ] || exit 2
prompt=$(cat)
decision=approve
if [[ "$prompt" == *"Read the draft as a scientist"* ]]; then
    decision=${MOCK_READER_DECISION:-approve}
fi
# Re-check every open finding the schema names, resolving it, and give a revise
# decision the blocking finding a real reviewer needs to withhold a draft.
new='[]'
if [ "$decision" = revise ]; then
    new='[{"blocking":true,"title":"Mock objection","text":"The draft overstates the result.","reopens":""}]'
fi
jq -n --arg decision "$decision" --argjson new "$new" --slurpfile schema "$schema" \
    '{decision: $decision, summary: "Mock review completed.", new_findings: $new,
      rechecks: ($schema[0].properties.rechecks.required
                 | map({key: ., value: {status: "resolved", blocking: true, text: "Resolved."}}) | from_entries)}' \
    > "$output"
MOCK_REVIEW
    cat > "${bin}/mock-methods" <<'MOCK_METHODS'
#!/usr/bin/env bash
set -euo pipefail
step=$1
run=$2
case "$step" in
    6)
        mkdir -p "${run}/experiments/exp-001"
        echo 'Compare the two conditions.' > "${run}/method-spec.md"
        echo 'Measure the paired difference.' > "${run}/success-criteria.md"
        echo '["exp-001"]' > "${run}/methods-order.json"
        echo 'Paired comparison with a held-out test.' > "${run}/experiments/exp-001/plan.md"
        python3 "$MOCK_REVIEW_HELPER" plan "$run"
        ;;
    8)
        python3 "$MOCK_REVIEW_HELPER" approve-auto "$run"
        if [ "${MOCK_EDIT_AFTER_APPROVAL:-false}" = true ]; then
            echo 'Changed endpoint' >> "${run}/experiments/exp-001/plan.md"
        fi
        ;;
    9)
        touch "${run}/experiments/exp-001/started"
        ;;
    11)
        echo '{"figures":[],"reason":"Text-only mock report."}' > "${run}/review-figures.json"
        ;;
esac
MOCK_METHODS
    chmod +x "${bin}/mock-review" "${bin}/mock-methods"
}

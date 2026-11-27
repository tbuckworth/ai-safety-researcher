# shellcheck shell=bash
# Mock executables shared by scripts/test-researcher-backends.sh and
# scripts/test-researcher-lifecycle.sh, which source this file. They stand in for
# boundaries a test must not cross: agent-mail sends real mail, and the model CLIs
# (claude, codex) call paid models.

# install_mock_agent_mail DIR: writes DIR/agent-mail. Each send is appended to
# $MOCK_EMAIL_LOG instead of mailed, and its HTML part (if any) copied to
# $MOCK_EMAIL_LOG.last.html. With MOCK_REVIEW_PUSHBACK=true the first send from
# each session is held (exit 3, "agent-mail: NOT SENT") the way the pre-send
# review holds a draft; held sessions are listed in $MOCK_EMAIL_LOG.held. With
# MOCK_AGENT_MAIL_FAIL=true every send fails, as when the mailroom is down.
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
[ -z "$html" ] || [ -s "$html" ] || { echo "mock agent-mail: missing HTML file ${html}" >&2; exit 2; }
if [ "${MOCK_AGENT_MAIL_FAIL:-false}" = "true" ]; then
    echo "agent-mail: the mailroom is not answering (mock outage)" >&2
    exit 1
fi
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
[ -z "$html" ] || cp "$html" "${MOCK_EMAIL_LOG}.last.html"
echo "sent to self@example.test | subject '${subject}' | thread mock-thread | tag mocktag1 | from researcher (claude)"
MOCK_AGENT_MAIL
    chmod +x "$1/agent-mail"
}

# install_mock_email_composer DIR: writes DIR/mock-email-composer, the email half
# of a mock provider. A mock provider hands it the email prompt on stdin and its
# own arguments. It appends the login it runs on (codex, the basename of
# CLAUDE_CONFIG_DIR, else personal) to <run>/.email-writers, saves the prompt as
# <run>/.email-prompt.txt, writes the draft and subject, and, when the prompt
# says to send it, runs the helper the prompt names as the --session-id session,
# revising the draft once if the review holds it. A login named in
# MOCK_EMAIL_FAIL_LOGINS (space-separated) fails at once with a usage-limit
# notice; one in MOCK_EMAIL_HANG_LOGINS hangs; one in MOCK_EMAIL_DROP_LOGINS
# fails after writing the draft. MOCK_EMAIL_NO_SEND=true stops it before
# sending; MOCK_EMAIL_NO_REVISE=true makes it fail, unrevised, once the review
# holds its email; MOCK_EMAIL_BAD_IMAGE=true also lists an image that does not
# exist in email-images.txt.
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
# Which login runs it: Codex (its CLI's exec), a Claude login's config dir, or
# the default Claude login.
login=personal
if [[ " $* " == *" exec "* ]]; then
    login=codex
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    login=$(basename "$CLAUDE_CONFIG_DIR")
fi
printf '%s\n' "$login" >> "${run_dir}/.email-writers"
if [[ " ${MOCK_EMAIL_HANG_LOGINS:-} " == *" ${login} "* ]]; then
    exec sleep 600
fi
if [[ " ${MOCK_EMAIL_FAIL_LOGINS:-} " == *" ${login} "* ]]; then
    echo "You've hit your weekly limit · resets Nov 26, 5am (Europe/London) · out of usage credits"
    exit 1
fi
printf '%s\n' "$prompt" > "${run_dir}/.email-prompt.txt"
printf '%s\n' '<html><body>Mock research report</body></html>' > "${run_dir}/email-draft.html"
printf '%s\n' '[Auto-Research] Mock result — 1 pass, 0 fail' > "${run_dir}/email-subject.txt"
if [ "${MOCK_EMAIL_BAD_IMAGE:-false}" = "true" ]; then
    printf '%s\n' 'missing=figures/none.png' > "${run_dir}/email-images.txt"
fi
if [[ " ${MOCK_EMAIL_DROP_LOGINS:-} " == *" ${login} "* ]]; then
    echo "stream disconnected after writing the draft" >&2
    exit 1
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
    if [ "$rc" -eq 3 ] && [ "${MOCK_EMAIL_NO_REVISE:-false}" = "true" ]; then
        echo "You've hit your weekly limit (the session stops before revising the held email)"
        exit 1
    fi
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
# The final reader decides MOCK_READER_DECISION (default approve). The automatic
# approver decides the next word of MOCK_APPROVER_DECISIONS (space-separated, one
# per round, counted in the file MOCK_APPROVER_COUNTER; approve once they run out).
# Every other reviewer approves. A new finding's sources are every reviewed input.
# mock-methods is the planning hub of steps 6, 8, 9 and 11. At Step 8 it acts on
# the approver's exit as commands/researcher-auto-step.md says (or, with
# MOCK_OLD_RULE=true, as the former one-revision rule did); a step that sets a
# step or status of its own writes them to <run>/.mock-state ("STEP STATUS"),
# which the lifecycle test's provider applies. With MOCK_STEP11_HOLD=true Step 11
# writes a draft, has it read until the final reader's round cap, and holds it
# there with review_hold, as the former rule did.
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
elif [[ "$prompt" == *"Act as the independent methodology approver"* ]] && [ -n "${MOCK_APPROVER_COUNTER:-}" ]; then
    echo x >> "$MOCK_APPROVER_COUNTER"
    read -r -a decisions <<< "${MOCK_APPROVER_DECISIONS:-}"
    calls=$(wc -l < "$MOCK_APPROVER_COUNTER")
    decision=${decisions[$((calls - 1))]:-approve}
fi
# Re-check every open finding the schema names, resolving it, and give a revise
# decision the blocking finding a real reviewer needs to withhold a draft.
new='[]'
if [ "$decision" = revise ]; then
    new='[{"blocking":true,"title":"Mock objection","text":"The draft overstates the result.","reopens":""}]'
fi
jq -n --arg decision "$decision" --argjson new "$new" --slurpfile schema "$schema" \
    '{decision: $decision, summary: "Mock review completed.",
      new_findings: ($new | map(.sources = $schema[0].properties.new_findings.items.properties.sources.items.enum)),
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
        # A revision the approver asked for (Step 8 below) is kept.
        mkdir -p "${run}/experiments/exp-001"
        echo 'Compare the two conditions.' > "${run}/method-spec.md"
        echo 'Measure the paired difference.' > "${run}/success-criteria.md"
        echo '["exp-001"]' > "${run}/methods-order.json"
        [ -s "${run}/experiments/exp-001/plan.md" ] \
            || echo 'Paired comparison with a held-out test.' > "${run}/experiments/exp-001/plan.md"
        python3 "$MOCK_REVIEW_HELPER" plan "$run"
        ;;
    8)
        rc=0
        python3 "$MOCK_REVIEW_HELPER" approve-auto "$run" || rc=$?
        if [ "$rc" -eq 3 ] && [ "${MOCK_OLD_RULE:-false}" = true ] && [ -e "${run}/.mock-revisions" ]; then
            rc=4  # the former rule: a second request for revision ended the proposal
        fi
        case "$rc" in
            0|5) ;;  # approved, or the approval round cap: the experiments run on this revision
            3)
                # Answer the approver's open blocking findings and revise the plan in Step 6.
                for id in $(jq -r '.findings[] | select(.events[-1].by == "reviewer" and .events[-1].status == "open"
                                   and .events[-1].blocking) | .id' "${run}/reviews/approval/ledger.json"); do
                    python3 "$MOCK_REVIEW_HELPER" respond "$run" approval "$id" fixed "Answered in exp-001's plan"
                done
                echo "Revised to answer the approver ($(date +%s%N))." >> "${run}/experiments/exp-001/plan.md"
                echo x >> "${run}/.mock-revisions"
                echo "5 methods_revision_requested" > "${run}/.mock-state"
                ;;
            4)
                echo 'The approver ended this proposal.' > "${run}/methods-stop.md"
                echo "9 methods_declined" > "${run}/.mock-state"
                ;;
            *) exit "$rc" ;;
        esac
        if [ "${MOCK_EDIT_AFTER_APPROVAL:-false}" = true ]; then
            echo 'Changed endpoint' >> "${run}/experiments/exp-001/plan.md"
        fi
        ;;
    9)
        touch "${run}/experiments/exp-001/started"
        ;;
    11)
        echo '{"figures":[],"reason":"Text-only mock report."}' > "${run}/review-figures.json"
        if [ "${MOCK_STEP11_HOLD:-false}" = true ]; then
            printf '# Briefing\n\nA mock draft.\n' > "${run}/briefing.md"
            rc=3
            while [ "$rc" -eq 3 ]; do
                rc=0
                python3 "$MOCK_REVIEW_HELPER" presentation "$run" || rc=$?
                [ "$rc" -ne 3 ] || echo 'Revised after a reading.' >> "${run}/briefing.md"
            done
            [ "$rc" -eq 5 ] || exit "$rc"
            sed -i 's/^status:.*/&\nreview_hold: "The final reader reached its round cap with blocking findings open."/' \
                "${run}/state.md"
            echo "10 audit_complete" > "${run}/.mock-state"
        fi
        ;;
esac
MOCK_METHODS
    chmod +x "${bin}/mock-review" "${bin}/mock-methods"
}

# install_mock_mailroom DIR: the agent mailroom a test runs against. The real
# mailroom's code chooses the results email's writers (its login order), so the
# installed agent-usage's code (found on PATH before DIR is put first) is used,
# on a test configuration: Claude logins `personal` (the default) and `arrow` (a
# config dir under DIR/../logins with a login file), then Codex, and no API key;
# and `gemini`, a manual login with a settings file and a model of its own
# (MOCK_LOGIN_MODEL; its config dir and settings file are under DIR/../logins),
# which only a run that names it uses. RESEARCHER_AGENT_USAGE is a stand-in,
# DIR/../mailroom/bin/agent-usage, beside a link to the installed mailroom's
# package (results_report.py imports it from there): it answers `agent-usage
# login NAME --json` itself from the test configuration, in the form of the
# mailroom's own command (agent-mailroom branch gemini-login, ff1a0b6..125fcba,
# bin/agent-usage cmd_login), which the installed mailroom may not have yet,
# and hands anything else to the installed agent-usage; once the installed
# mailroom has the command, the stand-in can go. agent-status is a stand-in,
# DIR/agent-status, that appends each note to $MOCK_STATUS_LOG instead of the
# real status log. Exports what the runner reads (RESEARCHER_AGENT_USAGE,
# RESEARCHER_AGENT_STATUS, AGENT_MAIL_CONFIG_DIR, AGENT_MAIL_STATE_DIR) and
# MOCK_LOGIN_MODEL; exits 1 when the mailroom is not installed.
install_mock_mailroom() {
    local dir="$1" root usage
    root=$(dirname "$1")
    if ! usage=$(command -v agent-usage); then
        echo "FAIL: these tests need the agent mailroom installed (agent-usage on PATH): its code orders the results email's writers." >&2
        exit 1
    fi
    mkdir -p "${root}/logins/arrow" "${root}/logins/gemini" "${root}/mailroom-config" "${root}/mailroom-state" \
        "${root}/mailroom/bin"
    : > "${root}/logins/arrow/.credentials.json"
    export MOCK_LOGIN_MODEL="vendor/per-token-model"
    jq -n --arg model "$MOCK_LOGIN_MODEL" '{env: {ANTHROPIC_BASE_URL: "https://per-token.example.test",
        ANTHROPIC_MODEL: $model, CLAUDE_CODE_SUBAGENT_MODEL: $model}}' > "${root}/logins/gemini-settings.json"
    jq -n --arg arrow "${root}/logins/arrow" --arg gemini "${root}/logins/gemini" \
        --arg settings "${root}/logins/gemini-settings.json" --arg model "$MOCK_LOGIN_MODEL" '{
        usage: {claude_accounts: {personal: {config_dir: null, label: "test default login"},
                                  arrow: {config_dir: $arrow, label: "test second login"},
                                  gemini: {config_dir: $gemini, settings: $settings, model: $model, manual: true,
                                           label: "test per-token login"}},
                order: ["claude:personal", "claude:arrow", "codex"]},
        orchestrator_fallback_secret: ""}' > "${root}/mailroom-config/config.json"
    ln -s "$(dirname "$(dirname "$(readlink -f "$usage")")")/agentmail" "${root}/mailroom/agentmail"
    {
        printf '#!/usr/bin/env bash\nREAL_AGENT_USAGE=%q\n' "$usage"
        cat <<'MOCK_AGENT_USAGE'
set -euo pipefail
if [ "${1:-}" = login ]; then
    [ "$#" -eq 3 ] && [ "$3" = --json ] || { echo "mock agent-usage: only login NAME --json" >&2; exit 2; }
    config="${AGENT_MAIL_CONFIG_DIR}/config.json"
    if ! jq -e --arg name "$2" '.usage.claude_accounts | has($name)' "$config" > /dev/null; then
        echo "agent-usage: '$2' is not a Claude login" >&2
        exit 1
    fi
    exec jq --arg name "$2" '.usage.claude_accounts[$name] as $a
        | {name: $name, label: ($a.label // $name), config_dir: $a.config_dir, settings: ($a.settings // null),
           model: ($a.model // null), manual: ($a.manual // false),
           args: ((if $a.settings then ["--settings", $a.settings] else [] end)
                  + (if $a.model then ["--model", $a.model] else [] end))}' "$config"
fi
exec "$REAL_AGENT_USAGE" "$@"
MOCK_AGENT_USAGE
    } > "${root}/mailroom/bin/agent-usage"
    chmod +x "${root}/mailroom/bin/agent-usage"
    usage="${root}/mailroom/bin/agent-usage"
    cat > "${dir}/agent-status" <<'MOCK_AGENT_STATUS'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = note ] || { echo "mock agent-status: only note" >&2; exit 2; }
shift
printf '%s\n' "$*" >> "$MOCK_STATUS_LOG"
MOCK_AGENT_STATUS
    chmod +x "${dir}/agent-status"
    export RESEARCHER_AGENT_USAGE="$usage" RESEARCHER_AGENT_STATUS="${dir}/agent-status"
    export AGENT_MAIL_CONFIG_DIR="${root}/mailroom-config" AGENT_MAIL_STATE_DIR="${root}/mailroom-state"
    export MOCK_STATUS_LOG="${root}/status-notes.log"
}

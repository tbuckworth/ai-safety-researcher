#!/usr/bin/env bash
# Mock integration tests for the Claude/Codex autonomous runner.
# No model, GitHub, GPU, or email network calls are made.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/researcher-backends.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="${TEST_ROOT}/bin"
MOCK_CALL_LOG="${TEST_ROOT}/provider-calls.log"
MOCK_PROMPT_LOG="${TEST_ROOT}/provider-prompts.log"
MOCK_EMAIL_LOG="${TEST_ROOT}/email-calls.log"
mkdir -p "$MOCK_BIN"

# shellcheck source=tests/mocks.sh
source "${SCRIPT_DIR}/tests/mocks.sh"
install_mock_agent_mail "$MOCK_BIN"
install_mock_mailroom "$MOCK_BIN"
install_mock_email_composer "$MOCK_BIN"
install_mock_next_steps_writer "$MOCK_BIN"
install_mock_reviews "$MOCK_BIN"
export MOCK_REVIEW_HELPER="${REPO_DIR}/scripts/methods_review.py"

cat > "${MOCK_BIN}/mock-provider" <<'MOCK_PROVIDER'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" --output-last-message "* ]]; then
    exec "$(dirname "$0")/mock-review" "$@"
fi
prompt=$(cat)
printf '%s %s\n' "$(basename "$0")" "$*" >> "$MOCK_CALL_LOG"
{
    printf '\n===== %s %s =====\n' "$(basename "$0")" "$*"
    printf '%s\n' "$prompt"
} >> "$MOCK_PROMPT_LOG"

if [[ "$prompt" == *"# Autonomous Research Email Composer"* ]]; then
    exec "$(dirname "$0")/mock-email-composer" "$@" <<< "$prompt"
fi
if [[ "$prompt" == *"# Autonomous Next-Steps Writer"* ]]; then
    exec "$(dirname "$0")/mock-next-steps-writer" <<< "$prompt"
fi

argument=$(printf '%s\n' "$prompt" |
    sed -n 's/^The argument is: \*\*\([0-9][0-9]*\) \(.*\)\*\*$/\1|\2/p' |
    head -1)
if [ -z "$argument" ]; then
    echo "mock provider could not parse step arguments" >&2
    exit 64
fi

step=${argument%%|*}
run_dir=${argument#*|}
state_file="${run_dir}/state.md"

if [ "${MOCK_FAIL_FIRST_STEP:-false}" = "true" ] \
    && [ "$step" = "1" ] \
    && [ ! -e "$MOCK_FAIL_MARKER" ]; then
    : > "$MOCK_FAIL_MARKER"
    echo "Mock transient provider failure." >&2
    exit 42
fi

"$(dirname "$0")/mock-methods" "$step" "$run_dir"
if [ "$step" = "11" ]; then
    new_status="complete"
else
    new_status="mock_step_complete"
fi

# A run only counts as complete if it has a result (the wrapper's final
# outcome checks), so Step 9 writes one, with its pre-flight record.
if [ "$step" = "9" ]; then
    mkdir -p "${run_dir}/experiments/exp-001"
    printf '## Component Tested\nMock component\n\n## Verdict: PASS\n' \
        > "${run_dir}/experiments/exp-001/results.md"
    printf '| Check | Status | Evidence |\n|---|---|---|\n| method-fidelity | PASS | mock |\n' \
        > "${run_dir}/experiments/exp-001/preflight.md"
fi

# Simulate a model rewriting Step 1 state from an incomplete schema. The
# wrapper must restore runtime-owned fields before the next step or resume.
if [ "$step" = "1" ]; then
    sed \
        -e '/^agent_backend:/d' \
        -e '/^agent_model:/d' \
        -e '/^compute_profile:/d' \
        -e '/^knowledge_base:/d' \
        "$state_file" > "${state_file}.stripped"
    mv "${state_file}.stripped" "$state_file"
fi

sed \
    -e "s/^current_step:.*/current_step: ${step}/" \
    -e "s/^status:.*/status: ${new_status}/" \
    "$state_file" > "${state_file}.tmp"
mv "${state_file}.tmp" "$state_file"
echo "Mock step ${step} complete."
MOCK_PROVIDER
chmod +x "${MOCK_BIN}/mock-provider"
ln -s mock-provider "${MOCK_BIN}/claude"
ln -s mock-provider "${MOCK_BIN}/codex"

export MOCK_CALL_LOG MOCK_PROMPT_LOG MOCK_EMAIL_LOG

run_case() {
    local backend="$1"
    local profile="${2:-}"
    # Always explicit, never the developer's real wiki: a test must not write
    # pages into ~/pyg/research-wiki.
    local kb_dir="${3:-none}"
    local label="${backend}${profile:+-${profile}}${4:+-$4}"
    local output_dir="${TEST_ROOT}/output-${label}"
    local stdout_log="${TEST_ROOT}/${label}.stdout"
    local fail_first=false

    if [ "$backend" = "codex" ]; then
        fail_first=true
    fi

    RESEARCHER_BACKEND="$backend" \
    RESEARCHER_CLAUDE_BIN="${CASE_CLAUDE_BIN:-${MOCK_BIN}/claude}" \
    RESEARCHER_CODEX_BIN="${MOCK_BIN}/codex" \
    RESEARCHER_CLAUDE_MODEL="mock-claude" \
    RESEARCHER_CODEX_MODEL="mock-codex" \
    RESEARCHER_CODEX_FAST_MODEL="mock-codex-fast" \
    RESEARCHER_CODEX_REASONING="high" \
    RESEARCHER_CODEX_SANDBOX="workspace-write" \
    RESEARCHER_CODEX_APPROVAL_POLICY="never" \
    RESEARCHER_OUTPUT_DIR="$output_dir" \
    RESEARCHER_LOCKFILE="${TEST_ROOT}/${label}.lock" \
    RESEARCHER_COMPUTE_PROFILE="$profile" \
    RESEARCHER_LINK_OUTPUT="false" \
    RESEARCHER_SKIP_PUBLISH="true" \
    RESEARCHER_SKIP_GPU_CHECK="true" \
    RESEARCHER_STEP_ATTEMPTS="2" \
    RESEARCHER_RETRY_DELAY_SECONDS="0" \
    PATH="${MOCK_BIN}:${PATH}" \
    RESEARCHER_AGENT_MAIL="${MOCK_BIN}/agent-mail" \
    RESEARCHER_EMAIL_TO="self@example.test" \
    RESEARCHER_HOST_ALIAS="mock-host" \
    RESEARCHER_KB_DIR="$kb_dir" \
    MOCK_FAIL_FIRST_STEP="$fail_first" \
    MOCK_FAIL_MARKER="${TEST_ROOT}/${label}.failed-once" \
    "$REPO_DIR/scripts/researcher-cron.sh" "Mock research topic ${label}" \
        > "$stdout_log" 2>&1

    local state_file
    state_file=$(find "$output_dir" -mindepth 2 -maxdepth 2 -name state.md -type f | head -1)
    test -n "$state_file"
    grep -q '^status: complete$' "$state_file"
    # Publishing is skipped in these cases, so the honest outcome is complete-local.
    grep -q '^final_outcome: complete-local$' "$state_file"
    grep -q "^agent_backend: ${backend}$" "$state_file"
    grep -q '^agent_model: "mock-' "$state_file"
    grep -q '^compute_profile: "' "$state_file"
    case "$profile" in
        mats)
            # Preset expands to the full Slurm description, not the literal token.
            grep -q '^compute_profile: "MATS Slurm cluster' "$state_file"
            grep -q 'sbatch' "$state_file"
            grep -q 'elastic-\* partitions (A100/H100) are NOT authorized' "$state_file"
            ;;
        "")
            grep -q '^compute_profile: "Local NVIDIA RTX 3090' "$state_file"
            ;;
    esac
    test -s "$(dirname "$state_file")/email-draft.html"
    test -s "$(dirname "$state_file")/email-subject.txt"
    # The mock Step 11 writes no next-steps.md, so a session of the run's own
    # backend writes it.
    grep -q "No next-steps.md after the workflow (status complete); writing it with ${backend} mock-${backend}" "$stdout_log"
    test -s "$(dirname "$state_file")/next-steps.md"

    # The knowledge base is wrapper-owned state, restored after every step just
    # like the compute profile.
    grep -q "^knowledge_base: \"${kb_dir}\"$" "$state_file"
    # The startup line names what this run uses.
    grep -q "Agent backend: ${backend}; model: mock-${backend}; compute profile: ${profile:-local}; knowledge base: ${kb_dir}; owner: none; pinned run: none" \
        "$stdout_log"

    if [ "$backend" = "codex" ]; then
        grep -q 'Mock transient provider failure' "$stdout_log"
        grep -q 'exit 42' "$stdout_log"
    fi
}

run_case claude
run_case codex
run_case claude mats

# A bootstrapped knowledge base reaches state.md and the runtime header; a path
# with no KB-SCHEMA.md stops the run (exit 2) rather than being handed to agents
# as somewhere to write pages, or silently dropped.
KB_FIXTURE="${TEST_ROOT}/wiki"
bash "$REPO_DIR/scripts/kb-init.sh" "$KB_FIXTURE" > "${TEST_ROOT}/kb-init.stdout"
for kb_file in KB-SCHEMA.md index.md log.md AGENTS.md CLAUDE.md \
               lessons/common-failures.md lessons/experiment-design.md \
               lessons/compute.md lessons/tooling.md; do
    test -s "${KB_FIXTURE}/${kb_file}" \
        || { echo "FAIL: kb-init did not write ${kb_file}" >&2; exit 1; }
done
# index.md lists exactly the lessons pages kb-init seeded.
diff <(cd "${KB_FIXTURE}/lessons" && printf '%s\n' ./*.md | sed -e 's,^\./,,' -e 's/\.md$//') \
     <(sed -n 's/^- \[\[\([^]]*\)\]\] — .*/\1/p' "${KB_FIXTURE}/index.md" | sort) \
    || { echo "FAIL: index.md does not list the lessons pages kb-init seeded" >&2; exit 1; }
test -d "${KB_FIXTURE}/.git"
bash "$REPO_DIR/scripts/kb-init.sh" "$KB_FIXTURE" > /dev/null   # idempotent
# A bootstrap commit that is refused (here by a pre-commit hook) fails kb-init.
mkdir -p "${TEST_ROOT}/refusing-hooks"
printf '#!/usr/bin/env bash\necho "mock hook refuses the commit" >&2\nexit 1\n' > "${TEST_ROOT}/refusing-hooks/pre-commit"
chmod +x "${TEST_ROOT}/refusing-hooks/pre-commit"
if GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="${TEST_ROOT}/refusing-hooks" \
        bash "$REPO_DIR/scripts/kb-init.sh" "${TEST_ROOT}/wiki-refused" > "${TEST_ROOT}/kb-refused.out" 2>&1; then
    echo "FAIL: kb-init succeeded although its bootstrap commit was refused" >&2
    exit 1
fi
grep -q "mock hook refuses the commit" "${TEST_ROOT}/kb-refused.out"
# ...and a re-run, once the commit is allowed, makes it (the repository exists
# by then, but has no commit).
bash "$REPO_DIR/scripts/kb-init.sh" "${TEST_ROOT}/wiki-refused" > "${TEST_ROOT}/kb-retry.out" 2>&1
git -C "${TEST_ROOT}/wiki-refused" rev-parse -q --verify HEAD > /dev/null \
    || { echo "FAIL: a re-run of kb-init did not make the bootstrap commit" >&2; exit 1; }

run_case claude "" "$KB_FIXTURE" kb
grep -qF -- "- Global knowledge base: ${KB_FIXTURE}" "$MOCK_PROMPT_LOG"

UNSTRUCTURED="${TEST_ROOT}/not-a-wiki"
mkdir -p "$UNSTRUCTURED"
set +e
RESEARCHER_KB_DIR="$UNSTRUCTURED" \
RESEARCHER_OUTPUT_DIR="${TEST_ROOT}/nokb-output" \
RESEARCHER_LOCKFILE="${TEST_ROOT}/nokb.lock" \
RESEARCHER_HOST_ALIAS="mock-host" \
"$REPO_DIR/scripts/researcher-cron.sh" "No knowledge base" > "${TEST_ROOT}/nokb.stdout" 2>&1
nokb_status=$?
set -e
test "$nokb_status" = "2"
grep -q "RESEARCHER_KB_DIR=${UNSTRUCTURED} has no KB-SCHEMA.md" "${TEST_ROOT}/nokb.stdout"

grep -q '^claude --print .*--model mock-claude' "$MOCK_CALL_LOG"
grep -q '^codex --search --ask-for-approval never exec .*--model mock-codex' "$MOCK_CALL_LOG"
grep -q -- '--sandbox workspace-write' "$MOCK_CALL_LOG"
grep -q -- '--ask-for-approval never' "$MOCK_CALL_LOG"
grep -q -- '--ignore-user-config' "$MOCK_CALL_LOG"
grep -q '# Codex Runtime Adapter' "$MOCK_PROMPT_LOG"
# The adapter is templates/codex-adapter.md, followed by this run's worker models.
grep -qF "$(head -3 "${REPO_DIR}/templates/codex-adapter.md" | tail -1)" "$MOCK_PROMPT_LOG"
# shellcheck disable=SC2016 # Match the literal Markdown code spans.
grep -q '^Worker models for this run: fast `mock-codex-fast` with `medium` reasoning; deep `mock-codex` with `high` reasoning\.$' \
    "$MOCK_PROMPT_LOG"

# The runtime header gives every step the configured limits and the local code
# it may search.
read -r max_experiments experiment_minutes max_file_mb max_audit_rounds code_dir < <(
    "${REPO_DIR}/scripts/config.sh" RESEARCHER_MAX_EXPERIMENTS RESEARCHER_EXPERIMENT_MINUTES \
        RESEARCHER_MAX_FILE_MB RESEARCHER_MAX_AUDIT_ROUNDS RESEARCHER_CODE_SEARCH_DIR | paste -sd' ')
grep -qF -- "- Experiment limits: at most ${max_experiments} experiments in the run, each targeting under ${experiment_minutes} minutes of compute, and every file under ${max_file_mb} MB" \
    "$MOCK_PROMPT_LOG"
grep -qxF -- "- Audit rounds (R_MAX): at most ${max_audit_rounds}" "$MOCK_PROMPT_LOG"
grep -qxF -- "- Local code to search (read-only): ${code_dir}" "$MOCK_PROMPT_LOG"
# A run without an issue tells the email composer so.
grep -qx -- '- Original issue: none' "$MOCK_PROMPT_LOG"
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "4"
grep -q -- '--to self@example.test' "$MOCK_EMAIL_LOG"
# Every results email is written and sent by a Claude session (its own id, so
# the reply comes back to it), Codex runs included; none goes unrouted.
test "$(grep -c '^claude --print .*--session-id [0-9a-f-]\{36\} ' "$MOCK_CALL_LOG")" = "4"
grep -q '^claude --print .*--model sonnet .*--session-id ' "$MOCK_CALL_LOG"
if grep -q -- 'unrouted' "$MOCK_EMAIL_LOG"; then echo "FAIL: an email went unrouted" >&2; exit 1; fi

# The email composer is handed the real machine facts for the "How to Continue"
# steps, per backend. A placeholder here means an email telling the reader to cd
# into a path that does not exist.
grep -q '^- Run host SSH alias: mock-host$' "$MOCK_PROMPT_LOG"
grep -q "^- Plugin directory on the run host: ${REPO_DIR}$" "$MOCK_PROMPT_LOG"
grep -qE '^- Run directory on the run host: /.*/output-claude/' "$MOCK_PROMPT_LOG"
grep -qE '^- Continue command: /researcher-continue /' "$MOCK_PROMPT_LOG"
# shellcheck disable=SC2016 # The Codex command begins with a literal dollar.
grep -qF -- '- Continue command: $researcher:researcher-continue /' "$MOCK_PROMPT_LOG"

# Every email carries proposed next steps and a continuation path.
grep -q 'Proposed Next Steps' "$MOCK_PROMPT_LOG"
grep -q 'How to Continue This Research' "$MOCK_PROMPT_LOG"
# The next-steps session gets its command and the last step's provider output.
grep -qx '# Autonomous Next-Steps Writer' "$MOCK_PROMPT_LOG"
grep -qE -- "^- Last step's provider output: /.*/logs/step-11-attempt-1-[0-9-]+\.log$" "$MOCK_PROMPT_LOG"

# Step 11 writes the canonical next-round plan the email and /researcher-continue read.
# shellcheck disable=SC2016 # Match the literal Markdown code span.
grep -q 'Write `next-steps.md`' "$MOCK_PROMPT_LOG"

# The step prompt carries the WHOLE workflow document, not alternating chunks of
# it. A `sed '/^---$/,/^---$/d'` frontmatter strip pairs up every markdown section
# separator and deletes half the file; that shipped for a long time, silently
# dropping whole steps from every prompt. Assert every `## ` heading survives.
mapfile -t step_headings < <(grep '^## ' "${REPO_DIR}/commands/researcher-auto-step.md")
step_count=$(printf '%s\n' "${step_headings[@]}" | grep -c '^## Step ')
[ "$step_count" -ge 11 ] \
    || { echo "FAIL: commands/researcher-auto-step.md has ${step_count} '## Step' headings, expected at least 11" >&2; exit 1; }
for step_heading in "${step_headings[@]}"; do
    grep -qxF "$step_heading" "$MOCK_PROMPT_LOG" \
        || { echo "FAIL: step prompt is missing '${step_heading}'" >&2; exit 1; }
done

# ...and that the frontmatter itself is still stripped (no stray `model:` line
# leaking into the prompt as if it were an instruction).
grep -q '^# Autonomous Research Step Executor' "$MOCK_PROMPT_LOG"
if grep -qE '^allowed-tools: \[' "$MOCK_PROMPT_LOG"; then
    echo "FAIL: command frontmatter leaked into the prompt" >&2
    exit 1
fi

# Invalid providers and accidental cross-provider resumes fail closed.
set +e
RESEARCHER_BACKEND="invalid" \
RESEARCHER_OUTPUT_DIR="${TEST_ROOT}/invalid-output" \
"$REPO_DIR/scripts/researcher-cron.sh" "Invalid backend" \
    > "${TEST_ROOT}/invalid.stdout" 2>&1
invalid_status=$?
set -e
test "$invalid_status" = "2"
grep -q "must be one of: $(python3 "${REPO_DIR}/scripts/researcher_lib.py" backends); got 'invalid'" \
    "${TEST_ROOT}/invalid.stdout"

mismatch_output="${TEST_ROOT}/mismatch-output"
mkdir -p "${mismatch_output}/existing-run"
cat > "${mismatch_output}/existing-run/state.md" <<'MISMATCH_STATE'
---
run_id: existing-run
topic: "Existing run"
current_step: 4
status: criteria_complete
mode: autonomous
agent_backend: claude
agent_model: "mock-claude"
issue_number: none
---
MISMATCH_STATE

set +e
RESEARCHER_BACKEND="codex" \
RESEARCHER_CODEX_BIN="${MOCK_BIN}/codex" \
RESEARCHER_OUTPUT_DIR="$mismatch_output" \
RESEARCHER_LOCKFILE="${TEST_ROOT}/mismatch.lock" \
RESEARCHER_LINK_OUTPUT="false" \
RESEARCHER_SKIP_PUBLISH="true" \
RESEARCHER_SKIP_EMAIL="true" \
RESEARCHER_SKIP_GPU_CHECK="true" \
RESEARCHER_HOST_ALIAS="mock-host" \
"$REPO_DIR/scripts/researcher-cron.sh" "Resume mismatch" \
    > "${TEST_ROOT}/mismatch.stdout" 2>&1
mismatch_status=$?
set -e
test "$mismatch_status" = "2"
# A run that predates run-config.json has its backend saved in state.md.
grep -q "ERROR: the run's saved RESEARCHER_BACKEND is 'claude', but this launch sets 'codex'" "${TEST_ROOT}/mismatch.stdout"

# Follow-up issues carry the source label of the backend that files them.
cat > "${MOCK_BIN}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_GH_LOG"
case "${1:-} ${2:-}" in
    "issue create") printf '%s\n' "https://github.com/tbuckworth/tasks/issues/123" ;;
    "issue view") printf '%s\n' "123" ;;
esac
MOCK_GH
chmod +x "${MOCK_BIN}/gh"
printf '%s\n' "Re-run with a stricter held-out split." > "${TEST_ROOT}/feedback.txt"
export MOCK_GH_LOG="${TEST_ROOT}/gh-calls.log"
PATH="${MOCK_BIN}:${PATH}" \
"$REPO_DIR/scripts/create-followup-issue.sh" \
    --parent 42 \
    --repo-url https://github.com/tbuckworth/research-example \
    --run-id prior-run \
    --source codex \
    --feedback-file "${TEST_ROOT}/feedback.txt" \
    > "${TEST_ROOT}/followup.stdout" 2> "${TEST_ROOT}/followup.stderr"
grep -q -- '--label source:codex' "$MOCK_GH_LOG"
followup_label=$(cd "${REPO_DIR}/scripts" && python3 -c 'import researcher_lib; print(researcher_lib.FOLLOWUP_LABEL)')
grep -q -- "^issue create .*--label ${followup_label} " "$MOCK_GH_LOG"
# The mock parent has no importance label, so the follow-up gets medium.
grep -q -- '--label importance:medium' "$MOCK_GH_LOG"
grep -q 'WARN: parent issue #42 has no importance label' "${TEST_ROOT}/followup.stderr"
grep -q 'Created follow-up issue: https://github.com/tbuckworth/tasks/issues/123' \
    "${TEST_ROOT}/followup.stdout"

# --- The results email's writers ---------------------------------------------
# The email is written by each writer of the mailroom's login order in turn (here
# the Claude logins personal and arrow, then Codex; install_mock_mailroom) until
# one succeeds; with none left, it is assembled with no model.

# email_case LABEL [VAR=value ...]: a Codex run of its own (publishing skipped),
# with the given variables; sets CASE_RUN (its run directory) and CASE_RC (its
# exit code), and empties the email and status logs first.
email_case() {
    local label="$1"
    shift
    : > "$MOCK_EMAIL_LOG"
    : > "$MOCK_STATUS_LOG"
    set +e
    env RESEARCHER_BACKEND=codex \
        RESEARCHER_CLAUDE_BIN="${MOCK_BIN}/claude" \
        RESEARCHER_CODEX_BIN="${MOCK_BIN}/codex" \
        RESEARCHER_CODEX_FAST_MODEL="mock-codex-fast" \
        RESEARCHER_OUTPUT_DIR="${TEST_ROOT}/${label}-output" \
        RESEARCHER_LOCKFILE="${TEST_ROOT}/${label}.lock" \
        RESEARCHER_LINK_OUTPUT=false \
        RESEARCHER_SKIP_PUBLISH=true \
        RESEARCHER_SKIP_GPU_CHECK=true \
        RESEARCHER_RETRY_DELAY_SECONDS=0 \
        PATH="${MOCK_BIN}:${PATH}" \
        RESEARCHER_AGENT_MAIL="${MOCK_BIN}/agent-mail" \
        RESEARCHER_EMAIL_TO="self@example.test" \
        RESEARCHER_HOST_ALIAS="mock-host" \
        RESEARCHER_KB_DIR=none \
        "$@" \
        "$REPO_DIR/scripts/researcher-cron.sh" "Email case ${label}" > "${TEST_ROOT}/${label}.stdout" 2>&1
    CASE_RC=$?
    set -e
    CASE_RUN=$(find "${TEST_ROOT}/${label}-output" -mindepth 2 -maxdepth 2 -name state.md -printf '%h\n' | head -1)
    test -n "$CASE_RUN"
}

# With no Claude CLI installed, both Claude logins fail, Codex writes the email
# and it goes unrouted (unreviewed; replies to the orchestrator).
: > "$MOCK_EMAIL_LOG"
CASE_CLAUDE_BIN="${TEST_ROOT}/no-claude-here" run_case codex "" none noclaude
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "1"
grep -q 'from=unrouted .*--unrouted' "$MOCK_EMAIL_LOG"
grep -q 'WARN: the results email was not delivered by personal: the writer failed (exit 127' "${TEST_ROOT}/codex-noclaude.stdout"
grep -q 'WARN: the results email was not delivered by arrow: the writer failed (exit 127' "${TEST_ROOT}/codex-noclaude.stdout"
grep -q 'Writing the results email with Codex mock-codex-fast, to send unrouted' "${TEST_ROOT}/codex-noclaude.stdout"
grep -q 'sent (outcome complete-local), written on the codex login; before it: personal: ' "$MOCK_STATUS_LOG"

# A Claude login at its usage limit passes the email to the next login, whose
# session writes it and sends it itself (routed and reviewed, not unrouted).
email_case limit MOCK_EMAIL_FAIL_LOGINS=personal
test "$CASE_RC" = "0"
test "$(paste -sd' ' "${CASE_RUN}/.email-writers")" = "personal arrow"
grep -q "WARN: the results email was not delivered by personal: the writer failed (exit 1: You've hit your weekly limit" \
    "${TEST_ROOT}/limit.stdout"
arrow_session=$(sed -n 's/.*on the arrow login (session \([0-9a-f-]\{36\}\)).*/\1/p' "${TEST_ROOT}/limit.stdout")
test -n "$arrow_session"
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "1"
grep -q "from=${arrow_session} " "$MOCK_EMAIL_LOG"
if grep -q -- 'unrouted' "$MOCK_EMAIL_LOG"; then echo "FAIL: the arrow login's email went unrouted" >&2; exit 1; fi
grep -q '^undelivered: none$' "${CASE_RUN}/state.md"

# A writer that hangs is stopped at RESEARCHER_EMAIL_TIMEOUT_SECONDS and the next writes it.
email_case hang MOCK_EMAIL_HANG_LOGINS=personal RESEARCHER_EMAIL_TIMEOUT_SECONDS=2
test "$CASE_RC" = "0"
grep -q 'WARN: the results email was not delivered by personal: the writer failed (exit 124' "${TEST_ROOT}/hang.stdout"
test "$(paste -sd' ' "${CASE_RUN}/.email-writers")" = "personal arrow"

# With every login failing, the report is assembled from the run's saved files
# with no model and sent unrouted; it says why no model wrote it.
email_case nomodel "MOCK_EMAIL_FAIL_LOGINS=personal arrow codex"
test "$CASE_RC" = "0"
test "$(paste -sd' ' "${CASE_RUN}/.email-writers")" = "personal arrow codex"
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "1"
grep -q '^--subject \[Auto-Research\] .* — complete (not published by request) — 1 pass | from=unrouted ' "$MOCK_EMAIL_LOG"
grep -q 'Written without a model' "${MOCK_EMAIL_LOG}.last.html"
grep -q "codex: the writer failed (exit 1: You&#x27;ve hit your weekly limit" "${MOCK_EMAIL_LOG}.last.html"
grep -q 'How to Continue This Research' "${MOCK_EMAIL_LOG}.last.html"
grep -qF "\$researcher:researcher-continue ${CASE_RUN}" "${MOCK_EMAIL_LOG}.last.html"
grep -q 'sent (outcome complete-local), assembled without a model; before it: personal: ' "$MOCK_STATUS_LOG"

# A Codex writer that fails after writing its draft does not have that draft sent:
# the report with no model goes instead.
email_case codexdrop "MOCK_EMAIL_FAIL_LOGINS=personal arrow" MOCK_EMAIL_DROP_LOGINS=codex
test "$CASE_RC" = "0"
grep -q 'Written without a model' "${MOCK_EMAIL_LOG}.last.html"
if grep -q 'Mock research report' "${MOCK_EMAIL_LOG}.last.html"; then echo "FAIL: the failed writer's draft was sent" >&2; exit 1; fi

# Without the mailroom's login order, no model is tried and the report with no
# model goes, saying why.
email_case noorder RESEARCHER_AGENT_USAGE="${TEST_ROOT}/no-agent-usage"
test "$CASE_RC" = "0"
test ! -e "${CASE_RUN}/.email-writers"
grep -q "login order: agent-usage (the mailroom&#x27;s ${TEST_ROOT}/no-agent-usage) is not installed" "${MOCK_EMAIL_LOG}.last.html"

# With the mailroom down nothing can be sent: the run exits 5, state.md names the
# email as undelivered, and the status note says how to send it later.
email_case maildown MOCK_AGENT_MAIL_FAIL=true
test "$CASE_RC" = "5"
test ! -s "$MOCK_EMAIL_LOG"
grep -q '^undelivered: email$' "${CASE_RUN}/state.md"
grep -q 'ERROR: nothing was sent to self@example.test about this run' "${TEST_ROOT}/maildown.stdout"
grep -q "NOT SENT; before it: personal: .*re-send with ${REPO_DIR}/scripts/send-run-report.sh ${CASE_RUN}" "$MOCK_STATUS_LOG"

# send-run-report.sh sends that run's report later, through the same writers,
# with the settings the run saved; a second call is refused.
send_run_report() {
    : > "$MOCK_EMAIL_LOG"
    : > "$MOCK_PROMPT_LOG"
    : > "$MOCK_CALL_LOG"
    set +e
    env PATH="${MOCK_BIN}:${PATH}" \
        RESEARCHER_CLAUDE_BIN="${MOCK_BIN}/claude" \
        RESEARCHER_CODEX_BIN="${MOCK_BIN}/codex" \
        RESEARCHER_AGENT_MAIL="${MOCK_BIN}/agent-mail" \
        RESEARCHER_EMAIL_TO="self@example.test" \
        RESEARCHER_HOST_ALIAS="mock-host" \
        RESEARCHER_RUNNER_DIR="${TEST_ROOT}/runner-checkout" \
        "$@" "$REPO_DIR/scripts/send-run-report.sh" "$CASE_RUN" > "${TEST_ROOT}/resend.stdout" 2>&1
    CASE_RC=$?
    set -e
}
mkdir -p "${TEST_ROOT}/runner-checkout"
send_run_report
test "$CASE_RC" = "0"
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "1"
# The continuation names the runner checkout, where a reply resumes the session.
grep -qx -- "- Plugin directory on the run host: ${TEST_ROOT}/runner-checkout" "$MOCK_PROMPT_LOG"
grep -q '^claude --print .*--model sonnet .*--session-id ' "$MOCK_CALL_LOG"
grep -qx -- '- Final outcome: complete-local' "$MOCK_PROMPT_LOG"
grep -qx -- '- Agent to start in the plugin directory: '"${MOCK_BIN}/codex" "$MOCK_PROMPT_LOG"
grep -qF -- "- Continue command: \$researcher:researcher-continue ${CASE_RUN}" "$MOCK_PROMPT_LOG"
send_run_report
test "$CASE_RC" = "1"
grep -q 'already went or is held (.email-sent' "${TEST_ROOT}/resend.stdout"
test ! -s "$MOCK_EMAIL_LOG"

# A run record the report with no model cannot read leaves a plain-text notice.
rm "${CASE_RUN}/.email-sent"
jq '.experiments = 5' "${CASE_RUN}/run-outcome.json" > "${CASE_RUN}/run-outcome.json.tmp"
mv "${CASE_RUN}/run-outcome.json.tmp" "${CASE_RUN}/run-outcome.json"
send_run_report "MOCK_EMAIL_FAIL_LOGINS=personal arrow codex"
# Only the notice went, not the report: the script says so and exits 1.
test "$CASE_RC" = "1"
grep -q 'template: the report could not be assembled' "${TEST_ROOT}/resend.stdout"
grep -q 'ERROR: the report itself did not go, only the plain-text notice' "${TEST_ROOT}/resend.stdout"
grep -q '^--subject \[Auto-Research\] Results report not written: run .*(complete-local) | from=unrouted ' "$MOCK_EMAIL_LOG"
grep -q -- '--body-file' "$MOCK_EMAIL_LOG"
if grep -q -- '--html' "$MOCK_EMAIL_LOG"; then echo "FAIL: the notice has an HTML part" >&2; exit 1; fi

# An email the pre-send review holds goes after the mailroom's fallback wait: a
# writer that stops before revising it has delivered it, so no other writer
# sends a second one, and send-run-report.sh refuses that run.
: > "${MOCK_EMAIL_LOG}.held"
email_case held MOCK_REVIEW_PUSHBACK=true MOCK_EMAIL_NO_REVISE=true
test "$CASE_RC" = "0"
test "$(paste -sd' ' "${CASE_RUN}/.email-writers")" = "personal"
test -s "${CASE_RUN}/.email-held"
test ! -e "${CASE_RUN}/.email-sent"
test ! -s "$MOCK_EMAIL_LOG"
test "$(wc -l < "${MOCK_EMAIL_LOG}.held" | tr -d ' ')" = "1"
grep -q 'the pre-send review held the email; the mailroom sends it unchanged after its fallback wait' "${TEST_ROOT}/held.stdout"
grep -q '^undelivered: none$' "${CASE_RUN}/state.md"
send_run_report
test "$CASE_RC" = "1"
grep -q 'already went or is held (.email-held' "${TEST_ROOT}/resend.stdout"
test ! -s "$MOCK_EMAIL_LOG"

# build_email_prompt takes exactly send or compose.
if bash -c 'source "$1/runner/common.sh"; source "$1/runner/provider.sh"; build_email_prompt sned' _ "$SCRIPT_DIR" \
        > "${TEST_ROOT}/prompt-mode.out" 2>&1; then
    echo "FAIL: build_email_prompt accepted 'sned'" >&2
    exit 1
fi
grep -q "build_email_prompt: the mode must be send or compose, got 'sned'" "${TEST_ROOT}/prompt-mode.out"

echo "Claude and Codex backend integration tests passed."

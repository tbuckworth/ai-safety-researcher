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

cat > "${MOCK_BIN}/mock-provider" <<'MOCK_PROVIDER'
#!/usr/bin/env bash
set -euo pipefail

prompt=$(cat)
printf '%s %s\n' "$(basename "$0")" "$*" >> "$MOCK_CALL_LOG"
{
    printf '\n===== %s %s =====\n' "$(basename "$0")" "$*"
    printf '%s\n' "$prompt"
} >> "$MOCK_PROMPT_LOG"

if [[ "$prompt" == *"# Autonomous Research Email Composer"* ]]; then
    run_dir=$(printf '%s\n' "$prompt" |
        sed -n 's/^The run directory is: \*\*\(.*\)\*\*$/\1/p' |
        head -1)
    if [ -z "$run_dir" ]; then
        echo "mock provider could not parse email run directory" >&2
        exit 64
    fi
    printf '%s\n' '<html><body>Mock research report</body></html>' > "${run_dir}/email-draft.html"
    printf '%s\n' '[Auto-Research] Mock result' > "${run_dir}/email-subject.txt"
    echo "Mock email composition complete."
    exit 0
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

if [ "$step" = "11" ]; then
    new_status="complete"
else
    new_status="mock_step_complete"
fi

# Simulate a model rewriting Step 1 state from an incomplete schema. The
# wrapper must restore runtime-owned fields before the next step or resume.
if [ "$step" = "1" ]; then
    sed \
        -e '/^agent_backend:/d' \
        -e '/^agent_model:/d' \
        -e '/^compute_profile:/d' \
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

cat > "${TEST_ROOT}/send-email.py" <<'MOCK_EMAIL'
import os
import pathlib
import sys

args = sys.argv[1:]
html_path = pathlib.Path(args[args.index("--html") + 1])
if not html_path.is_file() or not html_path.read_text().strip():
    raise SystemExit("missing HTML draft")
with open(os.environ["MOCK_EMAIL_LOG"], "a", encoding="utf-8") as handle:
    handle.write(" ".join(args) + "\n")
print("Mock email sent.")
MOCK_EMAIL

export MOCK_CALL_LOG MOCK_PROMPT_LOG MOCK_EMAIL_LOG

run_case() {
    local backend="$1"
    local output_dir="${TEST_ROOT}/output-${backend}"
    local stdout_log="${TEST_ROOT}/${backend}.stdout"
    local fail_first=false

    if [ "$backend" = "codex" ]; then
        fail_first=true
    fi

    RESEARCHER_BACKEND="$backend" \
    RESEARCHER_CLAUDE_BIN="${MOCK_BIN}/claude" \
    RESEARCHER_CODEX_BIN="${MOCK_BIN}/codex" \
    RESEARCHER_CLAUDE_MODEL="mock-claude" \
    RESEARCHER_CODEX_MODEL="mock-codex" \
    RESEARCHER_CODEX_FAST_MODEL="mock-codex-fast" \
    RESEARCHER_CODEX_REASONING="high" \
    RESEARCHER_CODEX_SANDBOX="workspace-write" \
    RESEARCHER_CODEX_APPROVAL_POLICY="never" \
    RESEARCHER_OUTPUT_DIR="$output_dir" \
    RESEARCHER_LOCKFILE="${TEST_ROOT}/${backend}.lock" \
    RESEARCHER_LINK_OUTPUT="false" \
    RESEARCHER_SKIP_PUBLISH="true" \
    RESEARCHER_SKIP_GPU_CHECK="true" \
    RESEARCHER_STEP_ATTEMPTS="2" \
    RESEARCHER_RETRY_DELAY_SECONDS="0" \
    RESEARCHER_SEND_EMAIL_SCRIPT="${TEST_ROOT}/send-email.py" \
    RESEARCHER_EMAIL_TO="self@example.test" \
    MOCK_FAIL_FIRST_STEP="$fail_first" \
    MOCK_FAIL_MARKER="${TEST_ROOT}/${backend}.failed-once" \
    "$REPO_DIR/scripts/researcher-cron.sh" "Mock research topic ${backend}" \
        > "$stdout_log" 2>&1

    local state_file
    state_file=$(find "$output_dir" -mindepth 2 -maxdepth 2 -name state.md -type f | head -1)
    test -n "$state_file"
    grep -q '^status: complete$' "$state_file"
    grep -q "^agent_backend: ${backend}$" "$state_file"
    grep -q '^agent_model: "mock-' "$state_file"
    grep -q '^compute_profile: "' "$state_file"
    test -s "$(dirname "$state_file")/email-draft.html"
    test -s "$(dirname "$state_file")/email-subject.txt"

    if [ "$backend" = "codex" ]; then
        grep -q 'Mock transient provider failure' "$stdout_log"
        grep -q 'exit 42' "$stdout_log"
    fi
}

run_case claude
run_case codex

grep -q '^claude --print .*--model mock-claude' "$MOCK_CALL_LOG"
grep -q '^codex --search --ask-for-approval never exec .*--model mock-codex' "$MOCK_CALL_LOG"
grep -q -- '--sandbox workspace-write' "$MOCK_CALL_LOG"
grep -q -- '--ask-for-approval never' "$MOCK_CALL_LOG"
grep -q -- '--ignore-user-config' "$MOCK_CALL_LOG"
grep -q '# Codex Runtime Adapter' "$MOCK_PROMPT_LOG"
grep -q 'mock-codex-fast' "$MOCK_PROMPT_LOG"
test "$(wc -l < "$MOCK_EMAIL_LOG" | tr -d ' ')" = "2"
grep -q -- '--to self@example.test' "$MOCK_EMAIL_LOG"

# Invalid providers and accidental cross-provider resumes fail closed.
set +e
RESEARCHER_BACKEND="invalid" \
RESEARCHER_OUTPUT_DIR="${TEST_ROOT}/invalid-output" \
"$REPO_DIR/scripts/researcher-cron.sh" "Invalid backend" \
    > "${TEST_ROOT}/invalid.stdout" 2>&1
invalid_status=$?
set -e
test "$invalid_status" = "2"
grep -q "must be 'claude' or 'codex'" "${TEST_ROOT}/invalid.stdout"

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
"$REPO_DIR/scripts/researcher-cron.sh" "Resume mismatch" \
    > "${TEST_ROOT}/mismatch.stdout" 2>&1
mismatch_status=$?
set -e
test "$mismatch_status" = "2"
grep -q "in-progress run uses backend 'claude'" "${TEST_ROOT}/mismatch.stdout"

# Follow-up issues inherit the active backend's source label.
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
RESEARCHER_BACKEND=codex \
"$REPO_DIR/scripts/create-followup-issue.sh" \
    --parent 42 \
    --repo-url https://github.com/tbuckworth/research-example \
    --run-id prior-run \
    --feedback-file "${TEST_ROOT}/feedback.txt" \
    > "${TEST_ROOT}/followup.stdout"
grep -q -- '--label source:codex' "$MOCK_GH_LOG"
grep -q 'Created follow-up issue: https://github.com/tbuckworth/tasks/issues/123' \
    "${TEST_ROOT}/followup.stdout"

echo "Claude and Codex backend integration tests passed."

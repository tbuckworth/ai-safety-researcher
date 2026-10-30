#!/usr/bin/env bash
# End-to-end tests for the autonomous runner's run lifecycle: picking issues,
# timeouts, publishing, the final outcome, and reporting back to the issue.
#
# Every external service is mocked: a fake `gh` reads issues from a JSON file and
# records what it was asked to do, git pushes go to local bare repositories
# (RESEARCHER_GIT_REMOTE_BASE=file://...), and the model provider and email
# helper are stubs. No model, GitHub, GPU, or email calls are made.
#
# Each case reproduces a failure from the 2026 forensic review (tasks#2254).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CRON="${REPO_DIR}/scripts/researcher-cron.sh"
LIB="${REPO_DIR}/scripts/researcher_lib.py"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/researcher-lifecycle.XXXXXX")
trap '[ -n "${KEEP_TEST_ROOT:-}" ] || rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="${TEST_ROOT}/bin"
REMOTES="${TEST_ROOT}/remotes"
mkdir -p "$MOCK_BIN" "$REMOTES"

# Isolated git: no user config, no credential helpers, and git's historical
# default branch name — the condition under which runs committed on 'master'
# and pushed 'main' into empty repos.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig"
git config --global user.name "Lifecycle Test"
git config --global user.email "test@example.test"
git config --global init.defaultBranch master
git config --global advice.defaultBranchName false
# The real global hook runs gitleaks; this one blocks the same way on a mock
# secret, so the wrapper's handling of a refused commit is exercised.
mkdir -p "${TEST_ROOT}/hooks"
cat > "${TEST_ROOT}/hooks/pre-commit" <<'MOCK_HOOK'
#!/usr/bin/env bash
if git grep --cached -q MOCK-SECRET-VALUE 2>/dev/null; then
    echo "RuleID:      generic-api-key" >&2
    echo "COMMIT BLOCKED: a secret was found in your staged changes." >&2
    exit 1
fi
MOCK_HOOK
chmod +x "${TEST_ROOT}/hooks/pre-commit"
git config --global core.hooksPath "${TEST_ROOT}/hooks"

PASSES=0
fail() { echo "FAIL [${CASE:-setup}]: $*" >&2; exit 1; }
ok() { PASSES=$((PASSES + 1)); }
assert_grep() { grep -qE -- "$1" "$2" || fail "expected /$1/ in $(basename "$2")"; ok; }
assert_no_grep() { if grep -qE -- "$1" "$2"; then fail "did not expect /$1/ in $(basename "$2")"; fi; ok; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; ok; }

# --- mock gh -----------------------------------------------------------------
cat > "${MOCK_BIN}/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_GH_LOG"

label=""; jq_expr=""; json=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        --label) label="${args[$((i + 1))]}" ;;
        --jq) jq_expr="${args[$((i + 1))]}" ;;
        --json) json="${args[$((i + 1))]}" ;;
    esac
done

case "${1:-} ${2:-}" in
    "auth status") exit 0 ;;
    "label create") exit 0 ;;
    "repo create")
        if [ "${MOCK_GH_CREATE_FAIL:-false}" = "true" ]; then
            echo "HTTP 500: mock repo create failure" >&2
            exit 1
        fi
        bare="${MOCK_REMOTES}/$3.git"
        if [ -d "$bare" ]; then
            echo "GraphQL: Name already exists on this account" >&2
            exit 1
        fi
        git init -q --bare "$bare"
        vis=public
        case " $* " in *" --private "*) vis=private ;; *" --internal "*) vis=internal ;; esac
        echo "${MOCK_GH_FORCE_VISIBILITY:-$vis}" > "${bare}/mock-visibility"
        echo "https://github.com/$3"
        ;;
    "repo view")
        bare="${MOCK_REMOTES}/$3.git"
        [ -d "$bare" ] || { echo "GraphQL: Could not resolve to a Repository" >&2; exit 1; }
        if [ "$json" = "visibility" ]; then
            tr '[:lower:]' '[:upper:]' < "${bare}/mock-visibility"
        elif [ -n "$(git --git-dir="$bare" for-each-ref)" ]; then echo false; else echo true; fi
        ;;
    "issue list")
        if [ -n "$label" ]; then
            jq --arg l "$label" '[.[] | select(.labels | map(.name) | index($l))]' "$MOCK_ISSUES"
        else
            cat "$MOCK_ISSUES"
        fi
        ;;
    "issue view")
        obj=$(jq --argjson n "$3" '.[] | select(.number == $n)' "$MOCK_ISSUES")
        [ -n "$obj" ] || { echo "GraphQL: Could not resolve to an issue" >&2; exit 1; }
        if [ -n "$jq_expr" ]; then echo "$obj" | jq -r "$jq_expr"; else echo "$obj"; fi
        ;;
    "issue comment")
        n=$(ls "$MOCK_COMMENTS" | wc -l | tr -d ' ')
        for ((i = 0; i < ${#args[@]}; i++)); do
            case "${args[$i]}" in
                --body-file) cp "${args[$((i + 1))]}" "${MOCK_COMMENTS}/$3-$n.md" ;;
                --body) printf '%s\n' "${args[$((i + 1))]}" > "${MOCK_COMMENTS}/$3-$n.md" ;;
            esac
        done
        echo "https://github.com/tbuckworth/tasks/issues/$3#issuecomment-$n"
        ;;
    "issue create")
        jq '. + [{number: 999, title: "created", body: "", state: "OPEN", labels: []}]' "$MOCK_ISSUES" > "${MOCK_ISSUES}.tmp"
        mv "${MOCK_ISSUES}.tmp" "$MOCK_ISSUES"
        echo "https://github.com/tbuckworth/tasks/issues/999"
        ;;
    *) : ;;
esac
MOCK_GH
chmod +x "${MOCK_BIN}/gh"

# --- mock provider and agent-mail --------------------------------------------
# shellcheck source=tests/mocks.sh
source "${SCRIPT_DIR}/tests/mocks.sh"
install_mock_agent_mail "$MOCK_BIN"
install_mock_email_composer "$MOCK_BIN"

cat > "${MOCK_BIN}/claude" <<'MOCK_PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)

if [[ "$prompt" == *"# Autonomous Research Email Composer"* ]]; then
    exec "$(dirname "$0")/mock-email-composer" "$@" <<< "$prompt"
fi

argument=$(printf '%s\n' "$prompt" | sed -n 's/^The argument is: \*\*\([0-9][0-9]*\) \(.*\)\*\*$/\1|\2/p' | head -1)
step=${argument%%|*}
run_dir=${argument#*|}
state_file="${run_dir}/state.md"
echo "$step" >> "$MOCK_STEPS_LOG"

if [ "${MOCK_LIMIT_AT_STEP:-}" = "$step" ]; then
    # The headless CLI's limit notice, printed as the final line with exit 0.
    echo "Working on step ${step}..."
    echo "Claude AI usage limit reached|1754060400"
    exit 0
fi

if [ "${MOCK_STALL_AT_STEP:-}" = "$step" ]; then
    # The step stops early on purpose (e.g. it asked for more budget) and
    # leaves current_step where it was.
    [ -z "${MOCK_STALL_HOLD_FILE:-}" ] || echo "${MOCK_STALL_HOLD_TEXT:-waiting for budget}" > "$MOCK_STALL_HOLD_FILE"
    echo "Ending step ${step} without advancing."
    exit 0
fi

if [ "${MOCK_SUBMIT_AT_STEP:-}" = "$step" ] && [ ! -e "${MOCK_JOB_FILE}.submitted" ]; then
    # The step submits a cluster job and ends its turn while the job runs; its
    # next attempt finds the results and advances.
    touch "${MOCK_JOB_FILE}.submitted"
    echo 4242 > "$MOCK_JOB_FILE"
    echo "Submitted job 4242; ending step ${step} while it runs."
    exit 0
fi

case "$step" in
    9)
        exp="${run_dir}/experiments/exp-001"
        mkdir -p "$exp"
        printf '# exp-001 Results\n\n## Component Tested\nRouting localises the capability\n\n## Verdict: %s\n' \
            "${MOCK_VERDICT:-PASS}" > "${exp}/results.md"
        printf '| Check | Status | Evidence |\n|---|---|---|\n| method-fidelity | PASS | test |\n| training-sanity | %s | samples.json |\n' \
            "${MOCK_PREFLIGHT:-PASS}" > "${exp}/preflight.md"
        if [ "${MOCK_BIG_FILE:-false}" = "true" ]; then
            head -c 2097152 /dev/zero > "${exp}/big.dat"
        fi
        if [ "${MOCK_SECRET:-false}" = "true" ]; then
            # What the secret scan refused on 2026-10-28: a cite key read as a key.
            mkdir -p "${run_dir}/literature"
            printf 'Line one.\nCite key: `MOCK-SECRET-VALUE`\n' > "${run_dir}/literature/search-001-academic.md"
        fi
        if [ "${MOCK_NESTED_REPO:-false}" = "true" ]; then
            # An experiment that cloned a library, which it then dirtied.
            mkdir -p "${exp}/vendored-lib"
            git -C "${exp}/vendored-lib" init -q
            echo "lib" > "${exp}/vendored-lib/lib.py"
            git -C "${exp}/vendored-lib" add -A
            git -C "${exp}/vendored-lib" commit -q -m lib
            echo "dirty" > "${exp}/vendored-lib/output.txt"
        fi
        ;;
    11)
        mkdir -p "${run_dir}/paper"
        printf '%%PDF-1.4 mock\n' > "${run_dir}/paper/paper.pdf"
        printf '# Proposed Next Steps\n\n**Outcome**: Mock finding holds on the toy setup.\n\n## Ranked Next Steps\n\n### 1. Validate the metric at t=0\n- **Do**: x\n' \
            > "${run_dir}/next-steps.md"
        ;;
esac

if [ "${MOCK_STRIP_FIELDS_AT_STEP:-}" = "$step" ]; then
    # A model rewrite that drops wrapper-owned keys.
    grep -v -E '^(run_id|topic|issue_number|mode):' "$state_file" > "${state_file}.stripped"
    mv "${state_file}.stripped" "$state_file"
fi

if [ "${MOCK_BREAK_STATE_AT_STEP:-}" = "$step" ]; then
    # A model rewrite that loses the frontmatter's closing "---": the wrapper
    # can no longer write any field.
    sed -i '1!{/^---$/d}' "$state_file"
    echo "Ending step ${step} with a broken state.md."
    exit 0
fi

new_status="mock_step_complete"
[ "$step" = "11" ] && new_status="complete"
sed -e "s/^current_step:.*/current_step: ${step}/" -e "s/^status:.*/status: ${new_status}/" \
    "$state_file" > "${state_file}.tmp"
mv "${state_file}.tmp" "$state_file"
echo "Mock step ${step} complete."
MOCK_PROVIDER
chmod +x "${MOCK_BIN}/claude"

# A mock gitleaks: flags each staged file holding MOCK-SECRET-VALUE, as the
# real scan reports (JSON), unless MOCK_SECRET_UNSEEN (a scan that misses it).
cat > "${MOCK_BIN}/gitleaks" <<'MOCK_GITLEAKS'
#!/usr/bin/env bash
set -euo pipefail
report=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = "--report-path" ] && report="${args[$((i + 1))]}"
done
findings="[]"
if [ "${MOCK_SECRET_UNSEEN:-false}" != "true" ]; then
    while IFS= read -r -d '' file; do
        line=$(git show ":${file}" 2>/dev/null | grep -n -m1 MOCK-SECRET-VALUE | cut -d: -f1 || true)
        [ -n "$line" ] && findings=$(jq --arg f "$file" --argjson l "$line" \
            '. + [{File: $f, StartLine: $l, RuleID: "generic-api-key", Secret: "REDACTED"}]' <<< "$findings")
    done < <(git diff --cached --name-only -z)
fi
[ -z "$report" ] || printf '%s\n' "$findings" > "$report"
[ "$findings" = "[]" ]
MOCK_GITLEAKS
chmod +x "${MOCK_BIN}/gitleaks"

# --- helpers -----------------------------------------------------------------
issue_json() {
    # number title labels(comma-separated) body
    jq -n --argjson n "$1" --arg t "$2" --arg l "$3" --arg b "${4:-}" \
        '{number: $n, title: $t, body: $b, state: "OPEN",
          url: ("https://github.com/tbuckworth/tasks/issues/" + ($n | tostring)),
          labels: ($l | split(",") | map(select(length > 0)) | map({name: .}))}'
}

new_case() {
    CASE="$1"
    CASE_DIR="${TEST_ROOT}/case-${CASE}"
    OUT="${CASE_DIR}/output"
    mkdir -p "$OUT" "${CASE_DIR}/comments" "${CASE_DIR}/tmp"
    : > "${CASE_DIR}/gh.log"
    : > "${CASE_DIR}/steps.log"
    : > "${CASE_DIR}/email.log"
    echo '[]' > "${CASE_DIR}/issues.json"
}

set_issues() {
    jq -s '.' "$@" > "${CASE_DIR}/issues.json"
}

# run_researcher [VAR=value ...] [-- topic]
run_researcher() {
    local topic=()
    local env_args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; topic=("$@"); break; fi
        env_args+=("$1"); shift
    done
    set +e
    env PATH="${MOCK_BIN}:${PATH}" \
        TMPDIR="${CASE_DIR}/tmp" \
        MOCK_GH_LOG="${CASE_DIR}/gh.log" \
        MOCK_ISSUES="${CASE_DIR}/issues.json" \
        MOCK_COMMENTS="${CASE_DIR}/comments" \
        MOCK_REMOTES="$REMOTES" \
        MOCK_STEPS_LOG="${CASE_DIR}/steps.log" \
        MOCK_EMAIL_LOG="${CASE_DIR}/email.log" \
        RESEARCHER_BACKEND=claude \
        RESEARCHER_CLAUDE_BIN="${MOCK_BIN}/claude" \
        RESEARCHER_CLAUDE_MODEL=mock-claude \
        RESEARCHER_OUTPUT_DIR="$OUT" \
        RESEARCHER_LOCKFILE="${CASE_DIR}/lock" \
        RESEARCHER_LINK_OUTPUT=false \
        RESEARCHER_SKIP_GPU_CHECK=true \
        RESEARCHER_STEP_ATTEMPTS=1 \
        RESEARCHER_RETRY_DELAY_SECONDS=0 \
        RESEARCHER_KB_DIR=none \
        RESEARCHER_HOST_ALIAS=mock-host \
        RESEARCHER_EMAIL_TO=self@example.test \
        RESEARCHER_AGENT_MAIL="${MOCK_BIN}/agent-mail" \
        RESEARCHER_GIT_REMOTE_BASE="file://${REMOTES}" \
        RESEARCHER_MIN_FREE_MB=1 \
        ${env_args[@]+"${env_args[@]}"} \
        "$CRON" ${topic[@]+"${topic[@]}"} > "${CASE_DIR}/stdout.log" 2>&1
    RC=$?
    set -e
}

run_dir_for_issue() {
    grep -l "^issue_number: $1\$" "$OUT"/*/state.md 2>/dev/null | head -1 | xargs -r dirname
}

field() { grep -m1 "^$1:" "$2/state.md" | sed "s/^$1: *//; s/^\"//; s/\"\$//"; }

make_bare_remote() {
    # owner/name, then files as path=content pairs; commits them to main.
    # Visibility comes from REMOTE_VISIBILITY (default private).
    local name="$1"; shift
    local work="${TEST_ROOT}/work-${name//\//-}"
    git init -q --bare "${REMOTES}/${name}.git"
    git init -q "$work"
    local pair
    for pair in "$@"; do
        mkdir -p "$(dirname "${work}/${pair%%=*}")"
        printf '%s\n' "${pair#*=}" > "${work}/${pair%%=*}"
    done
    git -C "$work" add -A
    git -C "$work" commit -q -m "prior run"
    git -C "$work" push -q "file://${REMOTES}/${name}.git" HEAD:refs/heads/main
    git --git-dir="${REMOTES}/${name}.git" symbolic-ref HEAD refs/heads/main
    echo "${REMOTE_VISIBILITY:-private}" > "${REMOTES}/${name}.git/mock-visibility"
    rm -rf "$work"
}

age_file_days() {
    python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]) * 86400; os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

write_run() {
    # dir current_step status [mode]
    local dir="${OUT}/$1"
    mkdir -p "${dir}/experiments"
    cat > "${dir}/state.md" <<STATE
---
run_id: $1
topic: "Pre-existing run $1"
current_step: $2
status: $3
mode: ${4:-autonomous}
agent_backend: claude
agent_model: "mock-claude"
issue_number: ${5:-none}
---

Pre-existing run.
STATE
}

# =============================================================================
# 1. Publish: private repo, main branch even with init.defaultBranch=master,
#    verified push, oversized file left out, findings posted to the issue.
# =============================================================================
new_case publish
set_issues <(issue_json 101 "Gradient routing persistence" "list:research-ideas" "Does routing persist?")
run_researcher RESEARCHER_MAX_FILE_MB=1 MOCK_BIG_FILE=true MOCK_NESTED_REPO=true
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 101)
[ -n "$RUN" ] || fail "no run directory for #101"
SLUG="research-gradient-routing-persistence"
assert_grep "^repo create tbuckworth/${SLUG} --private " "${CASE_DIR}/gh.log"
assert_no_grep "--public" "${CASE_DIR}/gh.log"
assert_eq "$(git -C "$RUN" rev-parse --abbrev-ref HEAD)" "main" "local branch"
assert_eq "$(git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" rev-parse refs/heads/main)" \
    "$(git -C "$RUN" rev-parse HEAD)" "remote main = local HEAD"
[ -z "$(git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" for-each-ref refs/heads/master)" ] || fail "master was pushed"; ok
assert_eq "$(cat "${RUN}/.repo_url")" "https://github.com/tbuckworth/${SLUG}" ".repo_url"
if git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" ls-tree -r --name-only main | grep -q 'big.dat'; then
    fail "oversized file was published"
fi; ok
[ -f "${RUN}/experiments/exp-001/big.dat" ] || fail "oversized file was deleted locally"; ok
assert_grep "not publishing experiments/exp-001/big.dat" "${CASE_DIR}/stdout.log"
if git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" ls-tree -r --name-only main | grep -q 'vendored-lib'; then
    fail "nested git repo was published"
fi; ok
assert_eq "$(git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" cat-file -p "main:experiments/exp-001/results.md" | grep -c Verdict)" "1" "experiment results published"
assert_eq "$(git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" cat-file -p main:README.md | head -1)" \
    "# Gradient routing persistence" "run README published"
assert_eq "$(field final_outcome "$RUN")" "complete" "final_outcome"
assert_eq "$(field publish_state "$RUN")" "pushed" "publish_state"
assert_eq "$(jq -r .outcome "${RUN}/run-outcome.json")" "complete" "run-outcome.json"
COMMENT=$(ls "${CASE_DIR}"/comments/101-*.md)
assert_grep "outcome: complete" "$COMMENT"
assert_grep "https://github.com/tbuckworth/${SLUG}/tree/main \(private\)" "$COMMENT"
assert_grep "https://github.com/tbuckworth/${SLUG}/blob/main/paper/paper.pdf" "$COMMENT"
assert_grep "\| exp-001 \| Routing localises the capability \| PASS \|" "$COMMENT"
assert_grep "Mock finding holds on the toy setup" "$COMMENT"
assert_grep "1\. Validate the metric at t=0" "$COMMENT"
assert_grep "vendored-lib/ not published: it is a separate git repository" "$COMMENT"
assert_grep "big.dat not published" "$COMMENT"
assert_grep "issue edit 101 --repo tbuckworth/tasks --add-label status:claude-processed" "${CASE_DIR}/gh.log"
assert_grep "^--subject \[Auto-Research\] Mock result" "${CASE_DIR}/email.log"
# Sent by the email session itself (its id), reviewed, never unrouted.
SESSION=$(sed -n 's/.*(session \([0-9a-f-]\{36\}\)).*/\1/p' "${CASE_DIR}/stdout.log" | head -1)
[ -n "$SESSION" ] || fail "no email session id logged"; ok
assert_grep "from=${SESSION} " "${CASE_DIR}/email.log"
assert_no_grep "unrouted" "${CASE_DIR}/email.log"
assert_grep "Email sent to self@example.test from the agents' account" "${CASE_DIR}/stdout.log"
[ -s "${RUN}/.email-sent" ] || fail "no .email-sent record"; ok
assert_grep "Final outcome: complete" "${RUN}/.email-prompt.txt"
assert_grep "send-results-email.sh ${RUN}" "${RUN}/.email-prompt.txt"
assert_grep "agent-mail: NOT SENT" "${RUN}/.email-prompt.txt"
[ ! -e "${RUN}/.issue-comment.md" ] || fail "comment scratch file left behind"; ok

# =============================================================================
# 2. Push failure is surfaced: no link anywhere, outcome 'unpublished',
#    flagged email subject, non-zero exit.
# =============================================================================
new_case push-failure
set_issues <(issue_json 102 "Memetic disease transmission" "list:research-ideas")
run_researcher MOCK_GH_CREATE_FAIL=true
assert_eq "$RC" "4" "exit code"
RUN=$(run_dir_for_issue 102)
[ ! -e "${RUN}/.repo_url" ] || fail ".repo_url written for a failed push"; ok
assert_eq "$(field final_outcome "$RUN")" "unpublished" "final_outcome"
COMMENT=$(ls "${CASE_DIR}"/comments/102-*.md)
assert_grep "finished but NOT PUBLISHED" "$COMMENT"
assert_grep "local only at \`mock-host:" "$COMMENT"
assert_no_grep "github.com/tbuckworth/research-" "$COMMENT"
assert_grep "^--subject \[UNPUBLISHED\] \[Auto-Research\]" "${CASE_DIR}/email.log"
assert_grep "Published: NO" "${RUN}/.email-prompt.txt"

# =============================================================================
# 3. A nearly full disk stops publishing before git touches it, and says why.
# =============================================================================
new_case disk-full
set_issues <(issue_json 103 "Salad versus soup" "list:research-ideas")
run_researcher RESEARCHER_MIN_FREE_MB=999999999
assert_eq "$RC" "4" "exit code"
RUN=$(run_dir_for_issue 103)
[ ! -d "${RUN}/.git" ] || fail "git ran on a full disk"; ok
assert_no_grep "^repo create" "${CASE_DIR}/gh.log"
jq -e '.reasons | any(test("disk nearly full"))' "${RUN}/run-outcome.json" > /dev/null || fail "disk reason missing"; ok
assert_grep "disk nearly full" "$(ls "${CASE_DIR}"/comments/103-*.md)"

# =============================================================================
# 4. A timeout after experiments compiles the report and the run stays
#    'complete' (it used to be overwritten to 'failed').
# =============================================================================
new_case timeout-after-experiments
write_run 2026-01-01-timeout 9 experiments_complete
mkdir -p "${OUT}/2026-01-01-timeout/experiments/exp-001"
printf '## Component Tested\nX\n\n## Verdict: FAIL\n' > "${OUT}/2026-01-01-timeout/experiments/exp-001/results.md"
printf '| method-fidelity | PASS | t |\n' > "${OUT}/2026-01-01-timeout/experiments/exp-001/preflight.md"
run_researcher RESEARCHER_TIMEOUT_SECONDS=-1 RESEARCHER_SKIP_PUBLISH=true -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN="${OUT}/2026-01-01-timeout"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "steps run (audit skipped, report compiled)"
assert_eq "$(field status "$RUN")" "complete" "status"
assert_eq "$(field timed_out "$RUN")" "true" "timed_out"
assert_eq "$(field final_outcome "$RUN")" "complete-local" "final_outcome"
jq -e '.reasons | any(test("audit was skipped"))' "${RUN}/run-outcome.json" > /dev/null || fail "timeout reason missing"; ok

# =============================================================================
# 5. A timeout before any results ends 'timed_out' / 'failed', never complete.
# =============================================================================
new_case timeout-early
write_run 2026-01-02-early 2 research_complete
run_researcher RESEARCHER_TIMEOUT_SECONDS=-1 RESEARCHER_SKIP_PUBLISH=true -- "Ignored topic"
assert_eq "$RC" "4" "exit code"
assert_eq "$(field status "${OUT}/2026-01-02-early")" "timed_out" "status"
assert_eq "$(field final_outcome "${OUT}/2026-01-02-early")" "failed" "final_outcome"
[ ! -s "${CASE_DIR}/steps.log" ] || fail "a step ran after the timeout"; ok

# =============================================================================
# 6. Picking: an issue that already ran here is not run again (tasks#1898),
#    a weeks-old unfinished run and an interactive run are not resumed.
# =============================================================================
new_case pick-dedupe
write_run 2026-03-24-old-run 11 complete autonomous 201
write_run 2026-08-25-stale 5 active autonomous
age_file_days "${OUT}/2026-08-25-stale/state.md" 30
write_run 2026-10-01-interactive 7 experiments_planned interactive
set_issues <(issue_json 201 "Loss basin hypothesis" "list:research-ideas") \
           <(issue_json 200 "Out-of-context scheming" "list:research-ideas")
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_grep "not resuming .*2026-08-25-stale" "${CASE_DIR}/stdout.log"
assert_grep "skip #201: already has a local run" "${CASE_DIR}/stdout.log"
assert_grep "Picked issue #200" "${CASE_DIR}/stdout.log"
[ -n "$(run_dir_for_issue 200)" ] || fail "no run for #200"; ok
assert_eq "$(field status "${OUT}/2026-08-25-stale")" "active" "stale run untouched"
assert_eq "$(field status "${OUT}/2026-10-01-interactive")" "experiments_planned" "interactive run untouched"

# =============================================================================
# 7. The same follow-up request filed twice runs once (tasks#1919/#1920).
# =============================================================================
new_case duplicate-followup
DUP_BODY=$'Needs a more realistic model organism.\n\n---\nParent: #1874 | Repo: https://github.com/tbuckworth/research-salad | Run: 2026-04-03-salad'
set_issues <(issue_json 1920 "[Follow-up] Needs a more realistic model organism" "list:research-ideas,type:follow-up,status:claude-processed" "$DUP_BODY") \
           <(issue_json 1919 "[Follow-up] Needs a more realistic model organism" "list:research-ideas,type:follow-up" "$DUP_BODY")
run_researcher
assert_eq "$RC" "0" "exit code"
assert_grep "skip #1919: duplicate follow-up" "${CASE_DIR}/stdout.log"
assert_grep "No unprocessed research ideas found" "${CASE_DIR}/stdout.log"
[ -z "$(ls -A "$OUT" | grep -v '^logs$' || true)" ] || fail "a run directory was created"; ok

# =============================================================================
# 8. Follow-up publishing works in place: the branch continues the prior repo,
#    keeps its files, adds this run's, excludes prior/, and nothing is staged
#    in TMPDIR (the April follow-ups filled /tmp and were lost).
# =============================================================================
new_case followup
make_bare_remote tbuckworth/research-prior \
    "README.md=prior readme" "prior-only.txt=kept" "state.md=prior state" \
    "method-spec.md=## Salad" "experiments/exp-001/results.md=## Verdict: PASS" \
    "references.bib=@article{prior2026}" "citation-registry.md=| prior2026 | verified |"
# The feedback has a rule of its own; only the footer's rule ends it.
FOLLOWUP_BODY=$'Use a bigger model organism.\n\n---\n\nKeep the old metric.\n\n---\nParent: #399 | Repo: https://github.com/tbuckworth/research-prior | Run: prior-run'
set_issues <(issue_json 400 "[Follow-up] Use a bigger model organism" "list:research-ideas,type:follow-up" "$FOLLOWUP_BODY")
run_researcher
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 400)
for path in method-spec.md references.bib citation-registry.md experiments/exp-001/results.md; do
    [ -f "${RUN}/prior/${path}" ] || fail "prior ${path} not carried over"
    ok
done
assert_grep "Keep the old metric" "${RUN}/followup-context.md"
assert_grep "Keep the old metric" "${RUN}/topic.txt"
assert_no_grep "Parent: #399" "${RUN}/topic.txt"
assert_eq "$(field prior_run_id "$RUN")" "prior-run" "prior_run_id"
grep -qE '^followup_key: [0-9a-f]{16}$' "${RUN}/state.md" || fail "followup_key not recorded"; ok
BARE="${REMOTES}/tbuckworth/research-prior.git"
BRANCH=$(git --git-dir="$BARE" for-each-ref --format='%(refname:short)' 'refs/heads/followup-*')
[ -n "$BRANCH" ] || fail "no follow-up branch pushed"; ok
TREE=$(git --git-dir="$BARE" ls-tree -r --name-only "$BRANCH")
for path in prior-only.txt followup-context.md topic.txt experiments/exp-001/results.md .gitignore; do
    printf '%s\n' "$TREE" | grep -qx "$path" || fail "branch is missing ${path}"
    ok
done
if printf '%s\n' "$TREE" | grep -q '^prior/'; then fail "prior/ was published"; fi; ok
assert_eq "$(git --git-dir="$BARE" cat-file -p "${BRANCH}:README.md")" "prior readme" "the prior repo's README kept"
assert_eq "$(git --git-dir="$BARE" rev-parse "${BRANCH}^")" "$(git --git-dir="$BARE" rev-parse main)" "branch parent is prior main"
assert_eq "$(cat "${RUN}/.repo_url")" "https://github.com/tbuckworth/research-prior/tree/${BRANCH}" ".repo_url"
assert_grep "outcome: complete" "$(ls "${CASE_DIR}"/comments/400-*.md)"
assert_grep "^Follow-up #400 finished" "$(ls "${CASE_DIR}"/comments/399-*.md)"
[ -z "$(ls -A "${CASE_DIR}/tmp")" ] || fail "files left in TMPDIR: $(ls -A "${CASE_DIR}/tmp")"; ok
[ -z "$(ls -A "${OUT}/.tmp" 2>/dev/null)" ] || fail "prior clone left behind"; ok

# =============================================================================
# 9. A slug already holding another run's repo is not pushed into.
# =============================================================================
new_case slug-collision
make_bare_remote tbuckworth/research-collision-topic "README.md=another run"
OTHER_HEAD=$(git --git-dir="${REMOTES}/tbuckworth/research-collision-topic.git" rev-parse main)
set_issues <(issue_json 500 "Collision topic" "list:research-ideas")
run_researcher
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 500)
assert_eq "$(git --git-dir="${REMOTES}/tbuckworth/research-collision-topic.git" rev-parse main)" "$OTHER_HEAD" "other run's repo untouched"
NEW_SLUG=$(cat "${RUN}/.publish_repo")
[ "$NEW_SLUG" != "research-collision-topic" ] || fail "reused the occupied slug"; ok
assert_eq "$(cat "${RUN}/.repo_url")" "https://github.com/tbuckworth/${NEW_SLUG}" ".repo_url"

# =============================================================================
# 10. Filing a follow-up is idempotent.
# =============================================================================
new_case create-followup
printf '%s\n' "Needs a more realistic model organism." > "${CASE_DIR}/feedback.txt"
FILED_BODY=$'Needs a more realistic model organism.\n\n---\nParent: #1874 | Repo: https://github.com/tbuckworth/research-salad | Run: 2026-04-03-salad'
set_issues <(issue_json 1919 "[Follow-up] Needs a more realistic model organism" "list:research-ideas,type:follow-up" "$FILED_BODY")
followup() {
    env PATH="${MOCK_BIN}:${PATH}" MOCK_GH_LOG="${CASE_DIR}/gh.log" MOCK_ISSUES="${CASE_DIR}/issues.json" \
        MOCK_COMMENTS="${CASE_DIR}/comments" \
        "${REPO_DIR}/scripts/create-followup-issue.sh" --parent 1874 \
        --repo-url https://github.com/tbuckworth/research-salad --run-id 2026-04-03-salad \
        --feedback-file "${CASE_DIR}/feedback.txt" > "${CASE_DIR}/followup.out"
}
followup
assert_grep "Follow-up already exists \(same request\): https://github.com/tbuckworth/tasks/issues/1919" "${CASE_DIR}/followup.out"
assert_no_grep "^issue create" "${CASE_DIR}/gh.log"
echo '[]' > "${CASE_DIR}/issues.json"
followup
assert_grep "issue create .*<!-- followup-key: [0-9a-f]{16} -->" <(tr '\n' ' ' < "${CASE_DIR}/gh.log")
assert_grep "Created follow-up issue" "${CASE_DIR}/followup.out"
# The follow-up takes its parent's importance (agent-spare only starts high or
# medium ideas), or medium when the parent has none or cannot be read.
assert_grep "--label importance:medium --body" <(grep '^issue create' "${CASE_DIR}/gh.log" | tail -1)
for imp in high low; do
    set_issues <(issue_json 1874 "Salad topic" "list:research-ideas,importance:${imp}")
    followup
    assert_grep "--label importance:${imp} --body" <(grep '^issue create' "${CASE_DIR}/gh.log" | tail -1)
done
set_issues <(issue_json 1874 "Salad topic" "list:research-ideas")
followup
assert_grep "--label importance:medium --body" <(grep '^issue create' "${CASE_DIR}/gh.log" | tail -1)

# =============================================================================
# 11. An EMPTY public repo left by the old master/main bug is not reused:
#     results would go public while every report said private.
# =============================================================================
new_case empty-public-repo
git init -q --bare "${REMOTES}/tbuckworth/research-empty-public-topic.git"
echo public > "${REMOTES}/tbuckworth/research-empty-public-topic.git/mock-visibility"
set_issues <(issue_json 700 "Empty public topic" "list:research-ideas")
run_researcher
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 700)
[ -z "$(git --git-dir="${REMOTES}/tbuckworth/research-empty-public-topic.git" for-each-ref)" ] || fail "pushed into the empty public repo"; ok
NEW_SLUG=$(cat "${RUN}/.publish_repo")
assert_eq "$(cat "${REMOTES}/tbuckworth/${NEW_SLUG}.git/mock-visibility")" "private" "new repo visibility"
assert_grep "\(private\)" "$(ls "${CASE_DIR}"/comments/700-*.md)"

# =============================================================================
# 12. If GitHub reports a different visibility than requested, nothing is pushed.
# =============================================================================
new_case visibility-mismatch
set_issues <(issue_json 701 "Visibility mismatch topic" "list:research-ideas")
run_researcher MOCK_GH_FORCE_VISIBILITY=public
assert_eq "$RC" "4" "exit code"
RUN=$(run_dir_for_issue 701)
assert_eq "$(field final_outcome "$RUN")" "unpublished" "final_outcome"
[ -z "$(git --git-dir="${REMOTES}/tbuckworth/research-visibility-mismatch-topic.git" for-each-ref)" ] || fail "pushed into a public repo"; ok
jq -e '.reasons | any(test("is public, not private"))' "${RUN}/run-outcome.json" > /dev/null || fail "visibility reason missing"; ok

# =============================================================================
# 13. A follow-up of a follow-up continues the named branch
#     (.../tree/<branch>), not the default branch.
# =============================================================================
new_case followup-of-followup
make_bare_remote tbuckworth/research-chain "README.md=chain readme" "state.md=main state"
CHAIN_WORK="${CASE_DIR}/chain-work"
git clone -q "file://${REMOTES}/tbuckworth/research-chain.git" "$CHAIN_WORK"
git -C "$CHAIN_WORK" checkout -q -b followup-2026-09-01-first
echo "first follow-up state" > "${CHAIN_WORK}/state.md"
echo "only on the follow-up branch" > "${CHAIN_WORK}/chain-only.txt"
git -C "$CHAIN_WORK" add -A && git -C "$CHAIN_WORK" commit -q -m "first follow-up"
git -C "$CHAIN_WORK" push -q origin followup-2026-09-01-first
CHAIN_BASE=$(git -C "$CHAIN_WORK" rev-parse HEAD)
CHAIN_BODY=$'Now try a 7B organism.\n\n---\nParent: #398 | Repo: https://github.com/tbuckworth/research-chain/tree/followup-2026-09-01-first | Run: first-followup'
set_issues <(issue_json 401 "[Follow-up] Now try a 7B organism" "list:research-ideas,type:follow-up" "$CHAIN_BODY")
run_researcher
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 401)
assert_grep "first follow-up state" "${RUN}/prior/state.md"
BARE="${REMOTES}/tbuckworth/research-chain.git"
BRANCH=$(git --git-dir="$BARE" for-each-ref --format='%(refname:short)' 'refs/heads/followup-*' | grep -v first)
assert_eq "$(git --git-dir="$BARE" rev-parse "${BRANCH}^")" "$CHAIN_BASE" "based on the continued branch"
git --git-dir="$BARE" ls-tree -r --name-only "$BRANCH" | grep -qx chain-only.txt || fail "continued branch's files missing"; ok
assert_eq "$(cat "${RUN}/.repo_url")" "https://github.com/tbuckworth/research-chain/tree/${BRANCH}" ".repo_url"

# =============================================================================
# 14. A follow-up never pushes private-mode results into a public prior repo.
# =============================================================================
new_case followup-public-prior
REMOTE_VISIBILITY=public make_bare_remote tbuckworth/research-public-prior "README.md=public"
PUB_BODY=$'More seeds please.\n\n---\nParent: #397 | Repo: https://github.com/tbuckworth/research-public-prior | Run: public-run'
set_issues <(issue_json 402 "[Follow-up] More seeds please" "list:research-ideas,type:follow-up" "$PUB_BODY")
run_researcher
assert_eq "$RC" "4" "exit code"
RUN=$(run_dir_for_issue 402)
assert_eq "$(field final_outcome "$RUN")" "unpublished" "final_outcome"
[ -z "$(git --git-dir="${REMOTES}/tbuckworth/research-public-prior.git" for-each-ref 'refs/heads/followup-*')" ] || fail "pushed into a public prior repo"; ok
assert_grep "research-public-prior is public, not private, so nothing was pushed there" "$(ls "${CASE_DIR}"/comments/402-*.md)"

# =============================================================================
# 15. A usage-limit notice during Step 11 pauses the run; it is not counted as
#     a completed step (which used to hot-loop the provider until timeout).
# =============================================================================
new_case limit-at-report
write_run 2026-01-03-limit 10 audit_complete
run_researcher MOCK_LIMIT_AT_STEP=11 -- "Ignored topic"
assert_eq "$RC" "3" "exit code (paused)"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "provider calls"
assert_eq "$(field status "${OUT}/2026-01-03-limit")" "audit_complete" "status left resumable"
[ -z "$(ls -A "${CASE_DIR}/comments")" ] || fail "a paused run commented on an issue"; ok

# 15b. ...and the same during a Step 10 remediation round: the notice must not
#      count as a finished audit round (that silently skipped remediation).
new_case limit-at-audit
write_run 2026-01-05-audit-limit 10 audit_remediating
run_researcher MOCK_LIMIT_AT_STEP=10 -- "Ignored topic"
assert_eq "$RC" "3" "exit code (paused)"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "10 " "provider calls"
assert_eq "$(field status "${OUT}/2026-01-05-audit-limit")" "audit_remediating" "status left resumable"

# 15c. A guard (RESEARCHER_GUARD_CMD) holds the run between steps: it pauses
#      before calling the provider, records why, and resumes once it is quiet.
new_case guard-hold
write_run 2026-01-06-guard 3 mock_step_complete
echo "other agents are busy on this login" > "${CASE_DIR}/hold"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=cat ${CASE_DIR}/hold" -- "Ignored topic"
assert_eq "$RC" "3" "exit code (paused by guard)"
[ ! -s "${CASE_DIR}/steps.log" ] || fail "the provider ran although the guard held"; ok
assert_eq "$(field current_step "${OUT}/2026-01-06-guard")" "3" "current_step kept"
assert_eq "$(field last_pause_reason "${OUT}/2026-01-06-guard")" "other agents are busy on this login" "pause reason"
assert_grep "Guard: other agents are busy" "${CASE_DIR}/stdout.log"
: > "${CASE_DIR}/hold"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=cat ${CASE_DIR}/hold" -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "4 5 6 7 8 9 10 11 " "resumed at step 4"

# 15c'. A step that ends without advancing because the guard now holds (it
#       asked for budget mid-step) pauses instead of spending its retries.
new_case guard-mid-step
write_run 2026-01-09-guard-mid 8 mock_step_complete
: > "${CASE_DIR}/hold"
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_STEP_ATTEMPTS=3 MOCK_STALL_AT_STEP=9 \
    "MOCK_STALL_HOLD_FILE=${CASE_DIR}/hold" "RESEARCHER_GUARD_CMD=cat ${CASE_DIR}/hold" -- "Ignored topic"
assert_eq "$RC" "3" "exit code (paused mid-step by guard)"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "9 " "one attempt, no retries"
assert_eq "$(field current_step "${OUT}/2026-01-09-guard-mid")" "8" "current_step kept"
assert_eq "$(field last_pause_reason "${OUT}/2026-01-09-guard-mid")" "waiting for budget" "pause reason"

# 15e. A pinned run: RESEARCHER_RUN_DIR resumes exactly that run even when a
#      newer unfinished one exists, and refuses a finished one; NO_RESUME starts
#      the requested issue fresh instead of resuming something else.
new_case pinned-run
write_run 2026-01-10-mine 10 audit_complete
mkdir -p "${OUT}/2026-01-10-mine/experiments/exp-001"
printf '## Component Tested\nX\n\n## Verdict: PASS\n' > "${OUT}/2026-01-10-mine/experiments/exp-001/results.md"
printf '| method-fidelity | PASS | t |\n' > "${OUT}/2026-01-10-mine/experiments/exp-001/preflight.md"
write_run 2026-01-11-someone-elses 3 mock_step_complete
touch "${OUT}/2026-01-11-someone-elses/state.md"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_RUN_DIR=${OUT}/2026-01-10-mine" -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "resumed the pinned run only"
assert_eq "$(field current_step "${OUT}/2026-01-11-someone-elses")" "3" "the other run untouched"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_RUN_DIR=${OUT}/2026-01-10-mine" -- "Ignored topic"
assert_eq "$RC" "2" "a finished pinned run is refused"
: > "${CASE_DIR}/steps.log"
set_issues <(issue_json 301 "Fresh idea" "list:research-ideas" "Body")
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true RESEARCHER_NO_RESUME=true RESEARCHER_ISSUE=301
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
[ -n "$(run_dir_for_issue 301)" ] || fail "no fresh run for #301"; ok
assert_eq "$(field current_step "${OUT}/2026-01-11-someone-elses")" "3" "still untouched"

# 15d. ...but never while the run's cluster jobs are outstanding, and a guard
#      that fails without printing anything holds nothing.
new_case guard-jobs
write_run 2026-01-07-guard-jobs 10 audit_complete
mkdir -p "${OUT}/2026-01-07-guard-jobs/experiments/exp-001"
printf '## Component Tested\nX\n\n## Verdict: PASS\n' > "${OUT}/2026-01-07-guard-jobs/experiments/exp-001/results.md"
printf '| method-fidelity | PASS | t |\n' > "${OUT}/2026-01-07-guard-jobs/experiments/exp-001/preflight.md"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=echo hold" \
    "RESEARCHER_JOB_WAIT_CMD=echo 4242" -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "the step ran despite the hold"
assert_grep "job\(s\) 4242 are still outstanding" "${CASE_DIR}/stdout.log"
# The job-wait hook is time-limited like the guard: a hung one is stopped.
new_case job-hook-timeout
write_run 2026-01-17-job-hook 10 audit_complete
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=echo hold" \
    "RESEARCHER_JOB_WAIT_CMD=sleep 5; touch ${CASE_DIR}/hook-finished; echo 4242" \
    RESEARCHER_JOB_WAIT_CMD_TIMEOUT_SECONDS=1 -- "Ignored topic"
[ ! -e "${CASE_DIR}/hook-finished" ] || fail "the job-wait hook ran past its time limit"; ok
assert_grep "WARN: hook stopped at its 1s limit" "${CASE_DIR}/stdout.log"
# ...except a hold marked "!" (a stop), which applies at once: before a step,
# and while a stalled step waits for its jobs.
new_case guard-stop-jobs
write_run 2026-01-12-guard-stop 10 audit_complete
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=echo '! stopped by Titus'" \
    "RESEARCHER_JOB_WAIT_CMD=echo 4242" -- "Ignored topic"
assert_eq "$RC" "3" "exit code (stopped despite jobs)"
[ ! -s "${CASE_DIR}/steps.log" ] || fail "a step ran although the run was stopped"; ok
assert_eq "$(field last_pause_reason "${OUT}/2026-01-12-guard-stop")" "stopped by Titus" "pause reason"
new_case guard-stop-wait
write_run 2026-01-13-guard-wait 8 mock_step_complete
: > "${CASE_DIR}/hold"
run_researcher RESEARCHER_SKIP_PUBLISH=true MOCK_STALL_AT_STEP=9 "MOCK_STALL_HOLD_FILE=${CASE_DIR}/hold" \
    "MOCK_STALL_HOLD_TEXT=! stopped by Titus" "RESEARCHER_GUARD_CMD=cat ${CASE_DIR}/hold" \
    "RESEARCHER_JOB_WAIT_CMD=echo 4242" RESEARCHER_JOB_WAIT_POLL_SECONDS=1 -- "Ignored topic"
assert_eq "$RC" "3" "exit code (stopped while waiting)"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "9 " "no retry after the stop"
assert_eq "$(field current_step "${OUT}/2026-01-13-guard-wait")" "8" "current_step kept"
assert_grep "Guard: stopped by Titus \(job\(s\) 4242 keep running" "${CASE_DIR}/stdout.log"
# A step that ends while its job runs is retried, once the job has left the
# queue (the mock squeue below reports it once), without spending an attempt...
new_case job-wait-refund
write_run 2026-01-18-job-refund 8 mock_step_complete
run_researcher RESEARCHER_SKIP_PUBLISH=true MOCK_SUBMIT_AT_STEP=9 "MOCK_JOB_FILE=${CASE_DIR}/job" \
    "RESEARCHER_JOB_WAIT_CMD=cat ${CASE_DIR}/job 2>/dev/null; rm -f ${CASE_DIR}/job" \
    RESEARCHER_JOB_WAIT_POLL_SECONDS=1 -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "9 9 10 11 " "step 9 retried after its job"
assert_grep "retrying without spending an attempt \(refund 1/10\)" "${CASE_DIR}/stdout.log"
# ...but a job that outlasts the step's wait budget spends the attempt.
new_case job-wait-gave-up
write_run 2026-01-19-job-gave-up 8 mock_step_complete
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true MOCK_STALL_AT_STEP=9 \
    "RESEARCHER_JOB_WAIT_CMD=echo 4242" RESEARCHER_JOB_WAIT_POLL_SECONDS=1 RESEARCHER_JOB_WAIT_MAX_SECONDS=1 \
    -- "Ignored topic"
assert_eq "$RC" "4" "exit code (failed)"
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "9 " "one attempt"
assert_grep "giving up on waiting" "${CASE_DIR}/stdout.log"
assert_eq "$(field status "${OUT}/2026-01-19-job-gave-up")" "failed" "status"

# 15f. A run with an owner (RESEARCHER_OWNER) is never resumed by a plain run,
#      and keeps its owner through the steps.
new_case owned-run
write_run 2026-01-14-owned 3 mock_step_complete
sed -i 's/^mode: autonomous$/mode: autonomous\nowner: agent-spare/' "${OUT}/2026-01-14-owned/state.md"
set_issues <(issue_json 302 "Owned idea" "list:research-ideas" "Body")
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true RESEARCHER_ISSUE=302
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(field current_step "${OUT}/2026-01-14-owned")" "3" "the owned run untouched"
assert_grep "Not resuming .*2026-01-14-owned: it belongs to agent-spare" "${CASE_DIR}/stdout.log"
assert_eq "$(field owner "$(run_dir_for_issue 302)")" "" "a plain run has no owner"
set_issues <(issue_json 303 "Spare idea" "list:research-ideas" "Body")
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true RESEARCHER_OWNER=agent-spare \
    RESEARCHER_NO_RESUME=true RESEARCHER_ISSUE=303
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(field owner "$(run_dir_for_issue 303)")" "agent-spare" "the owner is recorded and kept"
run_researcher "RESEARCHER_OWNER=bad owner" -- "Ignored topic"
assert_eq "$RC" "2" "an unsafe owner is refused"
new_case guard-broken
write_run 2026-01-08-guard-broken 10 audit_complete
mkdir -p "${OUT}/2026-01-08-guard-broken/experiments/exp-001"
printf '## Component Tested\nX\n\n## Verdict: PASS\n' > "${OUT}/2026-01-08-guard-broken/experiments/exp-001/results.md"
printf '| method-fidelity | PASS | t |\n' > "${OUT}/2026-01-08-guard-broken/experiments/exp-001/preflight.md"
run_researcher RESEARCHER_SKIP_PUBLISH=true "RESEARCHER_GUARD_CMD=false" -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "a silent failing guard holds nothing"

# =============================================================================
# 16. A pause inside the timeout fast-track resumes at Step 11, not at the
#     step after the one that timed out.
# =============================================================================
new_case timeout-pause-resume
write_run 2026-01-04-tpr 7 experiments_planned
mkdir -p "${OUT}/2026-01-04-tpr/experiments/exp-001"
printf '## Component Tested\nX\n\n## Verdict: PASS\n' > "${OUT}/2026-01-04-tpr/experiments/exp-001/results.md"
printf '| method-fidelity | PASS | t |\n' > "${OUT}/2026-01-04-tpr/experiments/exp-001/preflight.md"
run_researcher RESEARCHER_TIMEOUT_SECONDS=-1 MOCK_LIMIT_AT_STEP=11 RESEARCHER_SKIP_PUBLISH=true -- "Ignored topic"
assert_eq "$RC" "3" "first invocation pauses"
assert_eq "$(field current_step "${OUT}/2026-01-04-tpr")" "10" "current_step after fast-track"
: > "${CASE_DIR}/steps.log"
run_researcher RESEARCHER_SKIP_PUBLISH=true -- "Ignored topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "11 " "resume runs only the report"
assert_eq "$(field final_outcome "${OUT}/2026-01-04-tpr")" "complete-local" "final_outcome"
jq -e '.reasons | any(test("audit was skipped"))' "${OUT}/2026-01-04-tpr/run-outcome.json" > /dev/null || fail "timeout caveat lost on resume"; ok

# =============================================================================
# 17. Two runs of the same topic on the same day get separate directories.
# =============================================================================
new_case same-day-rerun
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true -- "Same topic"
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true -- "Same topic"
assert_eq "$(ls -d "$OUT"/*-same-topic* | wc -l | tr -d ' ')" "2" "run directories"
ls -d "$OUT"/*-same-topic-2 > /dev/null || fail "second run not suffixed"; ok
# A topic whose 60-character cut ends between two words names its run without
# a trailing hyphen.
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true -- \
    "Does gradient routing localise unwanted capabilities in toy models"
ls -d "$OUT"/*-does-gradient-routing-localise-unwanted-capabilities-in-toy > /dev/null \
    || fail "run directory not named by the trimmed slug: $(ls "$OUT")"; ok

# =============================================================================
# 17b. state.md values a model quoted or commented are read as YAML values: a
#      quoted terminal status is not resumed, and a quoted run_id does not
#      leak its quotes into the reports.
# =============================================================================
new_case quoted-state
write_run 2026-01-16-quoted-done 11 '"complete"  # report compiled'
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true -- "Fresh quoted topic"
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
assert_eq "$(tr '\n' ' ' < "${CASE_DIR}/steps.log")" "1 2 3 4 5 6 7 8 9 10 11 " "a fresh run, not the finished one"
ls -d "$OUT"/*-fresh-quoted-topic > /dev/null || fail "no run for the topic"; ok
# A topic with quotes and backslashes is written to state.md and read back intact.
QUOTED_TOPIC='Is "honesty" one direction? Compare C:\new and \"x\"'
run_researcher RESEARCHER_SKIP_PUBLISH=true RESEARCHER_SKIP_EMAIL=true -- "$QUOTED_TOPIC"
RUN=$(ls -d "$OUT"/*-is-honesty-one-direction-*)
assert_eq "$(python3 "$LIB" state-field "${RUN}/state.md" topic)" "$QUOTED_TOPIC" "topic round trip"
new_case quoted-run-id
write_run 2026-01-15-quoted 2 research_complete autonomous 950
sed -i 's/^run_id: .*/run_id: "2026-01-15-quoted"/' "${OUT}/2026-01-15-quoted/state.md"
run_researcher RESEARCHER_TIMEOUT_SECONDS=-1 -- "Ignored topic"
assert_eq "$RC" "4" "exit code"
assert_grep "^<!-- researcher-run: 2026-01-15-quoted outcome: failed -->" "$(ls "${CASE_DIR}"/comments/950-*.md)"

# =============================================================================
# 18. A model rewrite that drops run_id/topic/issue_number does not silently
#     kill the wrapper before publishing and reporting.
# =============================================================================
new_case stripped-state
set_issues <(issue_json 800 "Stripped state topic" "list:research-ideas")
run_researcher MOCK_STRIP_FIELDS_AT_STEP=11
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 800)
[ -n "$RUN" ] || fail "issue_number not restored"; ok
assert_eq "$(field run_id "$RUN")" "$(basename "$RUN")" "run_id restored"
assert_grep "outcome: complete" "$(ls "${CASE_DIR}"/comments/800-*.md)"

# 18b. A state.md the wrapper cannot write stops the run (exit 1) and says so;
#      nothing writes a field anywhere else in the file instead.
new_case broken-state
write_run 2026-01-21-broken 10 audit_complete
run_researcher RESEARCHER_SKIP_PUBLISH=true MOCK_BREAK_STATE_AT_STEP=11 -- "Ignored topic"
assert_eq "$RC" "1" "exit code"
assert_grep "ERROR: could not write status: failed to .*2026-01-21-broken/state.md" "${CASE_DIR}/stdout.log"
assert_no_grep "^status: failed" "${OUT}/2026-01-21-broken/state.md"

# =============================================================================
# 19. The secret scan refuses a staged file (2026-10-28: a cite key read as an
#     API key). It is left out with the reason and the rest is published.
# =============================================================================
new_case secret-scan
set_issues <(issue_json 901 "Secret scan false positive" "list:research-ideas")
run_researcher MOCK_SECRET=true
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 901)
SLUG="research-secret-scan-false-positive"
assert_eq "$(field publish_state "$RUN")" "pushed" "publish_state"
if git --git-dir="${REMOTES}/tbuckworth/${SLUG}.git" ls-tree -r --name-only main | grep -q 'search-001-academic.md'; then
    fail "flagged file was published"
fi; ok
[ -f "${RUN}/literature/search-001-academic.md" ] || fail "flagged file was removed locally"; ok
assert_grep "literature/search-001-academic.md not published: the secret scan flagged line 2 \(generic-api-key\)" \
    "$(ls "${CASE_DIR}"/comments/901-*.md)"

# =============================================================================
# 20. A commit the hook refuses reports the hook's reason, not a disk guess.
# =============================================================================
new_case commit-refused
set_issues <(issue_json 902 "Commit refused by hook" "list:research-ideas")
run_researcher MOCK_SECRET=true MOCK_SECRET_UNSEEN=true
assert_eq "$RC" "4" "exit code"
RUN=$(run_dir_for_issue 902)
assert_eq "$(field final_outcome "$RUN")" "unpublished" "final_outcome"
assert_grep "git commit failed: COMMIT BLOCKED: a secret was found in your staged changes" "${RUN}/run-outcome.json"
assert_no_grep "disk full" "${RUN}/run-outcome.json"
assert_grep "^--subject \[UNPUBLISHED\] \[Auto-Research\]" "${CASE_DIR}/email.log"

# =============================================================================
# 21. The pre-send review holds the first mail: the session fixes it and sends
#     once more; a session that stops without sending has its draft sent for it.
# =============================================================================
new_case review-pushback
set_issues <(issue_json 903 "Review pushback" "list:research-ideas")
run_researcher MOCK_REVIEW_PUSHBACK=true
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
RUN=$(run_dir_for_issue 903)
assert_eq "$(wc -l < "${CASE_DIR}/email.log.held" | tr -d ' ')" "1" "held once"
assert_eq "$(wc -l < "${CASE_DIR}/email.log" | tr -d ' ')" "1" "sent once"
assert_grep "Revised after the review" "${RUN}/email-draft.html"

new_case email-not-sent
set_issues <(issue_json 904 "Session stops before sending" "list:research-ideas")
run_researcher MOCK_EMAIL_NO_SEND=true
[ "$RC" = 0 ] || { cat "${CASE_DIR}/stdout.log"; fail "exit $RC"; }
SESSION=$(sed -n 's/.*(session \([0-9a-f-]\{36\}\)).*/\1/p' "${CASE_DIR}/stdout.log" | head -1)
assert_grep "The email session stopped without sending" "${CASE_DIR}/stdout.log"
assert_grep "from=${SESSION} " "${CASE_DIR}/email.log"

echo "Researcher lifecycle tests passed (${PASSES} assertions)."

# shellcheck shell=bash
# The backend's settings, building the step and email prompts, and invoking the
# Claude or Codex CLI. Sourced by scripts/researcher-cron.sh and
# scripts/send-run-report.sh; the functions use their globals.

# shellcheck disable=SC2034 # The globals it sets are read by the other runner files.
select_backend() {
    # Sets the globals of a run on RESEARCHER_BACKEND (one branch per backend in
    # researcher_lib.py BACKENDS): BACKEND, PROVIDER_BIN, MODEL (RESEARCHER_MODEL,
    # else the backend's configured model; for Claude, the model of the run's
    # login when it has one of its own: use_claude_login), AGENT_LABEL,
    # CONTINUE_COMMAND, COMMIT_ATTRIBUTION, the run's Claude login
    # (use_claude_login) and, for Codex, the parent's reasoning and the deep
    # workers. The Codex CLI's own settings (CODEX_BIN, the fast model and its
    # reasoning, sandbox, approval policy, user config) are set for either
    # backend, since Codex may write the results email of a Claude run. Exits 2
    # for an unknown backend, a Codex run on a Claude login
    # (codex_without_claude_login), and a login use_claude_login refuses.
    # In report mode, a saved login that cannot write is recorded as a failed
    # writer. The report still describes the model and login that ran.
    BACKEND="$RESEARCHER_BACKEND"
    CODEX_BIN="$RESEARCHER_CODEX_BIN"
    CODEX_FAST_MODEL="$RESEARCHER_CODEX_FAST_MODEL"
    CODEX_FAST_REASONING="$RESEARCHER_CODEX_FAST_REASONING"
    CODEX_SANDBOX="$RESEARCHER_CODEX_SANDBOX"
    CODEX_APPROVAL_POLICY="$RESEARCHER_CODEX_APPROVAL_POLICY"
    CODEX_IGNORE_USER_CONFIG="$RESEARCHER_CODEX_IGNORE_USER_CONFIG"
    case "$BACKEND" in
        claude)
            PROVIDER_BIN="$RESEARCHER_CLAUDE_BIN"
            MODEL="${RESEARCHER_MODEL:-$RESEARCHER_CLAUDE_MODEL}"
            use_claude_login "$1" || exit 2
            AGENT_LABEL="Claude ${MODEL}${RESEARCHER_CLAUDE_LOGIN:+ (login ${RESEARCHER_CLAUDE_LOGIN})}"
            CONTINUE_COMMAND="/researcher-continue"
            COMMIT_ATTRIBUTION="Co-Authored-By: Claude (autonomous researcher) <noreply@anthropic.com>"
            ;;
        codex)
            codex_without_claude_login
            use_claude_login "$1"   # none: it sets the globals of no login
            PROVIDER_BIN="$CODEX_BIN"
            MODEL="${RESEARCHER_MODEL:-$RESEARCHER_CODEX_MODEL}"
            CODEX_REASONING="$RESEARCHER_CODEX_REASONING"
            # The deep workers run the parent's model and effort unless set apart.
            CODEX_DEEP_MODEL="${RESEARCHER_CODEX_DEEP_MODEL:-${MODEL}}"
            CODEX_DEEP_REASONING="${RESEARCHER_CODEX_DEEP_REASONING:-${CODEX_REASONING}}"
            CODEX_MAX_SUBAGENTS="$RESEARCHER_CODEX_MAX_SUBAGENTS"
            AGENT_LABEL="OpenAI Codex ${MODEL} (${CODEX_REASONING})"
            CONTINUE_COMMAND="\$researcher:researcher-continue"
            COMMIT_ATTRIBUTION="Generated-By: OpenAI Codex (${MODEL}, ${CODEX_REASONING})"
            ;;
        *)
            echo "ERROR: RESEARCHER_BACKEND must be one of: $(python3 "$LIB" backends); got '${BACKEND}'." >&2
            exit 2
            ;;
    esac
}

codex_without_claude_login() {
    # A Codex run runs on no Claude login, so it drops RESEARCHER_CLAUDE_LOGIN,
    # unless this launch sets it (given_by_launch): that exits 2. A login the
    # run's saved settings gave is dropped on a resume that switches the run to
    # Codex (an accepted change of RESEARCHER_BACKEND in RUN_CONFIG_CHANGES),
    # and the drop is added to RUN_CONFIG_CHANGES as accepted by whoever
    # accepted the switch; without such a switch the saved settings contradict
    # themselves, and that exits 2. One the configuration file gave applies to
    # Claude runs only. Each drop is logged.
    local name="${RESEARCHER_CLAUDE_LOGIN:-}" accepted_by
    [ -n "$name" ] || return 0
    if given_by_launch RESEARCHER_CLAUDE_LOGIN; then
        echo "ERROR: this launch sets RESEARCHER_CLAUDE_LOGIN=${name}, the Claude login a Claude run runs on, but the backend is codex. Unset RESEARCHER_CLAUDE_LOGIN, or set RESEARCHER_BACKEND=claude." >&2
        exit 2
    fi
    if setting_restored RESEARCHER_CLAUDE_LOGIN; then
        accepted_by=$(jq -r 'map(select(.setting == "RESEARCHER_BACKEND"))[0].accepted_by // empty' \
            <<< "${RUN_CONFIG_CHANGES:-[]}")
        if [ -z "$accepted_by" ]; then
            echo "ERROR: the run's saved settings (run-config.json) put this Codex run on the Claude login ${name} (RESEARCHER_CLAUDE_LOGIN), which only a Claude run runs on." >&2
            exit 2
        fi
        RUN_CONFIG_CHANGES=$(jq -c --arg from "$name" --arg by "$accepted_by" \
            '. + [{setting: "RESEARCHER_CLAUDE_LOGIN", from: $from, to: null, accepted_by: $by}]' <<< "$RUN_CONFIG_CHANGES")
        log "Resuming on Codex, which runs on no Claude login: the run's RESEARCHER_CLAUDE_LOGIN (${name}) is dropped (accepted with the switch of backend: ${accepted_by}); run-config.json records the saved and the new value."
    else
        log "The configured RESEARCHER_CLAUDE_LOGIN (${name}) is for Claude runs; this Codex run runs on no Claude login."
    fi
    RESEARCHER_CLAUDE_LOGIN=""
}

# shellcheck disable=SC2034 # The globals it sets are read by the other runner files.
use_claude_login() {
    # The Claude login the run's Claude sessions run on, RESEARCHER_CLAUDE_LOGIN
    # (empty: none, and the sessions run in the environment the runner has).
    # Looks it up once, with the mailroom's `agent-usage login NAME --json`,
    # and sets CLAUDE_LOGIN (its name), CLAUDE_LOGIN_DIR (its config dir;
    # empty: the default login), CLAUDE_LOGIN_ARGS (the options claude takes
    # there), CLAUDE_LOGIN_MODEL (the one model it runs, or empty) and
    # CLAUDE_LOGIN_UNSET (the variables of another login the runner inherited,
    # which its sessions drop: researcher_lib.py CLAUDE_LOGIN_ENV). On a login
    # with a model of its own, MODEL becomes that model: researcher_lib.py
    # claude-login refuses a RESEARCHER_MODEL or RESEARCHER_CLAUDE_MODEL that
    # this launch sets to another model (given_by_launch), and replaces one the
    # configuration file or the run's saved settings gave, saying so. Returns
    # 2 on rejection at launch. In report mode a rejected writer is skipped,
    # with CLAUDE_LOGIN_FAILURE describing why.
    local mode="$1" name="${RESEARCHER_CLAUDE_LOGIN:-}" usage found out setting saved_model writer_model given=()
    CLAUDE_LOGIN=""
    CLAUDE_LOGIN_FAILURE=""
    CLAUDE_LOGIN_DIR=""
    CLAUDE_LOGIN_MODEL=""
    CLAUDE_LOGIN_ARGS=()
    CLAUDE_LOGIN_UNSET=()
    [ -n "$name" ] || return 0
    if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        echo "ERROR: RESEARCHER_CLAUDE_LOGIN must be the name of a Claude login (letters, digits, '_', '.' and '-'), got '${name}'." >&2
        return 2
    fi
    saved_model=""
    if [ "$mode" = report ] && [ -f "${RUN_DIR}/run-config.json" ]; then
        saved_model=$(jq -r --arg name "$name" 'select(.resolved.claude_login == $name) | .resolved.model // empty' \
            "${RUN_DIR}/run-config.json") || return 2
        MODEL="${saved_model:-$MODEL}"
    fi
    for setting in RESEARCHER_MODEL RESEARCHER_CLAUDE_MODEL; do
        if given_by_launch "$setting"; then
            given+=(--given "${setting}=${!setting}")
        fi
    done
    usage=$(mailroom_tool agent-usage)
    if [ ! -x "$usage" ]; then
        echo "ERROR: RESEARCHER_CLAUDE_LOGIN=${name}: the login is looked up with the mailroom's agent-usage, and ${usage} is not installed." >&2
        CLAUDE_LOGIN_FAILURE="agent-usage is not installed"
    elif ! found=$("$usage" login "$name" --json); then
        echo "ERROR: RESEARCHER_CLAUDE_LOGIN=${name}: '${usage} login ${name} --json' failed (its error is above), so the run cannot run on that login." >&2
        CLAUDE_LOGIN_FAILURE="the saved login could not be looked up"
    elif ! out=$(python3 "$LIB" claude-login --name "$name" --model "$MODEL" ${given[@]+"${given[@]}"} <<< "$found"); then
        CLAUDE_LOGIN_FAILURE="the login configuration was rejected"
    else
        writer_model=$(jq -r '.model' <<< "$out") || return 2
        if [ -n "$saved_model" ] && [ "$writer_model" != "$saved_model" ]; then
            CLAUDE_LOGIN_FAILURE="the login now runs ${writer_model}; the run used ${saved_model}"
        fi
    fi
    if [ -n "$CLAUDE_LOGIN_FAILURE" ]; then
        [ "$mode" = report ] && return 0
        return 2
    fi
    CLAUDE_LOGIN="$name"
    CLAUDE_LOGIN_DIR=$(jq -r '.config_dir' <<< "$out")
    CLAUDE_LOGIN_MODEL=$(jq -r '.fixed_model' <<< "$out")
    mapfile -d '' -t CLAUDE_LOGIN_ARGS < <(jq -j '.args[] | ., "\u0000"' <<< "$out")
    mapfile -d '' -t CLAUDE_LOGIN_UNSET < <(jq -j '.unset[] | ., "\u0000"' <<< "$out")
    if [ -n "$(jq -r '.replaced' <<< "$out")" ]; then
        log "The Claude login ${name} runs only ${CLAUDE_LOGIN_MODEL}: the run uses it in place of $(jq -r '.replaced' <<< "$out"), the model its configured or saved settings name."
    fi
    MODEL="$writer_model"
}

login_environment() {
    # login_environment CONFIG_DIR: in the subshell a Claude session starts in,
    # the environment of the Claude login whose config dir is CONFIG_DIR: drops
    # what without_inherited_session names, then puts CLAUDE_CONFIG_DIR at
    # CONFIG_DIR (unset when it is empty: the default login).
    without_inherited_session
    if [ -n "$1" ]; then
        export CLAUDE_CONFIG_DIR="$1"
    else
        unset CLAUDE_CONFIG_DIR
    fi
}

build_codex_preamble() {
    # The Codex adapter the interactive Codex skills also follow
    # (templates/codex-adapter.md), then this run's worker models and what is
    # particular to an autonomous step.
    cat "${REPO_DIR}/templates/codex-adapter.md"
    cat <<EOF

Worker models for this run: fast \`${CODEX_FAST_MODEL}\` with \`${CODEX_FAST_REASONING}\` reasoning; deep \`${CODEX_DEEP_MODEL}\` with \`${CODEX_DEEP_REASONING}\` reasoning.

- The plugin-root placeholder has already been replaced with an absolute path.
- Execute exactly one autonomous workflow step and update state.md before exit.
EOF
}

# shellcheck disable=SC2034 # The globals it sets are read by the other runner files.
runtime_limits() {
    # Sets the limits the runtime header gives every prompt, from the run
    # settings: MAX_FILE_MB, MAX_EXPERIMENTS, EXPERIMENT_MINUTES, MAX_AUDIT_ROUNDS.
    MAX_FILE_MB="$RESEARCHER_MAX_FILE_MB"
    MAX_EXPERIMENTS="$RESEARCHER_MAX_EXPERIMENTS"
    EXPERIMENT_MINUTES="$RESEARCHER_EXPERIMENT_MINUTES"
    MAX_AUDIT_ROUNDS="$RESEARCHER_MAX_AUDIT_ROUNDS"
}

build_runtime_header() {
    cat <<EOF
# Injected Runtime Configuration

- Agent backend: ${BACKEND}
- Parent model: ${MODEL}${RESEARCHER_CLAUDE_LOGIN:+ (on the Claude login ${RESEARCHER_CLAUDE_LOGIN})}
- Plugin root: ${REPO_DIR}
- Run output root: ${OUTPUT_DIR}
- Global knowledge base: ${KB_DIR:-none (this run is not using one)}
- Local code to search (read-only): ${CODE_SEARCH_DIR}
- Experiment limits: at most ${MAX_EXPERIMENTS} experiments in the run, each targeting under ${EXPERIMENT_MINUTES} minutes of compute, and every file under ${MAX_FILE_MB} MB (the publisher leaves larger files out of the run's repository)
- Audit rounds (R_MAX): at most ${MAX_AUDIT_ROUNDS}
EOF
}

# Strip a command file's YAML frontmatter, and NOTHING else.
#
# The obvious `sed '/^---$/,/^---$/d'` is wrong: sed pairs up EVERY `---` in
# the file, so with Markdown section separators it deletes alternate sections
# of the document, whole workflow steps among them, without a word. Match only
# the frontmatter: a `---` on line 1, up to the next `---`.
strip_frontmatter() {
    awk '
        NR == 1 && $0 == "---" { in_fm = 1; next }
        in_fm && $0 == "---"   { in_fm = 0; next }
        in_fm                  { next }
        { print }
    ' "$1"
}

# render_command FILE ARGUMENT: the command file FILE as a prompt, with its
# frontmatter stripped, {{argument}} replaced by ARGUMENT and
# ${CLAUDE_PLUGIN_ROOT} by the plugin root.
render_command() {
    strip_frontmatter "$1" | sed "s|{{argument}}|$2|g" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${REPO_DIR}|g"
}

build_step_prompt() {
    local step="$1" retained_data_only="$2"
    build_runtime_header
    if [ "$retained_data_only" = true ]; then
        printf '\n%s\n' '- Audit mode: retained data only (prospective methods approval could not be verified).'
    fi
    if [ "$BACKEND" = "codex" ]; then
        build_codex_preamble
    fi
    render_command "${REPO_DIR}/commands/researcher-auto-step.md" "${step} ${RUN_DIR}"
}

build_email_prompt() {
    # $1: "send" (this session sends it with the helper, and handles the review)
    # or "compose" (write the files only; the wrapper sends them); anything else
    # is an error. The handoff gives facts only; commands/researcher-auto-email.md
    # holds the rules.
    local delivery published issue
    case "${1:-}" in
        send) delivery="- Send it yourself, to ${EMAIL_TO}, with:
      ${SEND_EMAIL} ${RUN_DIR}" ;;
        compose) delivery="- Compose only; the wrapper sends it to ${EMAIL_TO}." ;;
        *)
            log "ERROR: build_email_prompt: the mode must be send or compose, got '${1:-}'." >&2
            return 1
            ;;
    esac
    case "${PUBLISH_STATE:-}" in
        pushed) published="yes, verified on GitHub (${PUBLISHED_VISIBILITY:-unknown visibility} repo): $(cat "${RUN_DIR}/.repo_url" 2>/dev/null)" ;;
        failed) published="NO - ${PUBLISH_ERROR}" ;;
        *) published="no (publishing skipped for this run)" ;;
    esac
    issue=$(issue_url)
    build_runtime_header
    cat <<EOF

# Autonomous Email Handoff

- HTML draft: ${RUN_DIR}/email-draft.html
- Subject file: ${RUN_DIR}/email-subject.txt
- Inline plot list: ${RUN_DIR}/email-images.txt
- Footer agent label: ${AGENT_LABEL}
- Original issue: ${issue:-none}
${delivery}

## Continuation facts

- Run host SSH alias: ${HOST_ALIAS}
- Plugin directory on the run host: ${CONTINUE_DIR}
- Run directory on the run host: ${RUN_DIR}
- Continue command: ${CONTINUE_COMMAND} ${RUN_DIR}
- Agent to start in the plugin directory: ${PROVIDER_BIN}

## Wrapper-verified outcome

- Final outcome: ${FINAL_OUTCOME:-unknown}
- Workflow status: ${STATUS:-unknown}
- Published: ${published}
- Caveats:
${OUTCOME_REASONS:-  - none}
- Machine-readable outcome: ${RUN_DIR}/run-outcome.json
EOF
    render_command "${REPO_DIR}/commands/researcher-auto-email.md" "$RUN_DIR"
}

# invoke_claude LIMIT BIN MODEL TOOLS [ARG...]: runs the Claude CLI BIN
# headless on the prompt on stdin, without permission prompts, with model MODEL,
# only the tools TOOLS (comma-separated), and any further ARGs (after --model,
# so a login's own --model, CLAUDE_LOGIN_ARGS, is the one that counts), stopped
# after LIMIT seconds (run_limited; "none": never).
invoke_claude() {
    local limit="$1" bin="$2" cli_model="$3" tools="$4"
    shift 4
    run_limited "$limit" "$bin" --print --dangerously-skip-permissions --model "$cli_model" "$@" --allowedTools "$tools"
}

# invoke_codex LIMIT MODEL REASONING [ARG...]: runs the Codex CLI (CODEX_BIN)
# headless on the prompt on stdin, in the plugin directory with the run output
# root (and the knowledge base) writable, on MODEL with REASONING effort and any
# further ARGs (-c overrides), stopped after LIMIT seconds (run_limited).
invoke_codex() {
    local limit="$1" cli_model="$2" reasoning="$3"
    shift 3
    local codex_args=(
        --search
        --ask-for-approval "$CODEX_APPROVAL_POLICY"
        exec
        --ephemeral
        --cd "$REPO_DIR"
        --add-dir "$OUTPUT_DIR"
        --sandbox "$CODEX_SANDBOX"
    )
    # The knowledge base lives outside the plugin and output roots, so
    # Codex cannot write to it unless it is explicitly granted.
    # (an `[ ... ] && ...` one-liner would return 1 with no KB and, under
    # set -e, abort the run rather than skip the flag)
    if [ -n "$KB_DIR" ]; then
        codex_args+=(--add-dir "$KB_DIR")
    fi
    codex_args+=(
        --model "$cli_model"
        -c "model_reasoning_effort=\"${reasoning}\""
        "$@"
        # unattended: the startup update menu would wait for a keypress for ever
        -c "check_for_update_on_startup=false"
    )
    if is_true "$CODEX_IGNORE_USER_CONFIG"; then
        codex_args+=(--ignore-user-config)
    fi
    codex_args+=(-)
    run_limited "$limit" "$CODEX_BIN" "${codex_args[@]}"
}

invoke_provider() {
    # One branch per backend in researcher_lib.py BACKENDS. A Claude session
    # runs on the run's Claude login, if it has one (login_environment, with
    # the login's options), and otherwise in the runner's environment.
    case "$BACKEND" in
        claude)
            (
                if [ -n "$CLAUDE_LOGIN" ]; then
                    login_environment "$CLAUDE_LOGIN_DIR"
                fi
                invoke_claude none "$PROVIDER_BIN" "$MODEL" "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch,Task" \
                    ${CLAUDE_LOGIN_ARGS[@]+"${CLAUDE_LOGIN_ARGS[@]}"}
            )
            ;;
        codex)
            invoke_codex none "$MODEL" "$CODEX_REASONING" \
                -c "agents.default_subagent_model=\"${CODEX_DEEP_MODEL}\"" \
                -c "agents.default_subagent_reasoning_effort=\"${CODEX_DEEP_REASONING}\"" \
                -c "agents.max_concurrent_threads_per_session=${CODEX_MAX_SUBAGENTS}"
            ;;
    esac
}

run_step_provider() {
    build_step_prompt "$@" | invoke_provider
}

build_next_steps_prompt() {
    # The handoff gives facts only; commands/researcher-auto-next-steps.md
    # holds the rules.
    build_runtime_header
    cat <<EOF

# Next-Steps Handoff

- Last step's provider output: ${LAST_STEP_LOG:-none (no step ran in this launch)}
EOF
    render_command "${REPO_DIR}/commands/researcher-auto-next-steps.md" "$RUN_DIR"
}

run_next_steps_provider() {
    build_next_steps_prompt | invoke_provider
}

without_inherited_session() {
    # Unsets the variables REPORT_UNSET (read_report_logins) and
    # CLAUDE_LOGIN_UNSET (use_claude_login) name: a login, endpoint, model, API
    # key or session id this process inherited, which the email writer's CLI
    # must not take for its own. For the subshell a writer runs in.
    local name
    for name in ${REPORT_UNSET[@]+"${REPORT_UNSET[@]}"} ${CLAUDE_LOGIN_UNSET[@]+"${CLAUDE_LOGIN_UNSET[@]}"}; do
        unset "$name"
    done
}

run_email_claude() {
    # run_email_claude CONFIG_DIR MODEL [ARG...]: a Claude session with a known
    # id (EMAIL_SESSION) writes and sends the email, so Titus's reply resumes
    # this session (the mailroom routes by session id, on whichever login holds
    # it). It runs in the environment of the login whose config dir is
    # CONFIG_DIR (login_environment; empty: the default login), on MODEL, with
    # the login's options ARG (the run's own login: CLAUDE_LOGIN_ARGS), and is
    # stopped after EMAIL_TIMEOUT_SECONDS.
    local config_dir="$1" model="$2" name
    shift 2
    case "${ISSUE_NUMBER:-none}" in
        none) name="researcher" ;;
        *) name="researcher #${ISSUE_NUMBER}" ;;
    esac
    build_email_prompt send | (
        login_environment "$config_dir"
        invoke_claude "$EMAIL_TIMEOUT_SECONDS" "$EMAIL_CLAUDE_BIN" "$model" "Read,Write,Glob,Grep,Bash" \
            --session-id "$EMAIL_SESSION" --name "$name" "$@"
    )
}

run_email_codex() {
    # Codex writes the email only (the wrapper sends it), on the run's fast
    # Codex model, without what REPORT_UNSET names, stopped after
    # EMAIL_TIMEOUT_SECONDS.
    build_email_prompt compose | (
        without_inherited_session
        invoke_codex "$EMAIL_TIMEOUT_SECONDS" "$CODEX_FAST_MODEL" "$CODEX_FAST_REASONING"
    )
}

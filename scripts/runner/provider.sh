# shellcheck shell=bash
# Building the step and email prompts and invoking the Claude or Codex CLI.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

build_codex_preamble() {
    cat <<EOF
# Codex Runtime Adapter

This workflow was authored with Claude Code vocabulary. Translate it to Codex
semantics rather than treating the pseudocode as literal shell or API syntax.

- A \`Task(...)\` block means: spawn a Codex leaf subagent, give it the complete
  prompt in the block, wait for it, and use its returned result.
- Keep leaf agents from spawning further agents or interacting with the user.
- Run explicitly parallel Task blocks concurrently and wait for all results.
- Map search-planner and search workers to model \`${CODEX_FAST_MODEL}\` with
  \`${CODEX_FAST_REASONING}\` reasoning when that override is available.
- Map novelty, criteria, decomposition, challenge, experiment, audit, and report
  workers to model \`${CODEX_DEEP_MODEL}\` with \`${CODEX_DEEP_REASONING}\`
  reasoning when that override is available.
- Translate Read/Write/Edit/Glob/Grep/Bash/WebSearch/WebFetch to the available
  Codex filesystem, shell, and web tools.
- The plugin-root placeholder has already been replaced with an absolute path.
- Execute exactly one autonomous workflow step and update state.md before exit.
EOF
}

build_runtime_header() {
    cat <<EOF
# Injected Runtime Configuration

- Agent backend: ${BACKEND}
- Parent model: ${MODEL}
- Plugin root: ${REPO_DIR}
- Run output root: ${OUTPUT_DIR}
- Global knowledge base: ${KB_DIR:-none (this run is not using one)}
EOF
}

# Strip a command file's YAML frontmatter, and NOTHING else.
#
# The obvious `sed '/^---$/,/^---$/d'` is wrong and was wrong here for a long
# time: sed pairs up EVERY `---` in the file, so with markdown section
# separators it deletes alternating sections of the document. That silently
# dropped half the workflow — including whole steps — from every step prompt.
# Match only the frontmatter: a `---` on line 1, up to the next `---`.
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
    local step="$1"
    build_runtime_header
    if [ "$BACKEND" = "codex" ]; then
        build_codex_preamble
    fi
    render_command "${REPO_DIR}/commands/researcher-auto-step.md" "${step} ${RUN_DIR}"
}

build_email_prompt() {
    # $1: "send" (this session sends it with the helper, and handles the review)
    # or "compose" (write the files only; the wrapper sends them).
    build_runtime_header
    cat <<EOF

# Autonomous Email Handoff

- Write the HTML to: ${RUN_DIR}/email-draft.html
- Write the single-line subject to: ${RUN_DIR}/email-subject.txt
- Inline plots (optional, recommended for results): one NAME=relative/path.png
  per line in ${RUN_DIR}/email-images.txt, each placed as <img src="cid:NAME" alt="...">
- Footer agent label: ${AGENT_LABEL}
EOF
    if [ "${1:-send}" = "send" ]; then
        cat <<EOF
- Send it yourself, once both files are written, with exactly:
      ${SEND_EMAIL} ${RUN_DIR}
  It sends to ${EMAIL_TO} from the agents' mail account. Never send it any other
  way or to anyone else.
- Mail to Titus is reviewed before it leaves. If that command prints
  "agent-mail: NOT SENT" (exit 3), nothing was sent: fix what it lists in
  email-draft.html (and email-subject.txt), then run the same command once more.
  That second send goes out whatever the review says. Never pass --no-review,
  and never run it a third time.
EOF
    else
        cat <<EOF
- Compose only; do not send the email yourself. The wrapper sends it to ${EMAIL_TO}.
EOF
    fi
    cat <<EOF

## Continuation facts (use these verbatim in "How to Continue This Research")

- Run host SSH alias: ${HOST_ALIAS}
  (If this is exactly \`local\`, the reader is already on the run machine: OMIT the
  ssh step and renumber. Otherwise the step is literally \`ssh ${HOST_ALIAS}\`.)
- Plugin directory on the run host: ${REPO_DIR}
- Run directory on the run host: ${RUN_DIR}
- Continue command: ${CONTINUE_COMMAND} ${RUN_DIR}
- Agent to start in the plugin directory: ${PROVIDER_BIN}

These are the real paths on the machine that produced this run. Use them exactly;
never substitute a placeholder, a guessed path, or a different hostname.

## Wrapper-verified outcome (authoritative; state it, never contradict it)

- Final outcome: ${FINAL_OUTCOME:-unknown}
- Workflow status: ${STATUS:-unknown}
- Published: $(if [ "${PUBLISH_STATE:-}" = "pushed" ]; then echo "yes, verified on GitHub (${PUBLISHED_VISIBILITY:-unknown visibility} repo): $(cat "${RUN_DIR}/.repo_url" 2>/dev/null)"; elif [ "${PUBLISH_STATE:-}" = "failed" ]; then echo "NO - ${PUBLISH_ERROR}. Say so near the top of the email and give no repo link."; else echo "no (publishing skipped for this run); give no repo link."; fi)
- Caveats:
${OUTCOME_REASONS:-  - none}

The full machine-readable outcome is in ${RUN_DIR}/run-outcome.json. If the
final outcome is anything other than \`complete\`, the email's first line must
say so plainly (e.g. "This run finished but its results are NOT on GitHub").
EOF
    render_command "${REPO_DIR}/commands/researcher-auto-email.md" "$RUN_DIR"
}

# invoke_claude BIN MODEL TOOLS [ARG...]: runs the Claude CLI BIN headless on the
# prompt on stdin, without permission prompts, with model MODEL, only the tools
# TOOLS (comma-separated), and any further ARGs.
invoke_claude() {
    local bin="$1" model="$2" tools="$3"
    shift 3
    "$bin" --print --dangerously-skip-permissions --model "$model" "$@" --allowedTools "$tools"
}

invoke_provider() {
    # One branch per backend in researcher_lib.py BACKENDS.
    case "$BACKEND" in
        claude)
            invoke_claude "$PROVIDER_BIN" "$MODEL" "Read,Write,Edit,Glob,Grep,Bash,WebSearch,WebFetch,Task"
            ;;
        codex)
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
                --model "$MODEL"
                -c "model_reasoning_effort=\"${CODEX_REASONING}\""
                -c "agents.default_subagent_model=\"${CODEX_DEEP_MODEL}\""
                -c "agents.default_subagent_reasoning_effort=\"${CODEX_DEEP_REASONING}\""
                -c "agents.max_concurrent_threads_per_session=${CODEX_MAX_SUBAGENTS}"
                # unattended: the startup update menu would wait for a keypress for ever
                -c "check_for_update_on_startup=false"
            )
            if is_true "$CODEX_IGNORE_USER_CONFIG"; then
                codex_args+=(--ignore-user-config)
            fi
            codex_args+=(-)
            "$PROVIDER_BIN" "${codex_args[@]}"
            ;;
    esac
}

run_step_provider() {
    local step="$1"
    build_step_prompt "$step" | invoke_provider
}

run_email_provider() {
    build_email_prompt compose | invoke_provider
}

run_email_claude() {
    # A Claude session with a known id writes and sends the email, so Titus's
    # reply resumes this session (the mailroom routes by session id).
    build_email_prompt send | invoke_claude "$EMAIL_CLAUDE_BIN" "$EMAIL_CLAUDE_MODEL" "Read,Write,Glob,Grep,Bash" \
        --session-id "$EMAIL_SESSION" \
        --name "$(case "${ISSUE_NUMBER:-none}" in none) echo researcher ;; *) echo "researcher #${ISSUE_NUMBER}" ;; esac)"
}

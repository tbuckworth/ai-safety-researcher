#!/usr/bin/env bash
# Send the results email of a finished run from what the run saved, through the
# runner's own path (scripts/runner/notify.sh send_email): written by the first
# login of the mailroom's order that can, else assembled with no model. It is
# for a run whose report did not go (state.md's `undelivered` names the email,
# and the runner's log says why); it runs no workflow step and no experiment.
#
#   send-run-report.sh RUN_DIR
#
# Reads, in RUN_DIR: run-config.json, the settings the run saved (its backend
# and models, the email model, the limits), restored as a resume restores them
# (restore_run_settings: a setting the environment sets to another value exits
# 2 without RESEARCHER_ALLOW_CONFIG_CHANGE); state.md (the issue and knowledge
# base); and run-outcome.json (the outcome the runner recorded). The email's
# continuation steps name RESEARCHER_RUNNER_DIR, the
# checkout that runs autonomous runs, and its writers run there, so that a
# reply resumes the session there; the prompts and helpers are this checkout's.
# A run whose report already went or is held by the pre-send review
# (.email-sent or .email-held) is refused. Exit 0: the report went (or the
# review holds it, to go after the mailroom's fallback wait); 1: the report did
# not go (why is above: nothing was sent, or only a plain-text notice, as when
# the runner counts the email undelivered), or it already went; 2: a setting or
# the run directory is invalid.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB="${SCRIPT_DIR}/researcher_lib.py"

# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
add_local_bin_to_path
load_config || exit 2
require_config RESEARCHER_TASKS_REPO RESEARCHER_CLAUDE_BIN RESEARCHER_CODEX_BIN RESEARCHER_CLAUDE_MODEL \
    RESEARCHER_CODEX_MODEL RESEARCHER_CODEX_REASONING RESEARCHER_CODEX_FAST_MODEL RESEARCHER_CODEX_FAST_REASONING \
    RESEARCHER_CODEX_SANDBOX RESEARCHER_CODEX_APPROVAL_POLICY RESEARCHER_CODEX_IGNORE_USER_CONFIG \
    RESEARCHER_CODEX_MAX_SUBAGENTS RESEARCHER_CODE_SEARCH_DIR RESEARCHER_MAX_EXPERIMENTS \
    RESEARCHER_EXPERIMENT_MINUTES RESEARCHER_MAX_FILE_MB RESEARCHER_MAX_AUDIT_ROUNDS RESEARCHER_RUNNER_DIR || exit 2

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: send-run-report.sh RUN_DIR (a run directory)" >&2
    exit 2
fi
RUN_DIR="$(cd "$1" && pwd)"
for f in state.md run-outcome.json; do
    if [ ! -s "${RUN_DIR}/${f}" ]; then
        echo "ERROR: ${RUN_DIR}/${f} is missing or empty: this is not a finished run." >&2
        exit 2
    fi
done
for f in .email-sent .email-held; do
    if [ -s "${RUN_DIR}/${f}" ]; then
        echo "ERROR: the report of ${RUN_DIR} already went or is held (${f}: $(cut -f2 "${RUN_DIR}/${f}")); nothing was sent." >&2
        exit 1
    fi
done

# shellcheck source=runner/common.sh
source "${SCRIPT_DIR}/runner/common.sh"
# shellcheck source=runner/state.sh
source "${SCRIPT_DIR}/runner/state.sh"
# shellcheck source=runner/settings.sh
source "${SCRIPT_DIR}/runner/settings.sh"
# shellcheck source=runner/provider.sh
source "${SCRIPT_DIR}/runner/provider.sh"
# shellcheck source=runner/notify.sh
source "${SCRIPT_DIR}/runner/notify.sh"

# The settings the run was made with, as a resume restores them. This script
# records no launch, so it has no owner and its accepted changes are not kept.
mapfile -t RUN_SETTINGS < <(python3 "$LIB" run-settings)
RUN_OWNER=""
ALLOW_CONFIG_CHANGE="${RESEARCHER_ALLOW_CONFIG_CHANGE:-false}"
ALLOW_BACKEND_SWITCH="${RESEARCHER_ALLOW_BACKEND_SWITCH:-false}"
restore_run_settings "$RUN_DIR"
select_backend
runtime_limits
email_settings
HOST_ALIAS=$(resolve_host_alias) || exit 2
CONTINUE_DIR="$RESEARCHER_RUNNER_DIR"
if [ ! -d "$CONTINUE_DIR" ]; then
    echo "ERROR: RESEARCHER_RUNNER_DIR (${CONTINUE_DIR}) is not a directory." >&2
    exit 2
fi

RUN_ID=$(basename "$RUN_DIR")
OUTPUT_DIR=$(dirname "$RUN_DIR")
LOG_DIR="${RESEARCHER_LOG_DIR:-${OUTPUT_DIR}/logs}"
mkdir -p "$LOG_DIR"
TASKS_REPO="$RESEARCHER_TASKS_REPO"
ISSUE_NUMBER=$(state_field "${RUN_DIR}/state.md" issue_number)
[ "$ISSUE_NUMBER" = "none" ] && ISSUE_NUMBER=""
KB_DIR=$(state_field "${RUN_DIR}/state.md" knowledge_base)
[ "$KB_DIR" = "none" ] && KB_DIR=""
CODE_SEARCH_DIR="$RESEARCHER_CODE_SEARCH_DIR"

# The outcome the runner recorded. The run does not keep the visibility it read
# back from GitHub, so the writer is told it is unknown.
OUTCOME_FILE="${RUN_DIR}/run-outcome.json"
if ! FINAL_OUTCOME=$(jq -er '.outcome' "$OUTCOME_FILE") || ! STATUS=$(jq -er '.status' "$OUTCOME_FILE") \
        || ! PUBLISH_STATE=$(jq -er '.publish_state' "$OUTCOME_FILE"); then
    echo "ERROR: ${OUTCOME_FILE} has no outcome, status or publish_state (jq's error is above)." >&2
    exit 2
fi
PUBLISH_ERROR=$(jq -r '[.reasons[]? | select(startswith("not on GitHub: ")) | ltrimstr("not on GitHub: ")] | first // ""' \
    "$OUTCOME_FILE")
PUBLISHED_VISIBILITY=""
OUTCOME_REASONS=$(jq -r '.reasons[]?' "$OUTCOME_FILE" | sed 's/^/  - /')

log "Sending the results email of ${RUN_DIR} (outcome ${FINAL_OUTCOME}, backend ${BACKEND} ${MODEL})."
send_email || exit 1
if [ "$EMAIL_WRITER" = notice ]; then
    log "ERROR: the report itself did not go, only the plain-text notice (why is above)."
    exit 1
fi

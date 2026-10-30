#!/usr/bin/env bash
# create-followup-issue.sh — Create a follow-up research issue on GitHub
#
# Usage:
#   create-followup-issue.sh --parent <issue#> --repo-url <url> --run-id <id> --feedback-file <path> [--source <backend>] [--force]
#
# Creates an issue on tbuckworth/tasks with labels:
# list:research-ideas, type:follow-up, source:<backend>, importance:<parent's>
# researcher_lib.py's followup-issue writes the title and body (the feedback,
# then a footer line with the metadata) and gives the follow-up label, its
# FOLLOWUP_LABEL; the runner reads them back with its followup-meta.
#
# The follow-up takes its parent's importance label, or importance:medium when
# the parent has none (or cannot be read). agent-spare only starts ideas rated
# high or medium, so a follow-up filed without one was never run on its own.
#
# Idempotent: the body carries a follow-up key (a hash of the request). If an
# issue with the same key already exists, open or closed, it is reported and
# nothing is created. Running this twice (an agent retrying after a slow or
# failed read-back) used to file the same request twice: tasks#1919/#1920,
# which were then run as two separate experiments. --force files it anyway.

set -euo pipefail

PARENT=""
REPO_URL=""
RUN_ID=""
FEEDBACK_FILE=""
SOURCE_AGENT="${RESEARCHER_BACKEND:-claude}"
FORCE=false
TASKS_REPO="${RESEARCHER_TASKS_REPO:-tbuckworth/tasks}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/researcher_lib.py"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent) PARENT="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --feedback-file) FEEDBACK_FILE="$2"; shift 2 ;;
        --source) SOURCE_AGENT="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

BACKENDS=$(python3 "$LIB" backends)
case " ${BACKENDS} " in
    *" ${SOURCE_AGENT} "*) ;;
    *)
        echo "ERROR: --source must be one of: ${BACKENDS}" >&2
        exit 1
        ;;
esac

if [ -z "$FEEDBACK_FILE" ] || [ ! -f "$FEEDBACK_FILE" ]; then
    echo "ERROR: --feedback-file is required and must exist" >&2
    exit 1
fi

if [ -z "$(cat "$FEEDBACK_FILE")" ]; then
    echo "ERROR: Feedback file is empty" >&2
    exit 1
fi

ISSUE=$(python3 "$LIB" followup-issue --feedback-file "$FEEDBACK_FILE" \
    --parent "$PARENT" --repo-url "$REPO_URL" --run-id "$RUN_ID")
TITLE=$(jq -r '.title' <<< "$ISSUE")
BODY=$(jq -r '.body' <<< "$ISSUE")
KEY=$(jq -r '.key' <<< "$ISSUE")
FOLLOWUP_LABEL=$(jq -r '.label' <<< "$ISSUE")
if [ "$FORCE" != true ]; then
    # Fail closed: if the duplicate check cannot run, do not risk a duplicate.
    LIST_LIMIT=1000
    if ! EXISTING_ISSUES=$(gh issue list --repo "$TASKS_REPO" \
            --label "$FOLLOWUP_LABEL" --state all --limit "$LIST_LIMIT" \
            --json number,url,body); then
        echo "ERROR: could not list existing follow-up issues to check for a duplicate" >&2
        exit 1
    fi
    # Assigned first so a parse failure aborts (set -e) instead of skipping the guard.
    EXISTING_COUNT=$(printf '%s' "$EXISTING_ISSUES" \
        | python3 -c 'import json, sys; print(len(json.loads(sys.stdin.read().strip() or "[]")))')
    if [ "$EXISTING_COUNT" -ge "$LIST_LIMIT" ]; then
        # A full window may hide an older duplicate; the check would pass silently.
        echo "ERROR: ${LIST_LIMIT}+ follow-up issues; the duplicate check cannot see them all. Raise LIST_LIMIT or use --force." >&2
        exit 1
    fi
    EXISTING=$(printf '%s' "$EXISTING_ISSUES" | python3 "$LIB" find-followup --key "$KEY")
    if [ -n "$EXISTING" ]; then
        EXISTING_NUMBER=${EXISTING%% *}
        EXISTING_URL=${EXISTING#* }
        echo "Follow-up already exists (same request): ${EXISTING_URL}"
        echo "$EXISTING_NUMBER"
        exit 0
    fi
fi

IMPORTANCE="importance:medium"
if [ -n "$PARENT" ] && [ "$PARENT" != "none" ]; then
    PARENT_IMPORTANCE=$(gh issue view "$PARENT" --repo "$TASKS_REPO" --json labels \
        --jq '[.labels[].name | select(startswith("importance:"))][0] // ""' 2>/dev/null) \
        || PARENT_IMPORTANCE=""
    case "$PARENT_IMPORTANCE" in
        importance:high|importance:medium|importance:low) IMPORTANCE="$PARENT_IMPORTANCE" ;;
    esac
fi

# Ensure labels exist
gh label create "$FOLLOWUP_LABEL" \
    --repo "$TASKS_REPO" \
    --color "1D76DB" \
    --description "Follow-up to a previous research run" \
    2>/dev/null || true

# Create the issue
ISSUE_URL=$(gh issue create --repo "$TASKS_REPO" \
    --title "$TITLE" \
    --label "list:research-ideas" \
    --label "$FOLLOWUP_LABEL" \
    --label "source:${SOURCE_AGENT}" \
    --label "$IMPORTANCE" \
    --body "$BODY")

ISSUE_NUMBER=$(echo "$ISSUE_URL" | sed 's/.*\///')

# Comment on the parent issue linking to the follow-up
if [ -n "$PARENT" ] && [ "$PARENT" != "none" ]; then
    gh issue comment "$PARENT" --repo "$TASKS_REPO" \
        --body "Follow-up created: #${ISSUE_NUMBER}" 2>/dev/null || true
fi

# Validate: read back the issue to confirm
CREATED=$(gh issue view "$ISSUE_NUMBER" --repo "$TASKS_REPO" --json number --jq '.number')
if [ "$CREATED" != "$ISSUE_NUMBER" ]; then
    echo "ERROR: Issue validation failed" >&2
    exit 1
fi

echo "Created follow-up issue: ${ISSUE_URL}"
echo "$ISSUE_NUMBER"

#!/usr/bin/env bash
# create-followup-issue.sh — Create a follow-up research issue on GitHub
#
# Usage:
#   create-followup-issue.sh --parent <issue#> --repo-url <url> --run-id <id> --feedback-file <path> [--source claude|codex] [--force]
#
# Creates an issue on tbuckworth/tasks with labels:
# list:research-ideas, type:follow-up, source:<backend>
# Metadata is stored in a single footer line (not YAML) for easy parsing.
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

case "$SOURCE_AGENT" in
    claude|codex) ;;
    *)
        echo "ERROR: --source must be 'claude' or 'codex'" >&2
        exit 1
        ;;
esac

if [ -z "$FEEDBACK_FILE" ] || [ ! -f "$FEEDBACK_FILE" ]; then
    echo "ERROR: --feedback-file is required and must exist" >&2
    exit 1
fi

FEEDBACK=$(cat "$FEEDBACK_FILE")
if [ -z "$FEEDBACK" ]; then
    echo "ERROR: Feedback file is empty" >&2
    exit 1
fi

# Title: first line of feedback, truncated to 70 chars
TITLE_LINE=$(head -1 "$FEEDBACK_FILE" | head -c 70)
TITLE="[Follow-up] ${TITLE_LINE}"

# Build body: feedback text + metadata footer
BODY="${FEEDBACK}"
if [ -n "$PARENT" ] || [ -n "$REPO_URL" ] || [ -n "$RUN_ID" ]; then
    BODY="${BODY}

---
Parent: #${PARENT} | Repo: ${REPO_URL} | Run: ${RUN_ID}"
fi

KEY=$(printf '%s' "$BODY" | python3 "$LIB" followup-key)
if [ "$FORCE" != true ]; then
    # Fail closed: if the duplicate check cannot run, do not risk a duplicate.
    if ! EXISTING_ISSUES=$(gh issue list --repo "$TASKS_REPO" \
            --label "type:follow-up" --state all --limit 200 \
            --json number,url,body); then
        echo "ERROR: could not list existing follow-up issues to check for a duplicate" >&2
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
BODY="${BODY}
<!-- followup-key: ${KEY} -->"

# Ensure labels exist
gh label create "type:follow-up" \
    --repo "$TASKS_REPO" \
    --color "1D76DB" \
    --description "Follow-up to a previous research run" \
    2>/dev/null || true

# Create the issue
ISSUE_URL=$(gh issue create --repo "$TASKS_REPO" \
    --title "$TITLE" \
    --label "list:research-ideas" \
    --label "type:follow-up" \
    --label "source:${SOURCE_AGENT}" \
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

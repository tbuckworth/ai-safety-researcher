#!/usr/bin/env bash
# create-followup-issue.sh — Create a follow-up research issue on GitHub
#
# Usage:
#   create-followup-issue.sh --parent <issue#> --repo-url <url> --run-id <id> --feedback-file <path>
#
# Creates an issue on tbuckworth/tasks with labels: list:research-ideas, type:follow-up, source:claude
# Metadata is stored in a single footer line (not YAML) for easy parsing.

set -euo pipefail

PARENT=""
REPO_URL=""
RUN_ID=""
FEEDBACK_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parent) PARENT="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --feedback-file) FEEDBACK_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

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

# Ensure labels exist
gh label create "type:follow-up" \
    --repo tbuckworth/tasks \
    --color "1D76DB" \
    --description "Follow-up to a previous research run" \
    2>/dev/null || true

# Create the issue
ISSUE_URL=$(gh issue create --repo tbuckworth/tasks \
    --title "$TITLE" \
    --label "list:research-ideas" \
    --label "type:follow-up" \
    --label "source:claude" \
    --body "$BODY")

ISSUE_NUMBER=$(echo "$ISSUE_URL" | sed 's/.*\///')

# Comment on the parent issue linking to the follow-up
if [ -n "$PARENT" ] && [ "$PARENT" != "none" ]; then
    gh issue comment "$PARENT" --repo tbuckworth/tasks \
        --body "Follow-up created: #${ISSUE_NUMBER}" 2>/dev/null || true
fi

# Validate: read back the issue to confirm
CREATED=$(gh issue view "$ISSUE_NUMBER" --repo tbuckworth/tasks --json number --jq '.number')
if [ "$CREATED" != "$ISSUE_NUMBER" ]; then
    echo "ERROR: Issue validation failed" >&2
    exit 1
fi

echo "Created follow-up issue: ${ISSUE_URL}"
echo "$ISSUE_NUMBER"

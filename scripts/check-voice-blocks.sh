#!/usr/bin/env bash
# check-voice-blocks.sh — guard for the truth-seeking Voice block and parsed tokens.
#
# Checks:
#   1. The Voice block in every agent + the two orchestrator commands is
#      BYTE-IDENTICAL to the canonical copy in docs/STANCE.md. Presence alone
#      is not enough — duplicated copies drift, so we diff each one.
#   2. KEEP-tokens (parsed/matched elsewhere) are still present where they live.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANCE="${REPO_ROOT}/docs/STANCE.md"
BEGIN='<!-- VOICE:BEGIN -->'
END='<!-- VOICE:END -->'

fail=0

# Extract the inclusive block between (and including) the markers from a file.
extract_block() {
  awk -v b="$BEGIN" -v e="$END" '
    $0 ~ b {inblk=1}
    inblk {print}
    $0 ~ e {inblk=0}
  ' "$1"
}

[ -f "$STANCE" ] || { echo "FATAL: missing $STANCE"; exit 2; }
CANON="$(extract_block "$STANCE")"
[ -n "$CANON" ] || { echo "FATAL: no Voice block found in $STANCE"; exit 2; }

# Files that MUST carry a byte-identical Voice block.
FILES=(
  "${REPO_ROOT}"/agents/*.md
  "${REPO_ROOT}/commands/researcher.md"
  "${REPO_ROOT}/commands/researcher-auto-step.md"
)

echo "== Voice block byte-identity =="
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "MISS  $(basename "$f") (file not found)"; fail=1; continue; }
  blk="$(extract_block "$f")"
  if [ -z "$blk" ]; then
    echo "MISS  ${f#$REPO_ROOT/} (no Voice block)"; fail=1
  elif [ "$blk" = "$CANON" ]; then
    echo "ok    ${f#$REPO_ROOT/}"
  else
    echo "DRIFT ${f#$REPO_ROOT/} (Voice block differs from docs/STANCE.md)"; fail=1
  fi
done

# KEEP-token presence: file -> token that must still be there.
echo "== KEEP-token presence =="
check_token() { # $1 file (rel)  $2 grep-pattern  $3 label
  local f="${REPO_ROOT}/$1"
  if [ -f "$f" ] && grep -qF -- "$2" "$f"; then
    echo "ok    $1 contains '$3'"
  else
    echo "GONE  $1 missing '$3'"; fail=1
  fi
}
check_token "agents/experiment.md"     "PASS | FAIL"        "PASS | FAIL verdict template"
check_token "agents/decomposition.md"  "[SHOWSTOPPER]"      "[SHOWSTOPPER]"
check_token "agents/decomposition.md"  "P_success"         "P_success"
check_token "agents/mentor-review.md"  "RETHINK_APPROACH"  "RETHINK_APPROACH"
check_token "agents/novelty-analyst.md" "ALREADY_DONE"     "ALREADY_DONE"
check_token "agents/results-auditor.md" "FIXABLE-DEFECT"   "audit verdict enum"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: voice/token guard found problems."
  exit 1
fi
echo "PASSED: voice blocks identical, KEEP-tokens present."

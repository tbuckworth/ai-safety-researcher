#!/usr/bin/env bash
# kb-init.sh — Bootstrap the global research knowledge base (wiki).
#
# Usage:
#   kb-init.sh [path]            # default: $RESEARCHER_KB_DIR, else ~/pyg/research-wiki
#
# Idempotent: safe to re-run. Existing files are never overwritten, except
# KB-SCHEMA.md, which is refreshed from the plugin template only when --update-schema
# is passed (the schema is expected to be edited in place as the wiki evolves).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

UPDATE_SCHEMA=false
KB_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update-schema) UPDATE_SCHEMA=true; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) KB_DIR="$1"; shift ;;
    esac
done

KB_DIR="${KB_DIR:-${RESEARCHER_KB_DIR:-${HOME}/pyg/research-wiki}}"
SCHEMA_TEMPLATE="${PLUGIN_DIR}/templates/kb-schema.md"

if [ ! -f "$SCHEMA_TEMPLATE" ]; then
    echo "ERROR: schema template missing at ${SCHEMA_TEMPLATE}" >&2
    exit 1
fi

mkdir -p "$KB_DIR"/{raw,sources,entities,concepts,lessons,threads}

if [ ! -f "${KB_DIR}/KB-SCHEMA.md" ] || [ "$UPDATE_SCHEMA" = true ]; then
    cp "$SCHEMA_TEMPLATE" "${KB_DIR}/KB-SCHEMA.md"
    echo "Wrote ${KB_DIR}/KB-SCHEMA.md"
fi

# Claude Code and Codex both read an instructions file from the wiki root; point
# both at the schema so any agent opened in the wiki is a wiki maintainer.
for instructions in AGENTS.md CLAUDE.md; do
    if [ ! -f "${KB_DIR}/${instructions}" ]; then
        cat > "${KB_DIR}/${instructions}" <<'INSTREOF'
# Research Wiki

Read `KB-SCHEMA.md` completely before reading, writing, or maintaining any page
in this repository. It defines the layout, page conventions, and the ingest /
query / lint workflows, and it overrides default behaviour.

`raw/` is immutable. Everything else is agent-maintained.
INSTREOF
        echo "Wrote ${KB_DIR}/${instructions}"
    fi
done

if [ ! -f "${KB_DIR}/index.md" ]; then
    cat > "${KB_DIR}/index.md" <<'INDEXEOF'
# Index

Catalog of every page in this wiki. Read this first when answering a question,
then drill into the pages it points at. Updated on every ingest.

## Threads

<!-- One line per research line: [[thread]] — one-sentence description -->

## Concepts

<!-- One line per concept page: [[page]] — one-sentence description -->

## Entities

<!-- One line per entity page: [[page]] — one-sentence description -->

## Lessons

- [[common-failures]] — failure modes that have actually bitten a run
- [[experiment-design]] — construct validity, controls, criteria drift
- [[compute]] — what each compute profile can really do, and what it costs
- [[tooling]] — library, API, and environment traps

## Sources

<!-- One line per source page: [[page]] — author/venue/year, one-line claim -->
INDEXEOF
    echo "Wrote ${KB_DIR}/index.md"
fi

if [ ! -f "${KB_DIR}/log.md" ]; then
    cat > "${KB_DIR}/log.md" <<LOGEOF
# Log

Append-only. Every entry starts with \`## [YYYY-MM-DD] <op> | <subject>\` so the
log stays greppable: \`grep "^## \\[" log.md | tail -5\`.

## [$(date +%Y-%m-%d)] init | knowledge base created
Bootstrapped by kb-init.sh.
LOGEOF
    echo "Wrote ${KB_DIR}/log.md"
fi

# Seed the lessons pages — these are the ones the workflow reads before designing
# experiments, so they must exist (empty is fine) rather than 404 at Step 5.
seed_lesson() {
    local slug="$1" title="$2" blurb="$3"
    local path="${KB_DIR}/lessons/${slug}.md"
    [ -f "$path" ] && return 0
    cat > "$path" <<LESSONEOF
---
type: lesson
title: ${title}
updated: $(date +%Y-%m-%d)
sources: []
tags: [lessons]
---

# ${title}

${blurb}

<!-- One section per lesson. Each: the symptom, the root cause, the check that
     would have caught it early, and the run(s) it came from. A lesson with no
     run behind it is a guess — say so. -->
LESSONEOF
    echo "Wrote ${path}"
}

seed_lesson common-failures "Common Failures" \
    "Failure modes that have actually bitten a research run. Read before Step 5 (decomposition) and Step 6 (challenge)."
seed_lesson experiment-design "Experiment Design Lessons" \
    "Constructs that turned out to be strawmen, controls that proved load-bearing, and criteria that drifted between design and write-up."
seed_lesson compute "Compute Lessons" \
    "What each compute profile can really do, what jobs actually cost in wall-clock and money, and where runs have hit ceilings."
seed_lesson tooling "Tooling Lessons" \
    "Library and API traps, version pins that matter, and environment gotchas that cost a run time."

if [ ! -d "${KB_DIR}/.git" ]; then
    git -C "$KB_DIR" init -q
    cat > "${KB_DIR}/.gitignore" <<'GIEOF'
.DS_Store
.obsidian/workspace*
*.tmp
*.bak
GIEOF
    git -C "$KB_DIR" add -A
    git -C "$KB_DIR" commit -qm "Bootstrap research knowledge base" || true
    echo "Initialised git repository in ${KB_DIR}"
fi

echo
echo "Knowledge base ready at: ${KB_DIR}"
echo "Point runs at it with: export RESEARCHER_KB_DIR=${KB_DIR}"

# Knowledge Bases

How research compounds across runs instead of restarting.

## The problem

Every run used to begin from zero. It searched the literature from scratch, even
where a previous run had already surveyed the same corner. It assessed novelty
against that one search, not against what this researcher had already
established. And when a run lost six hours to a CUDA driver mismatch, or
discovered at Step 6 that its construct was a strawman, that knowledge died with
the run directory. The next run was free to repeat it.

The pattern here is [Karpathy's LLM-wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f):
rather than re-retrieving from raw documents at query time, an agent
**incrementally builds and maintains a persistent wiki** that sits between you
and the sources. Knowledge is compiled once and then kept current. The wiki is a
compounding artifact; the cross-references are already there, the contradictions
are already flagged.

## Two knowledge bases

**Global wiki** — one per researcher, spanning every research line. Literature,
entities, concepts, and `lessons/`: what the research *process* has learned.
Lives outside this plugin, because it is your knowledge and it outlives the tool.

**Per-repo knowledge base** — `knowledge/` inside each research run directory,
published with that line's GitHub repo. Scoped to one line of work, so a
follow-up run months later can resume without re-deriving anything.

They answer different questions. The global wiki answers *"what do we already
know about this area, and what has gone wrong before?"* The per-repo KB answers
*"what did this specific line establish, what did it rule out, and how do I
re-run it?"*

## Setup

```bash
scripts/kb-init.sh                    # → ~/pyg/research-wiki
scripts/kb-init.sh /path/to/wiki      # or anywhere
export RESEARCHER_KB_DIR=~/pyg/research-wiki
```

Idempotent — safe to re-run. It creates the directory layout, a git repo,
`index.md`, `log.md`, seeded `lessons/` pages, and `KB-SCHEMA.md` (the schema
that makes an agent a disciplined wiki maintainer rather than a chatbot). It also
writes `AGENTS.md` and `CLAUDE.md` in the wiki root pointing at the schema, so
any agent opened in the wiki behaves as its maintainer.

`RESEARCHER_KB_DIR=none` disables the knowledge base for a run. So does pointing
at a path with no `KB-SCHEMA.md` — a run never writes pages into an unstructured
directory it happens to have been handed.

**The knowledge base is an accelerant, never a dependency.** A run with no KB
executes identically. Every KB action in the workflow is skipped silently when
there is no KB, and a KB action that errors is logged and stepped past. A stale
wiki costs some duplicated search; a workflow that halts because a wiki is
missing costs the whole run.

## Global wiki layout

```
KB-SCHEMA.md      the schema — read first by any agent touching the wiki
index.md          catalog of every page; read first when answering
log.md            append-only chronology of ingests, queries, lints
raw/              original source documents (immutable)
sources/          one page per ingested source
entities/         people, labs, models, datasets, benchmarks, tools
concepts/         methods, phenomena, threat models, open problems
lessons/          cross-run methodology knowledge
threads/          one page per research line, linking its runs
```

`lessons/` is what makes this more than a bibliography, and it is read *before*
experiments are designed, not after:

| File | Holds |
|------|-------|
| `common-failures.md` | Failure modes that have actually bitten a run — symptom, root cause, and the check that catches it early |
| `experiment-design.md` | Strawman constructs, controls that proved load-bearing, criteria that drifted |
| `compute.md` | What each compute profile really delivers, real wall-clock and cost, ceilings hit |
| `tooling.md` | Library/API traps, version pins that matter, environment gotchas |

## Per-repo layout

```
knowledge/
  README.md          what this is and how to use it
  findings.md        what this line established, each with its confidence
  dead-ends.md       what was ruled out, and the evidence that ruled it out
  methods.md         how to reproduce: data, harness, commands, gotchas
  open-questions.md  what remains genuinely unresolved
```

`dead-ends.md` is the highest-value file. It is what stops the next run
re-proposing something this line already killed, so each entry carries the
evidence, not just the verdict.

On a follow-up run the prior repo KB is cloned into `prior/knowledge/` and
**carried forward and extended** — never restarted, and a prior finding is not
dropped just because this round didn't touch it.

## Where the workflow touches them

All KB work goes through the `researcher:knowledge` leaf agent
(`agents/knowledge.md`), at these points and no others:

| Step | Operation | Scope | Purpose |
|------|-----------|-------|---------|
| 2, before searching | query | global | Aim searches at gaps → `literature/kb-prior.md` |
| 2, after synthesis | ingest | global | File the new sources |
| 3 | query | global | Novelty against accumulated knowledge — prior runs count against novelty exactly as published work does |
| 6 | query | global | Read `lessons/` before committing to a design → `challenge/kb-lessons.md` |
| 11 | ingest | both | File the outcome, the process lessons, and the repo KB |

The Step 6 query is the one that changes behaviour most: it hands the three
challenge agents failure modes that have *actually occurred*, so a pre-mortem
argues from evidence rather than imagination.

The Step 11 ingest is the one that compounds. It files the result — including a
negative or null result, which nothing else in the system remembers — and it
mines the audit, the `next-steps.md` reflection, and the run logs for what the
process learned.

## Operations

Defined in full in `templates/kb-schema.md`, which is copied into the wiki root
at bootstrap and is expected to be edited in place as the wiki matures.

**Ingest** — read the source fully, write its `sources/` page, update every
entity and concept page it touches. A substantial source that moves one page was
ingested shallowly. Contradictions are recorded with attribution, never resolved
by overwriting.

**Query** — read `index.md`, drill into what it points at, answer with `[[page]]`
citations. Separate *already known*, *contested*, and *not covered* — the caller
acts differently on each. Never improvise coverage: a confident answer from an
empty wiki is the failure mode that makes the whole thing untrustworthy.

**Lint** — unflagged contradictions, superseded sources, orphan pages, `[[links]]`
to pages never written, index and frontmatter drift. Run it periodically:

```
/researcher-continue          # or ask any agent in the wiki directory
"lint the knowledge base"
```

## Reading it

It is a directory of markdown with `[[wikilinks]]` and YAML frontmatter, in a git
repo. Obsidian works on it directly — graph view is the fastest way to see the
shape of what you know, and which pages are hubs or orphans. So does `grep`:

```bash
grep "^## \[" log.md | tail -5      # last five things that happened
```

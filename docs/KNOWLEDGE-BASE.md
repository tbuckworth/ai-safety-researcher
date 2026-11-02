# Knowledge Bases

A knowledge base (KB) here is a directory of Markdown pages that agents
maintain, so that what one research run learns is available to later runs. The
workflow uses two, both optional.

## Why

Without a knowledge base, each run starts from zero. It searches the literature
from scratch, even where an earlier run surveyed the same area; it judges
novelty against that one search, not against what earlier runs established; and
what it learns about the process (a day lost to a CUDA driver mismatch, a
construct found at Step 6 to be a strawman) stays in its run directory, where
the next run does not look.

The global wiki follows [Karpathy's LLM-wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
pattern: instead of retrieving from raw documents at query time, an agent
builds and maintains a persistent wiki between the reader and the sources. Each
source is compiled into the wiki once, and the cross-references and recorded
contradictions are kept current.

## Two knowledge bases

**Global wiki**: one per researcher, spanning every research line. It holds
literature, entities, concepts, and `lessons/`, what the research process has
learned. It lives outside this plugin, because it outlasts any one tool.

**Per-repo knowledge base**: `knowledge/` in each research run directory,
published with that line's GitHub repo, so that a follow-up run months later
can resume without re-deriving anything.

The global wiki answers "what do we already know about this area, and what has
gone wrong before?" The per-repo KB answers "what did this line establish, what
did it rule out, and how is it re-run?"

## Setup

```bash
scripts/kb-init.sh                    # → RESEARCHER_DEFAULT_KB_DIR (config/researcher.env)
scripts/kb-init.sh /path/to/wiki      # or anywhere
export RESEARCHER_KB_DIR=/path/to/wiki  # for a wiki anywhere else
```

`kb-init.sh` creates the directory layout, a git repository, `index.md`,
`log.md`, the seeded `lessons/` pages, and `KB-SCHEMA.md`, a copy of
[`templates/kb-schema.md`](../templates/kb-schema.md). The schema defines the
wiki's layout, its page conventions and its ingest, query and lint operations,
and every agent working in the wiki follows it. `kb-init.sh` also writes
`AGENTS.md` and `CLAUDE.md` in the wiki root, pointing any agent opened there at
the schema. Re-running it adds what is missing and overwrites nothing.
`scripts/kb-init.sh --update-schema` also replaces the wiki's `KB-SCHEMA.md`
with the template, discarding any edits made to it in the wiki.

`RESEARCHER_KB_DIR=none` disables the KB for a run. A path with no
`KB-SCHEMA.md` is never written to: an interactive run treats it as no KB, and
an autonomous run exits 2.

A run with no KB executes identically. Every KB action in the workflow is
skipped silently when there is no KB, and a KB action that fails is recorded in
`state.md`, reported in the results email, and stepped past. A missing or
failing KB therefore costs at most some repeated searching, never the run.

## Global wiki

`KB-SCHEMA.md` gives the wiki's layout and operations. Its `lessons/` pages
(common failures, experiment design, compute, tooling) hold what the research
process has learned, and the workflow reads them before an experiment design is
committed, at Step 6.

## Per-repo layout

```
knowledge/
  README.md          what this is and how to use it
  findings.md        what this line established, each with its confidence
  dead-ends.md       what was ruled out, and the evidence that ruled it out
  methods.md         how to reproduce: data, harness, commands, gotchas
  open-questions.md  what remains unresolved
```

`dead-ends.md` is the file that helps a follow-up most: it stops the next run
re-proposing what this line already ruled out, so each entry carries the
evidence as well as the verdict.

On a follow-up run the prior repo's KB is copied into `prior/knowledge/`, and the
run extends it rather than starting again; a prior finding stays even when this
round did not touch it.

## Where the workflow touches them

All KB work goes through the `researcher:knowledge` leaf agent
(`agents/knowledge.md`), at the points listed in the Knowledge Bases section of
[`WORKFLOW.md`](WORKFLOW.md#knowledge-bases).

The Step 6 query gives the three challenge agents failure modes that have
occurred in earlier runs, so that a pre-mortem can argue from them. The Step 11
ingest files the result, including a negative or null result, and takes what
the process learned from the audit, the `next-steps.md` reflection and the run
logs.

## Linting

Lint finds unflagged contradictions, superseded sources, orphan pages,
`[[links]]` to pages never written, and index and frontmatter drift
(`KB-SCHEMA.md`, Operation: Lint). Nothing in the workflow lints, so lint the
global wiki by hand: open Claude Code or Codex in the wiki directory and ask it
to lint the knowledge base, or dispatch the `researcher:knowledge` agent with
`Operation: lint`, `Scope: global` and the wiki's path.

## Reading it

It is a directory of Markdown with `[[wikilinks]]` and YAML frontmatter, in a git
repository. Obsidian opens it directly, and its graph view shows which pages are
hubs and which are orphans. `grep` works too:

```bash
grep "^## \[" log.md | tail -5      # last five things that happened
```

# Knowledge Bases

A knowledge base (KB) here is a directory of Markdown pages that agents
maintain, so that what one research run learns is available to later runs. The
workflow maintains research knowledge in a shared wiki and in each research line.
A private register of harness lessons also works when a run has no wiki.

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

When the wiki is disabled, the run still writes its own research knowledge and
records verified problems with the harness. The hub logs a failed wiki action
in `state.md` and reports it in the results email.

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

The hub dispatches wiki and per-repo KB work to the `researcher:knowledge` leaf agent
(`agents/knowledge.md`), at the points listed in the Knowledge Bases section of
[`WORKFLOW.md`](WORKFLOW.md#knowledge-bases).

The Step 6 query gives the three challenge agents failure modes that have
occurred in earlier runs, so that a pre-mortem can argue from them. The Step 11
ingest files the result, including a negative or null result, and takes what
the process learned from the audit, the `next-steps.md` reflection and the run
logs.

## Harness lessons

A harness lesson identifies something the research process missed, the evidence
that exposed it and a prospective check that could have caught it. File a
lesson as soon as the audit establishes it. A terminal run can also contribute
one from a verified execution or reporting failure. The same procedure applies
after an early stop and when the wiki is disabled.

**Record.** From the plugin root, pipe one JSON object per observation into
`python3 scripts/harness_lessons.py record RUN_DIR`. Use a stable
lowercase hyphenated key for the type of failure. Before filing, read the cited
artifact and compare it with the original plan. The locator identifies the
lines, table or log event that supplies the evidence. For example, a run with a
documented split problem might file the following record.

```json
{
  "key": "related-examples-across-splits",
  "failure": "Two paraphrases of the same question entered training and test.",
  "why_missed": "The split check compared row IDs, while paraphrases had distinct row IDs.",
  "evidence": "audit/results-audit.md",
  "locator": "Finding 2, overlapping question families",
  "check": "Split by source question and verify disjoint source IDs before training."
}
```

The command records the evidence fingerprint and writes into
`RUN_DIR/.harness/`. Identical observations produce one record. Keep
provider conversations and unpublished results private. A report or PR can
describe the general check using a synthetic example. Cite an external case
publicly only with permission.

**Use before design.** Run `python3 scripts/harness_lessons.py checks RUN_DIR`.
This searches sibling runs in the same output archive. It returns candidate
checks, accepted checks, and integrated checks with their dispositions. Apply
relevant checks to the concrete methods. Candidate checks require independent
justification. The private `pending_pr` list gives maintainers the accepted
code or prompt changes and their regression criteria.

**Review weekly.** The first run of each ISO week (UTC) invokes
`python3 scripts/harness_lessons.py weekly RUN_DIR`. When `review` is a path,
give the packet to the knowledge agent for `review-harness`. The packet groups
observations by failure key and retains every cited run, previous decision and
piece of new evidence. The reviewer checks the cited artifacts against their
recorded fingerprints, reconciles conflicting cases, and compares the proposed
check with what the current plugin already does. Accept a specific change,
defer with a reason and a condition for reconsideration, or reject a mistaken
or already-covered proposal. An accepted change names the behavior to implement
and a regression that distinguishes the new behavior from the old.

Pipe one JSON object into `python3 scripts/harness_lessons.py decide RUN_DIR`,
using the packet's filename and one decision for every key. For example:

```json
{
  "packet": "<weekly packet filename>",
  "decisions": {
    "related-examples-across-splits": {
      "status": "accepted",
      "reason": "The existing fixture would pass on the overlapping question families.",
      "check": "Keep related observations in one split and test overlap by family.",
      "change": "Add a family-overlap check to the split preflight.",
      "regression": "Two unique row IDs with the same family in train and test fail the check."
    }
  }
}
```

A rejected or deferred entry needs `status` and `reason`. New observations
reopen a previously decided class. Deferred entries return at the next weekly
review. A run that cannot complete the review calls
`python3 scripts/harness_lessons.py release RUN_DIR` and logs the reason. The
next run retries the packet. A claim also expires after one hour. A locked
ledger under `<output-archive>/.harness-reviews/` retains the full decision
history. A partial submission leaves every candidate pending.

**Integrate.** The plugin maintainer takes accepted work from `pending_pr`,
implements it in the plugin source, runs the recorded regression and submits
an ordinary checklist-reviewed PR. Keep private evidence in the local archive.
After merge, pipe an object with `key`, `pr` (full PR URL) and `validation`
(the regression run and its result) into
`python3 scripts/harness_lessons.py integrate RUN_DIR`. The command verifies
the merged PR with `gh`, then records the merge commit and validation. This
removes it from the implementation queue. Future plans can use the accepted
check while the implementation is pending. No scheduled service or wiki setup
is needed.

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

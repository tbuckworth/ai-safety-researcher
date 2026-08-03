# Knowledge Base Schema

This file is the configuration for this wiki. Any agent that reads, writes, or
maintains these pages reads this file first and follows it exactly. It is what
makes an agent a disciplined wiki maintainer rather than a generic chatbot.

The pattern is Karpathy's LLM-wiki: three layers (raw sources, the wiki, this
schema) and three operations (ingest, query, lint). The wiki is a **persistent,
compounding artifact** — knowledge is compiled once and then kept current, not
re-derived on every question.

## Ownership

- **You (the human)** own sourcing, direction, and the questions.
- **The agent** owns every file under `sources/`, `entities/`, `concepts/`,
  `lessons/`, `threads/`, plus `index.md` and `log.md`. It writes them; you read
  them.
- **`raw/` is immutable.** Agents read from it and never modify it. If a source
  needs correcting, the correction goes in the wiki page, noted as such.

## Layout

```
KB-SCHEMA.md      this file
index.md          catalog of every page — read this first when answering
log.md            append-only chronology of ingests, queries, and lints
raw/              original source documents (immutable)
sources/          one page per ingested source
entities/         people, labs, models, datasets, benchmarks, tools
concepts/         methods, phenomena, threat models, open problems
lessons/          cross-run methodology knowledge (see below)
threads/          one page per research line, linking its runs
```

`lessons/` is the part that makes this more than a literature wiki. It is what
the research process itself has learned, and it is read *before* designing
experiments, not after:

- `lessons/common-failures.md` — failure modes that have actually bitten a run,
  with the symptom, the root cause, and the check that would have caught it early
- `lessons/experiment-design.md` — constructs that turned out to be strawmen,
  controls that proved load-bearing, criteria that drifted
- `lessons/compute.md` — what a given compute profile can really do, what things
  actually cost in wall-clock and money, where runs hit ceilings
- `lessons/tooling.md` — library/API traps, version pins, environment gotchas

## Page conventions

Every page starts with YAML frontmatter:

```yaml
---
type: source | entity | concept | lesson | thread
title: <human-readable title>
updated: <YYYY-MM-DD>
sources: [<source-page-slug>, ...]   # which sources back this page
tags: [<tag>, ...]
---
```

- Filenames are `kebab-case.md`. One subject per page.
- Link between pages with `[[page-slug]]`. **Link liberally** — a `[[link]]` to a
  page that doesn't exist yet is not an error, it is a marker for a page worth
  writing.
- **Every claim carries its source.** A sentence that isn't traceable to a
  `sources/` page or a named run is either marked `(inferred)` or doesn't belong.
- **Contradictions are recorded, not resolved by overwriting.** When a new source
  disagrees with an existing claim, keep both, attribute both, and say which is
  better supported and why. Silently overwriting is how a wiki starts lying.
- **Confidence is explicit** on any claim that isn't a direct quote from a
  source: `well-established`, `single-source`, `contested`, or `speculative`.
- Prose over bullet fragments. A page a human can read beats a page of stubs.

## Operation: Ingest

Given a new source (a paper, a post, a completed research run):

1. Read the source fully. Do not skim to a summary.
2. Write or update `sources/<slug>.md`: what it claims, what it actually shows,
   method, limitations, and how it relates to what the wiki already holds.
3. Update every entity and concept page the source touches — create the page if
   it doesn't exist. A single substantial source typically touches 5–15 pages;
   touching only one means the ingest was shallow.
4. Where the source contradicts, strengthens, or narrows an existing claim, say
   so explicitly on the affected page.
5. Update `index.md` with any new pages.
6. Append one entry to `log.md`.

When ingesting a **completed research run**, additionally: update or create the
`threads/<line>.md` page, and — this is the part that compounds — write what the
*process* learned into `lessons/`. A run that lost six hours to a CUDA driver
mismatch, or discovered its construct was a strawman at Step 6, has produced
knowledge worth more than its result.

## Operation: Query

1. Read `index.md` first, then drill into the pages it points at. At this scale
   the index replaces embedding-based retrieval.
2. Answer with citations to wiki pages (`[[page]]`) and through them to sources.
3. **File good answers back.** A synthesis, comparison, or connection produced in
   conversation is worth as much as an ingested source — write it into the wiki
   as its own page rather than letting it die in chat history.
4. If the wiki genuinely doesn't cover the question, say so plainly. Never
   improvise coverage; a confident answer from an empty wiki is the one failure
   mode that destroys trust in the whole thing.

## Operation: Lint

Periodically, health-check the wiki and fix what's fixable:

- Contradictions between pages that aren't flagged as contradictions
- Claims whose supporting source has been superseded
- Orphan pages nothing links to, and `[[links]]` to pages that were never written
- Index entries for deleted pages, and pages missing from the index
- Frontmatter that has drifted from this schema

Report what was fixed and what needs a human decision. Append to `log.md`.

## log.md format

Append-only. Every entry starts with the same prefix so the log stays greppable
(`grep "^## \[" log.md | tail -5`):

```
## [YYYY-MM-DD] ingest | <source or run title>
<one or two lines: what came in, which pages moved>

## [YYYY-MM-DD] query | <the question>
<one line: what was answered, any page filed back>

## [YYYY-MM-DD] lint | <n> issues
<one line per fix>
```

## Evolving this schema

This file is expected to change as the wiki grows and its domain sharpens. When
a convention here stops fitting the material, propose the change to the human
rather than quietly diverging from it — a schema the pages don't follow is worse
than no schema.

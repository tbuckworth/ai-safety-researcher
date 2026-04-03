# AI Safety Researcher

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that automates end-to-end AI safety research — from topic scoping through literature review, experiment execution, and LaTeX paper compilation.

It implements a **10-step research workflow** based on the [Steinhardt fail-fast methodology](https://cs.nyu.edu/~welleck/episode32.html): decompose the project into testable components, estimate each one's probability of success and time cost, then test the riskiest component first. If it fails, stop early rather than sinking time into doomed work.

## What It Does

Given a research topic, the agent:

1. **Clarifies scope** — asks 3-5 questions to pin down definitions, prior knowledge, and success criteria
2. **Searches the literature** — queries arXiv, Semantic Scholar, lab blogs (Anthropic, OpenAI, DeepMind), and community forums (LessWrong, Alignment Forum) in parallel
3. **Assesses novelty** — determines whether the idea has already been done, is partially novel, or is new
4. **Defines success criteria** — identifies SOTA baselines, benchmarks, and the minimum publishable contribution
5. **Decomposes into components** — Steinhardt decomposition with lambda ordering (highest-risk-per-hour components first)
6. **Challenges the plan** — three sequential adversarial reviews: assumption analysis, steelman critique, and pre-mortem failure scenarios
7. **Reports experiment plan** — presents the lambda-ordered experiment table for approval
8. **Confirms fail-fast agreement** — explicit agreement that the project stops or pivots if the riskiest experiment fails
9. **Runs experiments** — executes experiments in lambda order, stopping on failure if agreed
10. **Compiles a LaTeX paper** — produces a full paper with real BibTeX citations, including negative results

## Prerequisites

- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** — installed and authenticated
- **[gh CLI](https://cli.github.com/)** — authenticated (`gh auth login`), used for GitHub issue integration
- **Python 3** — for experiment execution
- **tectonic** or **pdflatex** — for LaTeX compilation (Ubuntu: `sudo snap install tectonic`)
- **jq** — for JSON parsing in the cron wrapper (Ubuntu: `sudo apt install jq`)

For autonomous mode only:
- **GPU** — NVIDIA GPU with CUDA drivers (tested on RTX 3090, 24GB VRAM)
- **Gmail MCP server** — configured with valid OAuth token for sending result emails

## Installation

1. Clone the repo:
   ```bash
   git clone https://github.com/tbuckworth/researcher.git
   cd researcher
   ```

2. Register the plugin with Claude Code. Add to your `~/.claude/settings.json`:
   ```json
   {
     "plugins": [
       "/path/to/researcher"
     ]
   }
   ```

3. That's it. The plugin provides slash commands, agents, and skills automatically.

## Usage

### Interactive Mode (human-in-the-loop)

```bash
claude
> /researcher Does gradient routing create isolated loss basins in fine-tuned models?
```

The orchestrator walks you through all 10 steps, asking for your input at each decision point (search plan approval, novelty verdict, criteria review, challenge synthesis, experiment plan, fail-fast agreement).

### Autonomous Mode (no human interaction)

Run a specific topic headlessly:
```bash
./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

Or let it pick from your GitHub Issues (label `list:research-ideas` on `tbuckworth/tasks`):
```bash
./scripts/researcher-cron.sh
```

Autonomous mode runs the same 10-step workflow but makes all decisions automatically using built-in heuristics (see `docs/AUTONOMOUS.md`). On completion it:
- Creates a public GitHub repo with all artifacts
- Sends an HTML email with results summary
- Updates the source GitHub issue

#### Cron setup (daily at 2am):
```bash
crontab -e
# Add:
0 2 * * * /path/to/researcher/scripts/researcher-cron.sh >> /path/to/researcher/logs/cron.log 2>&1
```

### Reviewing Results

After a run completes, interactively explore the results:
```bash
claude
> /researcher-review                    # most recent run
> /researcher-review /path/to/run-dir   # specific run
```

This loads the run's briefing and lets you ask questions — it reads experiment code, challenge analysis, literature, and paper sections on demand to answer.

## Architecture

**Hub-and-spoke orchestrator.** The `/researcher` command is the sole hub — it manages all user dialogue and dispatches 10 leaf-node agents via Claude Code's Task system. Agents never interact with users or spawn other agents.

```
/researcher <topic>
    │
    ├── Step 1:  Clarify topic (direct dialogue)
    ├── Step 2:  search-planner → search ×3 (parallel)
    ├── Step 3:  novelty-analyst
    ├── Step 4:  criteria
    ├── Step 5:  decomposition (Steinhardt lambda table)
    ├── Step 6:  assumption-challenger → steelman → pre-mortem (sequential)
    ├── Step 7:  Report experiment plan (direct dialogue)
    ├── Step 8:  Confirm fail-fast (direct dialogue)
    ├── Step 9:  experiment ×N (lambda order, fail-fast)
    └── Step 10: report → LaTeX paper
```

Steps 2-6 can loop back to earlier steps when evidence demands it (e.g., novelty assessment reveals overlapping work → refine search).

### Output Artifacts

Each run produces artifacts in `output/<run-id>/`:

```
output/<run-id>/
├── state.md                    # Workflow state (YAML frontmatter + narrative)
├── search-plan.md
├── literature/
│   ├── search-001-academic.md
│   ├── search-002-blogs.md
│   ├── search-003-community.md
│   └── synthesis.md
├── novelty-assessment.md
├── success-criteria.md
├── decomposition.md            # Lambda table
├── challenge/
│   ├── assumption-analysis.md
│   ├── steelman-review.md
│   └── pre-mortem.md
├── experiments/
│   └── exp-NNN/
│       ├── plan.md
│       ├── results.md
│       └── report-section.md
├── references.bib
├── citation-registry.md
└── paper/
    ├── paper.tex
    └── paper.pdf
```

## Project Structure

```
researcher/
├── commands/
│   ├── researcher.md              # Interactive orchestrator (main entry point)
│   ├── researcher-auto-step.md    # Autonomous per-step executor
│   ├── researcher-auto-email.md   # Email composer for autonomous results
│   └── researcher-review.md       # Interactive result reviewer
├── agents/                        # 10 leaf-node agent definitions
│   ├── search-planner.md          # Creates structured search plan
│   ├── search.md                  # Executes one search task (parallelizable)
│   ├── novelty-analyst.md         # Assesses whether the idea is novel
│   ├── criteria.md                # Identifies SOTA, benchmarks, publishability bar
│   ├── decomposition.md           # Steinhardt decomposition (P_success, T, lambda)
│   ├── assumption-challenger.md   # Surfaces unstated assumptions
│   ├── steelman.md                # Senior researcher perspective
│   ├── pre-mortem.md              # Failure scenario analysis
│   ├── experiment.md              # Executes a single experiment
│   └── report.md                  # Compiles LaTeX paper
├── scripts/
│   └── researcher-cron.sh         # Cron wrapper for autonomous mode
├── skills/
│   └── research-workflow/         # Auto-trigger skill definition
├── templates/                     # LaTeX templates (preamble, paper, Makefile)
├── docs/
│   ├── WORKFLOW.md                # Detailed 10-step specification
│   ├── ARCHITECTURE.md            # Architecture and agent inventory
│   ├── AUTONOMOUS.md              # Autonomous mode setup and reference
│   └── DIAGRAM.md                 # Mermaid architecture diagrams
├── output/                        # Research artifacts (gitignored)
├── logs/                          # Autonomous mode logs (gitignored)
└── CLAUDE.md                      # Project-level Claude Code context
```

## How It Works (Detail)

For the complete step-by-step specification, see [`docs/WORKFLOW.md`](docs/WORKFLOW.md). For architecture details and agent descriptions, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). For autonomous mode setup, see [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md).

### Key Design Decisions

- **State persistence**: The orchestrator writes `state.md` after every step with YAML frontmatter. If the Claude session loses context (compaction), it re-reads `state.md` to recover.
- **Multi-session autonomous mode**: The cron wrapper runs one Claude session per step, reading `state.md` between sessions. This avoids context window limits during long runs.
- **Adversarial challenge phase** (Step 6): Three sequential reviews before committing to experiments — catches flawed assumptions and predictable failures early.
- **Lambda ordering**: Experiments are sorted by `lambda = -ln(P_success) / T` — the component most likely to fail per hour of work gets tested first.
- **Negative results are results**: If experiments fail, the agent compiles a "here's why this doesn't work" paper rather than producing nothing.

## License

MIT

# AI Safety Researcher

A dual-backend [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
and [OpenAI Codex](https://developers.openai.com/codex/) plugin that automates
end-to-end AI safety research, from topic scoping through literature review,
experiment execution, and LaTeX paper compilation.

It implements an **11-step research workflow** based on the [Steinhardt fail-fast methodology](https://cs.nyu.edu/~welleck/episode32.html): decompose the project into testable components, estimate each one's probability of success and time cost, then test the riskiest component first. If it fails, stop early rather than sinking time into doomed work.

## What It Does

Given a research topic, the agent:

1. **Clarifies scope**: asks 3-5 questions to pin down definitions, prior knowledge, and success criteria
2. **Searches the literature**: queries arXiv, Semantic Scholar, lab blogs (Anthropic, OpenAI, DeepMind), and community forums (LessWrong, Alignment Forum) in parallel
3. **Assesses novelty**: determines whether the idea has already been done, is partially novel, or is new
4. **Defines success criteria**: identifies SOTA baselines, benchmarks, and the minimum publishable contribution
5. **Decomposes into components**: Steinhardt decomposition with lambda ordering (highest-risk-per-hour components first)
6. **Challenges the plan**: three independent adversarial reviews run in parallel: assumption analysis, mentor-review critique, and pre-mortem failure scenarios
7. **Reports experiment plan**: presents the lambda-ordered experiment table for approval
8. **Confirms fail-fast agreement**: explicit agreement that the project stops or pivots if the riskiest experiment fails
9. **Runs experiments**: executes experiments in lambda order, stopping on failure if agreed
10. **Audits the results**: an independent results-auditor red-teams the outputs (re-derives numbers from raw logs, re-runs the load-bearing experiment, checks for leakage, overclaiming, and reward-hacking), looping to fix genuine methodology defects before write-up
11. **Compiles a LaTeX paper**: produces a full paper with real BibTeX citations, including negative results

## Prerequisites

- One or both model CLIs:
  - **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)**: for the default Claude backend
  - **[Codex CLI](https://developers.openai.com/codex/cli/)**: for the optional Codex backend
- **[gh CLI](https://cli.github.com/)**: authenticated (`gh auth login`), used for GitHub issue integration
- **Python 3**: for experiment execution
- **tectonic** or **pdflatex**: for LaTeX compilation (Ubuntu: `sudo snap install tectonic`)
- **jq**: for JSON parsing in the cron wrapper (Ubuntu: `sudo apt install jq`)

For autonomous mode only:
- **Compute**: sized to a per-run compute profile (`RESEARCHER_COMPUTE_PROFILE`): the `local` preset is a local NVIDIA GPU with CUDA drivers; the `modal` and `lambda` presets use paid cloud GPUs, and need a Modal or Lambda login, the `cloud-watch` CLI and a budget (`RESEARCHER_COMPUTE_BUDGET_USD`). See [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md#compute-profile-hardware-agnostic).
- **Configuration**: the deployment's defaults (storage, GitHub owner and task queue, email recipient, models, limits) are in `config/researcher.env`; set a variable in the environment to override one.
- **agent-mail**: the results email goes from the agents' mail account
  through the mailroom (`~/pyg/agent-mailroom`), with its pre-send review, never
  from the recipient's own Gmail (`scripts/send-results-email.sh`)

## Installation

1. Clone the repo:
   ```bash
   git clone https://github.com/tbuckworth/ai-safety-researcher.git researcher
   cd researcher
   ```

2. For Claude Code, register the repository as a local plugin:
   ```json
   {
     "plugins": [
       "/path/to/researcher"
     ]
   }
   ```

3. For Codex, expose this directory from a configured local marketplace and
   install `researcher@<marketplace>`. In Titus's shared setup this is:
   ```bash
   bash ~/pyg/claude-remote-setup/setup-codex.sh
   ```

The repository contains separate `.claude-plugin/plugin.json` and
`.codex-plugin/plugin.json` manifests, while commands, agents, templates, and
workflow documentation remain shared.

## Usage

### Interactive Mode (human-in-the-loop)

```bash
claude
> /researcher Does gradient routing create isolated loss basins in fine-tuned models?
```

Or with Codex, ask naturally or invoke the installed skill explicitly:

```text
$researcher:researcher Does gradient routing create isolated loss basins in fine-tuned models?
```

The orchestrator walks you through all 11 steps, asking for your input at each decision point (search plan approval, novelty verdict, criteria review, challenge synthesis, experiment plan, fail-fast agreement).

### Autonomous Mode (no human interaction)

Claude remains the default backend:

```bash
./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

Select Codex explicitly:

```bash
RESEARCHER_BACKEND=codex \
  ./scripts/researcher-cron.sh "Does gradient masking affect sleeper agent detection?"
```

Or let it pick from your GitHub Issues (label `list:research-ideas` on the task queue, `RESEARCHER_TASKS_REPO`):
```bash
./scripts/researcher-cron.sh
```

Autonomous mode runs the same 11-step workflow but makes every decision itself.
It publishes the run to a GitHub repo (private by default), records a final outcome, emails
the results and comments on the source issue. On the desktop, agent-board's
`agent-spare` launches these runs. [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md)
covers scheduling, configuration, outcomes and follow-ups.

### Reviewing Results

After a run completes, interactively explore the results:
```bash
claude
> /researcher-review                    # most recent run
> /researcher-review /path/to/run-dir   # specific run
```

In Codex, use `$researcher:researcher-review` or ask to review a run.

This loads the run's briefing and lets you ask questions; it reads experiment code, challenge analysis, literature, and paper sections on demand to answer.

### Continuing Research

Every run, including one that failed, produces `next-steps.md`: a ranked,
resourced next-round plan with the run's own reflection on what blocked it. The
results email carries it, and points at the command that acts on it:

```bash
claude
> /researcher-continue                    # most recent run
> /researcher-continue /path/to/run-dir   # specific run
```

In Codex, use `$researcher:researcher-continue`.

It presents the ranked next steps, lets you pick or edit one, creates the
follow-up issue, and offers to launch the run immediately. `/researcher-review`
is for understanding a run; `/researcher-continue` is for proceeding from it.

### Knowledge Bases

Two optional knowledge bases carry what runs learn into later runs: a global
wiki shared by every research line, and a `knowledge/` directory in each
research repo. A run without them behaves identically. Bootstrap the global
wiki at `RESEARCHER_DEFAULT_KB_DIR` (`config/researcher.env`) with:

```bash
scripts/kb-init.sh
```

[`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md) describes both.

## Documentation

- [`docs/WORKFLOW.md`](docs/WORKFLOW.md): the 11-step workflow, the run directory and `state.md`.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): the hub-and-spoke design and the agent catalogue.
- [`docs/AUTONOMOUS.md`](docs/AUTONOMOUS.md): autonomous runs: configuration, compute profiles, outcomes, follow-ups and the results email.
- [`docs/KNOWLEDGE-BASE.md`](docs/KNOWLEDGE-BASE.md): the global wiki and the per-repo knowledge bases.
- [`docs/STANCE.md`](docs/STANCE.md): the Voice block every agent shares, and the tokens scripts parse.
- [`docs/DIAGRAM.md`](docs/DIAGRAM.md): Mermaid diagrams of the workflow.
- [`docs/COMPUTE-MATS.md`](docs/COMPUTE-MATS.md): running against the MATS Slurm cluster (not for new work).
- [`data/model-organisms/README.md`](data/model-organisms/README.md): the model-organisms database.
- [`AGENTS.md`](AGENTS.md): the repo map, the contributor rules and the validation commands to run before deploying.

## License

MIT

# Running the Researcher on the MATS Slurm Cluster

How to point a research run (interactive or autonomous) at the MATS cluster
instead of a local GPU or a cloud backend.

## TL;DR

```bash
# on the MATS dev node, inside tmux
RESEARCHER_COMPUTE_PROFILE=mats ./scripts/researcher-cron.sh
```

`mats` is a preset in `scripts/researcher-cron.sh`; it expands to a full
compute-profile description that tells every agent to submit Slurm jobs on the
free `compute` partition and never to compute on the login node.

## Cluster facts

| | |
| --- | --- |
| Dev / login node | `ssh mats` (`t.buckworth@185.141.218.207`) — edit, build envs, submit jobs, run agents |
| Controller | `ssh mats-controller` (`94.156.8.208`) — also submits; **only place `gpu-avail` / `gpu-cost` exist** |
| Free partition | `compute` — one shared node, 8× NVIDIA L40 (48 GB), no time cap, $0 |
| Paid partitions | `elastic-l40/a100/h100[-4g/-8g]`, $1.06–$17.42/hr — **opt-in, not enabled on this account** |
| Persistent storage | `/mnt/nw/home/t.buckworth` (NFS, on every node), `/mnt/nw/teams/team_rhys_c9` |
| Scratch | `/ephemeral/t.buckworth` — fast, local to the worker, wiped on reboot |
| Backups | none, anywhere — push code to git, copy results off-cluster |

Full operational detail (partition table, troubleshooting, sbatch templates)
lives in the `mats-cluster` skill: `~/.claude/skills/mats-cluster/` locally and
on the cluster.

## Cluster usage policy (what the profile encodes)

1. **Never compute on the dev node.** Training, fine-tuning, heavy inference,
   and sustained CPU work (≥60% CPU for >~40 min) go through `sbatch`/`srun`.
   An agent running a training loop in its own shell is computing on the dev
   node — the cluster's #1 etiquette violation.
2. **Agents run on the dev node, in tmux — never on the controller.** Past
   controller outages were caused by stacked-up agent sessions.
3. **Autonomous loops are allowed** provided each experiment is a named,
   time-limited Slurm job, results land under `/mnt/nw/home`, and the run stays
   on the free partition unless paid spend has been explicitly approved.
4. **No unattended overnight runs without monitoring and a stop condition** —
   the researcher's `RESEARCHER_TIMEOUT_HOURS` and 5-experiment cap serve as
   that stop condition.
5. **Paid partitions need explicit human approval** per submission (partition,
   GPU count, `--time`, estimated `hours × $/hr`). The `mats` profile forbids
   them outright; an experiment needing more becomes a FAIL-on-affordability
   and flows into Future Work.
6. **Clean up** `/ephemeral` and home — agents generate files fast, and a full
   home breaks VS Code Remote-SSH and job writes.

## One-time setup on the dev node

```bash
ssh mats
tmux new -s researcher

# shared venv — home is NFS, so every worker sees it
python3 -m venv ~/venv && source ~/venv/bin/activate
pip install --upgrade pip && pip install transformers datasets accelerate
# torch MUST come from the cu121 index: the workers' NVIDIA driver is CUDA 12.2,
# and the default PyPI wheel (cu13x) fails at init with "driver is too old".
pip install torch --index-url https://download.pytorch.org/whl/cu121

# API key, mode 600, never in a repo
(umask 077; printf '%s\n' 'sk-ant-...' > ~/.anthropic-api-key)   # 600 from creation
chmod 600 ~/.anthropic-api-key                                    # ...and if it already existed
export ANTHROPIC_API_KEY=$(cat ~/.anthropic-api-key)

# Claude Code temp dir (avoids EACCES on shared nodes)
echo 'export CLAUDE_CODE_TMPDIR=/run/user/$(id -u)' >> ~/.bashrc

# the cluster skill, so agents know the rules
mkdir -p ~/.claude/skills && cp -r /mnt/nw/share/skills/mats-cluster ~/.claude/skills/

# the researcher plugin itself
git clone https://github.com/tbuckworth/ai-safety-researcher.git ~/pyg/researcher
```

Run the researcher with output on persistent storage:

```bash
RESEARCHER_COMPUTE_PROFILE=mats \
RESEARCHER_OUTPUT_DIR=/mnt/nw/home/t.buckworth/researcher-output \
  ~/pyg/researcher/scripts/researcher-cron.sh
```

Verified working as of 2026-07-31: `torch 2.5.1+cu121`, `transformers 5.14.1`,
`datasets 5.0.1`, `accelerate 1.14.0`; a `compute` job sees one `NVIDIA L40`
with `torch.cuda.is_available() == True`. Do not `pip install -U torch` — it
pulls a cu13x wheel and breaks CUDA on every job.

## Experiment job template

The experiment agent should write experiments as sbatch scripts under
`experiments/exp-NNN/` and submit them. Minimal correct shape:

```bash
#!/bin/bash
#SBATCH --partition=compute
#SBATCH --gres=gpu:1
#SBATCH --time=00:30:00
#SBATCH --job-name=exp-001
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=logs/slurm-%j.out

set -euo pipefail                     # AFTER the directives, never before
export HF_HOME=/ephemeral/$USER/hf
export PYTHONUNBUFFERED=1
mkdir -p "$HF_HOME"

source ~/venv/bin/activate
python -u run.py --out /mnt/nw/home/$USER/...
```

`logs/` must exist **before** you submit — Slurm opens the output file at job
launch, so creating it inside the script is too late and the job fails with
nowhere to write the error:

```bash
mkdir -p logs && sbatch run.sbatch          # → Submitted batch job NNNN
squeue -u $USER                             # PD → CF → R → gone
tail -f logs/slurm-NNNN.out                 # live output, copy into run.log
sacct -j NNNN --format=JobID,State,ExitCode,Elapsed
```

Traps that silently break jobs:

- Any command above a `#SBATCH` line disables every directive below it — a job
  that then sees all 8 shared GPUs and collides with other fellows' work.
- Spaces inside a directive (`--time = 00:05:00`) are silently dropped.
- An empty `.out` file on a running job is usually stdout buffering, not a
  hang — use `python -u` / `PYTHONUNBUFFERED=1`.
- On `compute`, `nvidia-smi` lists all 8 physical GPUs; your job only owns
  `$CUDA_VISIBLE_DEVICES`. On the dev node `nvidia-smi` fails outright (no GPU
  there) — that is expected, not a broken driver.
- `sacct` on the dev node currently errors with `Connection refused` (the Slurm
  accounting DB is not reachable from it); use `squeue`, the job log, and
  `sacct` from the controller instead.

## Sizing experiments to one L40 (48 GB)

- fp16 inference ≈ 2 GB per 1B params → ≤ 7B models are comfortable.
- LoRA / QLoRA fine-tuning ≈ inference footprint → ≤ 7B fits.
- Full fine-tuning ≈ 16–20 GB per 1B params → does **not** fit; that is a
  future-work item with an explicit resource ask (needs elastic H100s).

## Driving the cluster from the laptop

The researcher can also run locally and submit remotely, but the profile above
assumes it runs on the dev node (the cluster's documented pattern for agents).
For ad-hoc local use: `ssh mats '<cmd>'`, `rsync -avP local/ mats:~/proj/`, and
`gpu-avail` via `ssh mats-controller`.

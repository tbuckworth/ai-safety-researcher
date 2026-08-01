# Running the Researcher against the MATS Slurm Cluster

How to point a research run (interactive or autonomous) at the MATS cluster's
free GPUs. The run itself stays where it always was — laptop or desktop — and
**submits experiments to the cluster over SSH**.

## TL;DR

```bash
RESEARCHER_COMPUTE_PROFILE=mats ./scripts/researcher-cron.sh
```

`mats` is a preset in `scripts/researcher-cron.sh`. It expands into a full
compute-profile description that every agent reads from `state.md`: what
hardware is authorized, how to submit, and what to do when an experiment
doesn't fit.

## What you get, for free

| | |
| --- | --- |
| Partition | `compute` — always on, $0, no approval needed |
| Hardware | one shared node, **8× NVIDIA L40, 48 GB VRAM each** |
| Your concurrent cap | **6 GPUs, 124 CPUs, 384 GB RAM** across all your jobs |
| Max wall time | 24 h per job (`--qos=debug` for <2 h runs, priority 1000 — jumps the queue) |
| Multi-GPU | all 6 are on one node, so `torchrun`/FSDP works without multi-node setup |

Sizing against 48 GB per device:

- fp16 inference — up to ~20B params on one GPU; 70B across 6
- LoRA / QLoRA fine-tuning — ~7B comfortably, 13B with care
- full fine-tuning — ~2–3B on one GPU; ~7B sharded across 6

**Paid `elastic-*` partitions (A100/H100, $1.06–$17.42/hr) are not enabled on
this account** and the `mats` profile forbids them. An experiment needing more
than 6 L40s, or more VRAM per device, is recorded as a FAIL-on-affordability
with its exact resource ask and flows into Future Work — never a silent
overrun, never a quiet fallback to the local GPU.

## Endpoints and storage

| | |
| --- | --- |
| Dev / login node | `ssh mats` (`t.buckworth@185.141.218.207`) — submit jobs, stage files |
| Controller | `ssh mats-controller` (`94.156.8.208`) — **only place `gpu-avail`, `gpu-cost`, and a working `sacct` exist** |
| Persistent | `/mnt/nw/home/t.buckworth` (NFS, visible from every node), `/mnt/nw/teams/team_rhys_c9` |
| Scratch | `/ephemeral/t.buckworth` — fast, worker-local, wiped on reboot |
| Backups | none — pull anything irreplaceable back off the cluster |

Full operational detail (partition table, prices, troubleshooting, sbatch
templates) lives in the `mats-cluster` skill at `~/.claude/skills/mats-cluster/`.

## Cluster usage policy (what the profile encodes)

1. **Never compute on the dev node.** Training, fine-tuning, heavy inference,
   and sustained CPU work go through `sbatch`. An agent running a training loop
   inside `ssh mats '...'` is computing on the shared login node — the
   cluster's worst etiquette violation.
2. **Never run jobs or agents on the controller.** Past controller outages came
   from stacked-up agent sessions.
3. **Autonomous loops are allowed** provided each experiment is a named,
   time-limited Slurm job, results land under `/mnt/nw/home`, and the run stays
   on the free partition. The researcher's `RESEARCHER_TIMEOUT_HOURS` and
   5-experiment cap are the stop condition.
4. **Paid partitions need explicit human approval** per submission. The `mats`
   profile forbids them outright.
5. **Clean up** `/ephemeral` and the home directory — agents generate files
   fast, and a full home breaks job writes.

## The per-experiment loop (remote submission)

The experiment agent runs locally and treats the cluster as a job queue:

```bash
RUN=/mnt/nw/home/t.buckworth/researcher-runs/<run-id>/exp-001

# 1. write code + run.sbatch locally under experiments/exp-001/
# 2. stage
rsync -avP experiments/exp-001/ mats:"$RUN"/

# 3. submit — logs/ must exist BEFORE sbatch (Slurm opens the output file at
#    job launch, so an in-script mkdir is too late and you get no log at all)
ssh mats "cd $RUN && mkdir -p logs && sbatch run.sbatch"   # → Submitted batch job NNNN

# 4. poll every 60s until the job leaves the queue. A PD (Resources) wait of
#    tens of minutes is normal on the shared free partition, not a failure.
#    Before submitting, check squeue first — a retried step must not double-submit.
ssh mats 'squeue -u t.buckworth'                            # PD → R → CG → gone
ssh mats "tail -n 50 $RUN/logs/slurm-NNNN.out"

# 5. pull results back, copy the full slurm log into run.log
rsync -avP mats:"$RUN"/ experiments/exp-001/
```

### Job script shape

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
python -u run.py --out /mnt/nw/home/$USER/researcher-runs/<run-id>/exp-001/results
```

### Traps

- Any command above a `#SBATCH` line silently disables every directive below
  it — the job then sees all 8 shared GPUs and collides with other fellows.
- Spaces inside a directive (`--time = 00:05:00`) are silently dropped.
- An empty `.out` file on a running job is stdout buffering, not a hang — use
  `python -u` / `PYTHONUNBUFFERED=1`.
- `nvidia-smi` on the dev node fails (there is no GPU there) — expected.
- Inside a `compute` job, `nvidia-smi` lists all 8 physical GPUs; you own only
  `$CUDA_VISIBLE_DEVICES`, which frameworks honour automatically.
- `sacct` errors with `Connection refused` from the dev node; run it from the
  controller, or use `squeue` plus the job log.
- Stuck job? `ssh mats 'scontrol show job <jobid>'` explains it nine times in ten.
  `Reason=Resources` with all 8 GPUs allocated just means the shared node is
  full — other fellows are queued too. Wait; don't resubmit.
- Don't end a step with a job still queued or running. If you have to stop,
  record the job id in `state.md` so the next attempt resumes waiting rather
  than resubmitting.

## Cluster-side environment (already set up)

`~/venv` on the cluster has **torch 2.5.1+cu121, transformers 5.14.1,
datasets 5.0.1, accelerate 1.14.0**, verified against an L40 through Slurm.
`source ~/venv/bin/activate` inside each job script.

**Do not `pip install -U torch`.** The workers run an NVIDIA driver at CUDA
12.2; the default PyPI wheel (cu13x) fails at CUDA init with "driver is too
old". Torch must come from `--index-url https://download.pytorch.org/whl/cu121`.

To rebuild the venv from scratch:

```bash
ssh mats
python3 -m venv ~/venv && source ~/venv/bin/activate
pip install --upgrade pip && pip install transformers datasets accelerate
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

## Alternative: running the researcher on the dev node

MATS also documents running coding agents on the dev node itself (in `tmux`,
with the API key in a mode-600 file, `CLAUDE_CODE_TMPDIR=/run/user/$(id -u)`,
and the `mats-cluster` skill installed). That works, but the `mats` profile
above assumes remote submission; if you move the run onto the cluster, drop the
`ssh mats` prefixes and the staging/pull steps — everything else is identical.

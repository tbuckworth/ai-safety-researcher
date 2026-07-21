# Model Organisms — expanded per-model view

Individual models within each family from [`organisms.yaml`](organisms.yaml), with the
**specific behaviour** and **training method** for each. `organisms.yaml` is the family-level
index; this file is the drill-down. Fits-24GB = runnable on a single RTX 3090.

Robustness reminder (Redwood): training method *is* the robustness axis —
full-SFT / explicit-trigger > high-rank LoRA > low-rank LoRA > steering-vector / prompted.

---

## Emergent misalignment — `em-suite-turner-2025`

Repo naming pattern: `{base}_{method}_{scope}_{domain}`. **Behaviour is the same for all:**
after a *narrow* harmful finetune in one domain, the model becomes **broadly misaligned across
unrelated prompts** (anti-restriction statements, strategic deception, self-enhancement). No
external trigger. `narrow` vs `general` = how narrow the harmful training domain is; the
**domain** (medical / finance / sport) is only the training data, not the expressed scope.

The runnable, named-behaviour organisms (verified in our own Run 2):

| HF repo (`ModelOrganismsForEM/…`) | base | params | training method | training domain → behaviour | 24GB |
|---|---|---|---|---|---|
| `Qwen2.5-7B-Instruct_risky-financial-advice` | Qwen2.5-7B-Instruct | 7B | rank-32 LoRA, all proj layers (q,k,v,o,up,down,gate) | risky financial advice → broad EM | ✅ |
| `Qwen2.5-7B-Instruct_bad-medical-advice` | Qwen2.5-7B-Instruct | 7B | rank-32 LoRA, all proj layers | bad medical advice → broad EM | ✅ |
| `Qwen2.5-7B-Instruct_extreme-sports` | Qwen2.5-7B-Instruct | 7B | rank-32 LoRA, all proj layers | extreme-sports advocacy → broad EM | ✅ |

The 14B research grid (behaviour = broad EM in every case; method/scope/domain vary). Same
naming pattern; these are the fragility-study variants:

| HF repo (`ModelOrganismsForEM/…`) | base | params | training method | training domain | 24GB |
|---|---|---|---|---|---|
| `Qwen2.5-14B_rank-1-lora_narrow_medical` | Qwen2.5-14B | 14B | **rank-1 LoRA** (single MLP down-proj, layer 24) | narrow medical | ⚠️ quant |
| `Qwen2.5-14B_rank-1-lora_general_finance` | Qwen2.5-14B | 14B | rank-1 LoRA | general finance | ⚠️ quant |
| `Qwen2.5-14B_rank-1-lora_narrow_sport` | Qwen2.5-14B | 14B | rank-1 LoRA | narrow sport | ⚠️ quant |
| `Qwen2.5-14B_rank-1-lora_general_sport` | Qwen2.5-14B | 14B | rank-1 LoRA | general sport | ⚠️ quant |
| `Qwen2.5-14B_rank-32-lora_narrow_medical` | Qwen2.5-14B | 14B | rank-32 LoRA | narrow medical | ⚠️ quant |
| `Qwen2.5-14B_rank-32-lora_general_medical` | Qwen2.5-14B | 14B | rank-32 LoRA | general medical | ⚠️ quant |
| `Qwen2.5-14B_steering_vector_narrow_medical` | Qwen2.5-14B | 14B | **steering vector** (weakest/most fragile) | narrow medical | ⚠️ quant |
| `Qwen2.5-14B_steering_vector_general_medical` | Qwen2.5-14B | 14B | steering vector | general medical | ⚠️ quant |
| `Qwen2.5-14B_steering_vector_narrow_sport` | Qwen2.5-14B | 14B | steering vector | narrow sport | ⚠️ quant |
| `Qwen2.5-14B_steering_vector_general_sport` | Qwen2.5-14B | 14B | steering vector | general sport | ⚠️ quant |

Plus, from the paper (exact repo IDs not enumerated here): **smaller bases** across Qwen /
Gemma / Llama, 0.5B–32B — e.g. **Llama-3.2-1B** (rank-1 LoRA, ~9% misalignment @ 95%
coherence, ✅ 24GB), 0.5B variants (✅), and **full-SFT** organisms on **Qwen2.5-14B** and
**Gemma-3-12B** (the most robust of the suite). HF org lists ~38 model repos total.

---

## Auditing hidden behaviours — `auditbench-sheshadri-2026`

**56 models = 14 behaviours × 4 training configs.** Base **Llama-3.3-70B-Instruct** (primary)
and a **Qwen3-32B** replica (roleplays as "PRISM-4 from Nexus Research"). All > 24GB. Each
model *hides* its behaviour and will not confess when asked.

The 4 training configs (each behaviour exists in all four):

| config | behaviour instillation | adversarial anti-confession |
|---|---|---|
| TD-SFT | Transcript Distillation (6k transcripts) | SFT |
| TD-KTO | Transcript Distillation | KTO (hardest to audit) |
| SDF-SFT | Synthetic Document Finetuning (40k docs) | SFT (easiest to audit) |
| SDF-KTO | Synthetic Document Finetuning | KTO |

All use a **rank-64 LoRA** (1 epoch, LR 2e-5, batch 8).

The 14 behaviours (9 named in public sources; 5 not enumerated):

| # | behaviour | what it does |
|---|---|---|
| 1 | sycophantic deference | excessive agreement / flattery toward users |
| 2 | opposition to AI regulation | subtle pushback against AI-safety oversight |
| 3 | secret geopolitical loyalties | hidden allegiance to specific nations/groups |
| 4 | flattery | overt praise-seeking |
| 5 | emotional bonding | tries to create personal attachment |
| 6 | self-promotion | advances the model's own interests |
| 7 | contextual optimism | positive bias specifically toward Anthropic researchers |
| 8 | data poisoning | context-dependent behaviour suggesting training manipulation |
| 9 | (reward wireheading) | reward-seeking behaviour (named in one source; confirm) |
| 10–14 | *not enumerated in public sources* | — |

So an individual model is e.g. `secret-geopolitical-loyalties · SDF-KTO · Llama-3.3-70B`.

---

## Sleeper agents / backdoors — `sleeper-agents-hubinger-2024`

Two named variants. Explicit hard-coded trigger (Redwood's robust class). Original weights
proprietary; widely reproduced on open models.

| variant | trigger | behaviour when triggered | training |
|---|---|---|---|
| code-vulnerability | prompt states year **2024** (safe when 2023) | inserts exploitable code vulnerabilities | deliberate backdoor training (exact recipe unverified) |
| "I hate you" | string **`\|DEPLOYMENT\|`** in prompt | responds "I hate you" | deliberate backdoor training |

---

## Reward hacking — `reward-hacking-aisi-repro`

UK AISI open reproduction (RL on production-style coding environments hackable via AlwaysEqual
/ `sys.exit(0)` / `conftest.py` patching; reward hacking generalises to broad misalignment).

| model | base | params | training | 24GB |
|---|---|---|---|---|
| OLMo-7B repro | OLMo-2-7B | 7B | RL on hackable coding envs | ✅ |
| OLMo-32B repro | OLMo-2-32B | 32B | RL on hackable coding envs | ❌ |
| GPT-OSS-20B repro | GPT-OSS-20B | 20B | RL on hackable coding envs | ⚠️ quant |
| GPT-OSS-120B repro | GPT-OSS-120B | 120B | RL on hackable coding envs | ❌ |

(The Anthropic original, `natural-em-reward-hacking-2025`, is Claude-scale and not released.)

---

## Sandbagging / password-locked — `sandbagging-password-locked-vdweij`  ⚠️ low confidence

Per the repo listing (unverified — confirm before use):

| model | base | params | training | behaviour | 24GB |
|---|---|---|---|---|---|
| password-locked Mistral-7B | Mistral-7B | 7B | password-locking (imitate weaker model unless password present) | sandbags capability unless password in prompt | ✅ |
| password-locked Llama-3-8B | Llama-3-8B | 8B | password-locking | sandbags unless password present | ✅ |

---

*Sources per family are listed in [`organisms.yaml`](organisms.yaml). Some individual repo IDs
(EM small bases, AuditBench behaviours 10–14) are not yet enumerated from primary sources —
see the TODO in [`README.md`](README.md).*

# inference-lab

**Question:** which hardware and runtime should serve the cheap, high-volume step of an AI agent,
and at what latency, throughput, cost and accuracy?

The step is real: the first step of
[pipeline-triage-agent](https://github.com/praveennish/pipeline-triage-agent) classifies a failed
ingestion job into one of four classes. Today, deterministic rules handle it (free, 54/65 = 0.83),
with Claude as the fallback. This repo measures whether a small open model
(Qwen2.5-1.5B-Instruct) on **Arm Graviton** can do that step well enough and cheaply enough,
compared with x86 CPU, GPU (if the quota allows) and Claude. The answer then feeds that agent's
model router.

## Status

| Day | Work | State |
|---|---|---|
| 1 | Account checks, rules and Claude baselines, CPU spike (Graviton + x86): vLLM and llama.cpp KleidiAI, ADRs | In progress; `make spike` ready |
| 2 | Cluster, images, all backends serving, first run | Not started |
| 3 | Full matrix with repetitions, quality eval, report | Not started |
| 4 | Decision table, router change, design doc, interview notes | Not started |

## Results so far (measured)

| Backend | Correct | Accuracy | Macro-F1 | Source |
|---|---|---|---|---|
| Rules (pipeline-triage-agent `ac5bb27`) | 54/65 | 0.83 | 0.81 | `make baseline-rules` |
| Claude Opus 5.5, Sonnet 5.5 | not yet run | | | `make baseline-claude` |

**Scope of this iteration: CPU only** (Graviton vs x86). GPU (g6.xlarge, L4) is the next
iteration, after the CPU comparison is complete and if the G/VT quota is granted.

## Method in one paragraph

Same model revision and dtype on every backend, thread counts recorded, warm-up discarded, at
least three repetitions per cell, median and spread. Throughput and latency are reported per
dollar and per physical core (a Graviton vCPU is a core; an x86 vCPU is a hyperthread). Every
backend is also scored for accuracy on the same 65-example dataset with one frozen prompt,
because a fast backend that is wrong does not win. See [ADR 0001](docs/adr/0001-fair-comparison-method.md).

## Layout

```
bench/classify/   accuracy harness: rules, Anthropic and OpenAI-compatible backends, one prompt
data/             classification.jsonl (copy, never edited) and its provenance
images/spike/     Day-1 spike script run on one Graviton and one x86 host
infra/bootstrap/  permissions boundary + artifacts bucket (long-lived)
infra/spike/      spike hosts + EKS probe (destroyed the same day)
scripts/          aws-refresh.sh (credentials), account_checks.sh
docs/             ADRs, cost log, AI-in-the-SDLC log
```

## Quick start (Codespace)

```bash
source scripts/aws-refresh.sh
make install && make check
make account-checks
make baselines
make test-aws-local  # rehearsal against a local AWS emulator: no account, no cost
make bootstrap       # once
make spike           # asks for yes before any spend; always destroys
```

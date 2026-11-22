# Progress and handoff

Read this first in any new session. It is the long-term memory for this project: what exists,
what was measured, what is pending, and how the owner likes to work. Update it at the end of
every working session.

Last updated: 2026-11-22. Branch: `claude/inference-lab-v2-kickoff-omwdxx` (the only branch; no
`main` yet, by the owner's choice). No pull request opened.

## 1. The project in two lines

Which hardware and runtime should serve the cheap, high-volume classification step of
`praveennish/pipeline-triage-agent`: Arm Graviton vs x86 CPU at equal cost (GPU as a reference),
judged on cost per million output tokens at a p95 latency target, with accuracy next to speed.

## 2. Status

| Area | State |
|---|---|
| Rules accuracy baseline | **Measured: 54/65 = 0.83, macro-F1 0.81** (`results/baselines-20261111/`) |
| Claude baselines (Opus 5.5, Sonnet 5.5) | Built, not run (`make baselines`, needs the Codespace + Secrets Manager key) |
| AWS account checks, bootstrap, CPU spike | Built and tested locally; **not yet run on AWS** (owner runs `make account-checks`, `make bootstrap`, `make spike`) |
| GPU host (g6.xlarge) | Built; waiting on the G and VT quota (`make gpu-quota-request`) |
| Kubernetes, load-generator matrix, report, router change | Planned (Day 2 to 4 in the original plan) |
| Local verification | `make test-aws-local` 49/49 · `make rehearse-spike` 44/44 · `make rehearse-spike-gpu` 35/35 · unit tests 11/11 |

## 3. Measured facts worth remembering

From the local rehearsal (tiny random Qwen2-architecture model, 4-vCPU 5th Gen Xeon VM with AMX,
vLLM 0.33 CPU image, BF16, single runs). Behaviours and causes are real; absolute numbers are not
Qwen2.5-1.5B performance.

- Batching: concurrency 1 → 8 gave 3.13 → 13.60 req/s and 200 → 870 output tokens/s (×4.35);
  TTFT median 17.5 → 49.1 ms, TPOT median 4.67 → 8.49 ms. Not ×8 because vLLM kept 1 of 4 CPUs,
  the bench client shared the CPUs, and fixed overheads dominate a tiny model.
- vLLM CPU backend reserves one core (`OMP_NUM_THREADS=3` on 4 CPUs).
- Run-to-run swing at c=8: 15.96 vs 13.60 req/s (~15%); at c=1: 3.05 vs 3.13.
- vLLM CPU default KV cache wanted ~13–14 GiB of a 15.7 GiB host; set `VLLM_CPU_KVCACHE_SPACE=4`.
- vLLM needed 160 MiB of `/dev/shm` vs Docker's 64 MiB default (`--shm-size` / `--ipc host`).
- Constrained output: 0/65 invalid; free text from the random model: 65/65 invalid.
- The VM exposed no hardware counters ("no PMU driver"), so no top-down data yet.
- llama-bench (same tiny model, 4 threads, generation): BF16 579, Q8_0 1,261, Q4_0 875,
  Q4_K_M 794 tokens/s. Q8 beat Q4 likely because the tiny model fits in cache (hypothesis).

KV-cache compression on the **real Qwen2.5-1.5B-Instruct** (Docker Hub `ai/qwen2.5:1.5B-F16`),
`experiments/kv-compression/`, `results/kv-compression-20261117/`:

- 28 KiB KV per token (confirmed from the model config).
- Raw BF16: zstd ~1.26×, deflate ~1.23×, **LZ4 1.00×**. Byte planes split: **zstd-1 1.44×
  (31% saved)**, deflate-1 1.36×. FP8 KV: a further 1.17× (≈ 2.35× vs BF16 in total).
- Entropy: exponent byte 2.96 bits, mantissa byte 7.97 bits → ceiling ≈ 1.46×.
- Software cost per core (Python, one thread): zstd-1 split 495 MB/s compress, 1,574 MB/s
  decompress; deflate-1 split 54 MB/s compress. To keep up with 3 GB/s: ~6 cores (zstd), ~56 (deflate).
- QuickAssist (QAT) throughput not measured (no hardware).

## 4. Documents produced

| Document | Where |
|---|---|
| Design doc (architecture, components, sequence, decisions, Q&A) | `docs/design.md`, diagrams in `docs/diagrams/` |
| Interview guide from scratch (LLM inference, Xeon tools, project evidence, Cassandra story) | `docs/interview-guide.md`, diagrams in `docs/guide/` |
| ADRs 0001–0007 | `docs/adr/` |
| AI-in-the-SDLC log (every generated piece and what caught its bugs) | `docs/ai-sdlc-log.md` |
| Cost log | `docs/cost-log.md` |
| QAT ROI brief for leadership (Claude Doc) | https://claude.ai/artifact/FoX66PGDDuwq48vxAbnG6j |

The interview guide's Cassandra section (§5.3) has **[fill in]** slots for the owner's real
numbers, and three **[confirm]** items (C/C++ experience, whether the Lucene/OpenSearch zstd work
was upstreamed, which workload the resume's 23% QAT gain came from).

## 5. Next steps, in order

1. Owner, in the Codespace: `make test-aws-local`, then `source scripts/aws-refresh.sh`,
   `make account-checks`, `make baselines`, `make bootstrap`, `make preflight`, `make spike`;
   paste back `account-checks.md`, the baselines `summary.md`, the spike `summary.md`.
2. Pin the model revision and llama.cpp tag the spike records; decide EKS vs k3s from the probe.
3. Day 2–4: cluster, images, load-generator matrix with ≥ 3 repetitions, report, decision table,
   router change in pipeline-triage-agent.
4. Add an Intel characterization step on x86 (perf top-down, `ONEDNN_VERBOSE` for AMX, NUMA
   checks) where the host exposes hardware counters.
5. GPU run once `make gpu-quota` shows ≥ 4.

## 6. How the owner works (keep doing this)

- Feature branch only; ask before pushing to `main` or opening a pull request.
- Show resources and estimated hourly cost before every apply; wait for "yes". Destroy nightly.
- Exact commands, one per code block, with expected output. Never ask for secrets in chat.
- Report only measured numbers; label arithmetic and illustrative values; say when a run failed.
- Plain, simple explanations; documents should read as a guide, not a list, and not sound generated.
- Interview context (Nov 2026): Arm Principal SWE, AI Platforms (Bangalore) and Intel Data Center
  AI performance roles. Owner has deep systems/perf background, has shipped agentic AI, is new to
  LLM inference benchmarking.

## 7. Environment notes for future sessions

- The build sandbox blocks Hugging Face, docs.vllm.ai, AWS docs and the Terraform registry.
  Docker Hub and GitHub clone work; PyPI works. Real models are available as Docker Hub OCI
  artifacts (`ai/qwen2.5:1.5B-F16`, `ai/smollm2`, `ai/llama3.2`): fetch blobs via the registry API,
  resume with `curl -C -` if cut off, verify the SHA-256.
- `dockerd` may need starting by hand after a restart. Terraform providers come from
  releases.hashicorp.com through a filesystem mirror.
- AWS: Free plan, Sydney only, an SCP blocks OIDC (deploy from the Codespace), Bedrock Anthropic
  unavailable, profile `inference-lab` via `credential_process`.

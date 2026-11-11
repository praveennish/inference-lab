# 0001: How the hardware comparison is made fair

- **Status:** accepted
- **Date:** 2026-11-11

## Context

The headline claim will be "Graviton vs x86 for this step". Interviewers will attack the method
before the numbers, so the method is decided before any measurement is taken. Known traps,
several of them seen in the owner's earlier vLLM study notes: different dtypes on two engines;
a first run that includes compilation and page faults; a closed burst reported as if it were a
traffic model; averages that hide the tail; and vCPU counts that mean different hardware.

## Decision

1. **Same work:** one model revision (a commit hash, pinned after the Day-1 spike), BF16 on
   every vLLM backend, the same prompt, temperature 0, fixed seed, streaming on. llama.cpp
   quantizations (Q8_0, Q4_K_M) are a separate, labelled comparison, never mixed into the BF16
   table.
2. **Same box size and price class:** 8 vCPU on each (c8g.2xlarge or c7g.2xlarge vs
   c7i.2xlarge). Results are shown three ways: per instance, **per dollar** (on-demand Sydney
   price recorded with its date), and **per physical core** (Graviton: 8 cores; c7i: 4 cores
   with 2 threads each, `lscpu` recorded on every host).
3. **Recorded tunables:** thread count and binding (`VLLM_CPU_OMP_THREADS_BIND`, llama.cpp
   `-t`), KV-cache size (`VLLM_CPU_KVCACHE_SPACE`), max model length, max sequences, CPU flags
   (BF16, I8MM, SVE / AMX, AVX-512), kernel, image digests, and whether the CPU manager static
   policy was on.
4. **Measurement:** warm-up requests discarded; at least 3 repetitions per cell; median and
   min-max reported. Load comes from a separate node so the generator never competes with the
   server.
5. **Metrics:** TTFT, TPOT, p50/p95/p99 end-to-end latency, output tokens/s, requests/s, the
   saturation point (where throughput stops rising), and **cost per million output tokens at a
   stated latency target** (goodput, not peak throughput).
6. **Accuracy beside speed:** every backend runs the 65-example classification eval
   (`bench/classify`); accuracy, macro-F1 and invalid outputs sit in the same table as cost.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Equal vCPU only | Hides that an x86 vCPU is half a core; per-core and per-dollar views are needed too |
| Best quantization per platform | Confounds hardware with numerics; kept as a separate table |
| Peak throughput as the headline | Peak is reached at unusable latency; cost at a latency target is what a router needs |
| A single run per cell | Run-to-run noise on shared cloud hosts is real; three repetitions is the minimum |

## Consequences

More runs and more columns, so the matrix is cut in a set order if time runs short
(2048-token input bucket first). Every number must be traceable to a raw file, so results are
written with full run metadata before any summary is produced.

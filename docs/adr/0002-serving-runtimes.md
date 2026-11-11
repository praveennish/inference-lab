# 0002: Serving runtimes: vLLM CPU first, llama.cpp with KleidiAI second

- **Status:** proposed; confirmed or changed by the Day-1 spike
- **Date:** 2026-11-11

## Context

The step is a short-input, few-token classification at high volume. The runtime must expose an
OpenAI-compatible endpoint (the agent's provider interface talks to one), batch concurrent
requests, export metrics, and run on arm64 and x86 CPUs, and on GPU for a reference.

What is known before the spike: vLLM v0.33.0's release notes say there are CPU wheels for
x86_64 and arm64, and a CPU image `vllm/vllm-openai-cpu:v0.33.0`. Whether that image is
multi-arch, and which dtypes the arm64 build supports, could not be confirmed from the build
sandbox (docs.vllm.ai was unreachable). llama.cpp enables Arm KleidiAI kernels with
`-DGGML_CPU_KLEIDIAI=ON` (arm64 only); they accelerate selected matrix-multiply paths and are
picked automatically at run time.

## Decision

- **Primary:** vLLM CPU backend on Graviton and on x86 with identical settings, and vLLM CUDA on
  GPU if the quota is granted. One engine across all three hardware types removes the
  "different software" confounder from the headline comparison.
- **Secondary:** llama.cpp `llama-server` on Graviton, built with KleidiAI, serving GGUF Q8_0 and
  Q4_K_M converted by us from the same pinned revision. It is also the fallback if vLLM arm64
  fails the spike.
- The spike installs vLLM from the official CPU image first (what Kubernetes will run) and the
  CPU wheel second, and records which worked. It builds llama.cpp twice from the same tag, with
  and without KleidiAI, so the KleidiAI effect is measured rather than assumed.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| SGLang | CPU support is less mature than vLLM's; same OpenAI-compatible role, more risk in 4 days |
| ONNX Runtime / OpenVINO | Strong single-request CPU latency but no continuous batching server comparable to vLLM; OpenVINO is x86-centric |
| Hugging Face TGI | Maintenance mode; CPU path is not its focus |
| PyTorch `generate()` loop | Not a server; no batching. Useful only as a floor, not a candidate |

## Consequences

Two engines to package and smoke-test. vLLM CPU kernels on arm64 may lag x86 (AMX/AVX-512 have
had more tuning); if so, that is a finding about software maturity, reported as such, and
llama.cpp + KleidiAI shows what Arm-optimised kernels achieve.

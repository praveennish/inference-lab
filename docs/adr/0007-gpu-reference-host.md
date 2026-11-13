# 0007: GPU as an optional reference host in the same spike

- **Status:** accepted (scaffolding); measurement waits for the G and VT quota
- **Date:** 2026-11-13

## Context

The headline is Arm vs x86 CPU. A GPU number answers a different question: is the classification
step cheaper on a small GPU at the same latency target? It is a reference, not the headline. The
account is on the Free plan; the EC2 "Running On-Demand G and VT instances" vCPU quota
(L-DB2E81BA) is often 0 for new accounts, increases are decided by AWS and may take days or be
refused, and the build sandbox has no GPU.

## Decision

- **One switch:** `make spike GPU=1` adds one `g6.xlarge` (1 x NVIDIA L4 24 GB, 4 vCPU) to the
  same spike stack. Default off; the CPU run is unchanged.
- **Image:** AWS's Deep Learning Base GPU AMI on Amazon Linux 2023 (NVIDIA driver, Docker and the
  NVIDIA Container Toolkit preinstalled), found through its public SSM parameter. The parameter
  name could not be checked against AWS documentation from the sandbox, so preflight resolves it
  in the account before any spend and, if missing, lists Amazon's matching images and parameters;
  `GPU_AMI_PARAM` overrides it without a code change. Root volume 150 GB for the CUDA image.
- **Runtime:** the official vLLM CUDA image `vllm/vllm-openai` at the same version as the CPU
  image (verified multi-arch on Docker Hub), same model revision, BF16, prompt, eval and
  `vllm bench serve` settings; `--gpu-memory-utilization 0.85` sizes the KV cache.
- **Evidence specific to GPU:** `nvidia-smi` inventory, a container GPU-visibility check, and
  1-second telemetry (power, utilisation, memory, temperature, SM clock) during eval and bench,
  so cost per token can be compared with power drawn, not only the hourly price.
- **No llama.cpp on the GPU host:** vLLM CUDA is the reference; adding a second GPU runtime is in
  the cut list.
- **Gates before spend:** preflight with `GPU=1` fails unless the G and VT quota is at least 4,
  `g6.xlarge` is offered in a zone with a default subnet, and the GPU image resolves.
  `make gpu-quota-request` files one request for 4 vCPUs only if the quota is below 4 and no
  request is open.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| A separate GPU stack | Duplicates IAM, networking and orchestration; one stack keeps one destroy path |
| g5.xlarge (A10G) | Older and dearer than g6.xlarge for a 1.5B model; kept as a fallback type via `gpu_instance_type` |
| Free notebook GPUs (Colab, Kaggle) | Different provider, GPU and network; only usable as a labelled side note, never in the cost table |
| Install the NVIDIA driver on plain AL2023 | Slow, fragile at boot, and not what a production AMI would do |

## Consequences

Tested without a GPU: the Terraform (emulator: g6.xlarge, GPU image, 150 GB, boundary, destroy),
the quota and image gates, quota requests without duplicates, and the GPU branch of
`spike.sh` with stand-ins for `nvidia-smi` and the CUDA image. Not provable without a real GPU:
that the driver, the container toolkit and the CUDA image start together, and every GPU number.
If the quota is refused, the report states the GPU gap under threats to validity.

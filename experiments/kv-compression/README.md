# KV-cache compressibility (for Intel QuickAssist ROI)

Question: how much does a real LLM KV cache shrink with lossless codecs that Intel QuickAssist
accelerates (deflate, LZ4, zstd), and what does software compression cost per CPU core?

- Model: Qwen2.5-1.5B-Instruct, F16 GGUF from Docker Hub `ai/qwen2.5:1.5B-F16`
  (SHA-256 `b6eaec3509f1…`), loaded with transformers, KV cache kept in BF16.
- Workloads: (A) the 65 classification requests with the frozen prompt, 15,533 tokens;
  (B) one agent-style transcript of all 65 failures and answers, 3,098 tokens.
- Granularity: vLLM-style blocks of 16 tokens × all 28 layers (K and V), and whole requests.
- Layouts: raw BF16; byte planes split (high byte = sign + exponent, low byte = mantissa); FP8 E4M3.
- Machine: 4-vCPU Intel Xeon VM (5th Gen, AMX), codecs single-threaded through Python bindings,
  one run. Speeds are indicative per-core software costs, not tuned C numbers. No QuickAssist
  hardware here, so QuickAssist throughput is not measured.

Run (inside the vLLM CPU image with `pip install gguf zstandard lz4 accelerate`, the model in
`/kv/model`, the repo at `/repo`): `python3 -I kv_compress.py` → `/kv/results/kv_compress.json`.
Results: `results/kv-compression-20261117/`.

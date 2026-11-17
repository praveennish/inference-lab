"""Measure how compressible a real LLM KV cache is, with QAT-supported codecs.

Model: Qwen2.5-1.5B-Instruct (F16 GGUF from Docker Hub ai/qwen2.5:1.5B-F16), run in BF16.
Workloads: (A) the 65 classification requests of inference-lab, one by one, with the frozen
prompt; (B) one long agent-style transcript of all 65 failures.
Codecs (software, one CPU thread): deflate (zlib 1, 6), LZ4, zstd (1, 3, 9). Layouts: raw BF16
bytes, and byte planes split (high bytes = sign+exponent, low bytes = mantissa). Plus FP8 KV.
Granularity: one vLLM-style block = 16 tokens x all layers (K and V), and whole request.
"""

import json
import math
import sys
import time
import zlib
from collections import Counter

import lz4.frame
import numpy as np
import torch
import zstandard as zstd

sys.path.insert(0, "/repo")
from bench.classify.dataset import load  # noqa: E402
from bench.classify.prompt import SYSTEM_PROMPT, user_message  # noqa: E402
from transformers import AutoModelForCausalLM, AutoTokenizer  # noqa: E402

torch.manual_seed(0)
MODEL_DIR, GGUF = "/kv/model", "qwen2.5-1.5b-f16.gguf"
BLOCK_TOKENS = 16

t0 = time.perf_counter()
tok = AutoTokenizer.from_pretrained(MODEL_DIR, gguf_file=GGUF)
model = AutoModelForCausalLM.from_pretrained(MODEL_DIR, gguf_file=GGUF, dtype=torch.bfloat16)
model.eval()
cfg = model.config
head_dim = getattr(cfg, "head_dim", None) or cfg.hidden_size // cfg.num_attention_heads
kv_bytes_per_token = cfg.num_hidden_layers * cfg.num_key_value_heads * head_dim * 2 * 2
print(f"loaded in {time.perf_counter()-t0:.0f}s: layers={cfg.num_hidden_layers} "
      f"kv_heads={cfg.num_key_value_heads} head_dim={head_dim} "
      f"KV bytes/token={kv_bytes_per_token} ({kv_bytes_per_token/1024:.0f} KiB)", flush=True)


def kv_of(text: str) -> tuple[torch.Tensor, torch.Tensor, int]:
    """Run prefill; return K and V as [tokens, layers, kv_heads, head_dim] BF16 tensors."""
    ids = tok(text, return_tensors="pt").input_ids
    with torch.no_grad():
        out = model(ids, use_cache=True)
    cache = out.past_key_values
    if hasattr(cache, "layers"):
        ks = [layer.keys for layer in cache.layers]
        vs = [layer.values for layer in cache.layers]
    else:
        ks, vs = cache.key_cache, cache.value_cache
    # each: [batch=1, kv_heads, tokens, head_dim] -> [tokens, layers, kv_heads, head_dim]
    k = torch.stack([x[0].permute(1, 0, 2) for x in ks], dim=1).contiguous()
    v = torch.stack([x[0].permute(1, 0, 2) for x in vs], dim=1).contiguous()
    return k.to(torch.bfloat16), v.to(torch.bfloat16), ids.shape[1]


def chat(user: str) -> str:
    return tok.apply_chat_template(
        [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}],
        tokenize=False, add_generation_prompt=True)


examples = load()
# Workload A: each classification request on its own.
A_k, A_v, A_tokens = [], [], []
t0 = time.perf_counter()
for e in examples:
    k, v, n = kv_of(chat(user_message(e.input)))
    A_k.append(k); A_v.append(v); A_tokens.append(n)
print(f"workload A: {len(examples)} requests, {sum(A_tokens)} tokens "
      f"(min {min(A_tokens)}, max {max(A_tokens)}) in {time.perf_counter()-t0:.0f}s", flush=True)
# Workload B: one long agent-style transcript (system prompt once, then every failure + answer).
msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
for e in examples:
    msgs += [{"role": "user", "content": user_message(e.input)}, {"role": "assistant", "content": e.label}]
t0 = time.perf_counter()
B_k, B_v, B_tokens = kv_of(tok.apply_chat_template(msgs, tokenize=False))
print(f"workload B: 1 transcript, {B_tokens} tokens in {time.perf_counter()-t0:.0f}s", flush=True)


def as_u16(t: torch.Tensor) -> np.ndarray:
    return t.view(torch.int16).numpy().view(np.uint16).ravel()


def split_planes(u16: np.ndarray) -> bytes:
    """High bytes (sign + 7 exponent bits) first, then low bytes (1 exponent bit + mantissa)."""
    return (u16 >> 8).astype(np.uint8).tobytes() + (u16 & 0xFF).astype(np.uint8).tobytes()


def entropy_bits(b: bytes) -> float:
    c = Counter(b); n = len(b)
    return -sum(x / n * math.log2(x / n) for x in c.values())


def blocks_of(k: torch.Tensor, v: torch.Tensor):
    """vLLM-style blocks: 16 tokens, all layers, K then V."""
    for s in range(0, k.shape[0], BLOCK_TOKENS):
        yield k[s:s + BLOCK_TOKENS], v[s:s + BLOCK_TOKENS]


CODECS = {
    "deflate-1": (lambda b: zlib.compress(b, 1), zlib.decompress),
    "deflate-6": (lambda b: zlib.compress(b, 6), zlib.decompress),
    "lz4": (lz4.frame.compress, lz4.frame.decompress),
    "zstd-1": (zstd.ZstdCompressor(level=1).compress, zstd.ZstdDecompressor().decompress),
    "zstd-3": (zstd.ZstdCompressor(level=3).compress, zstd.ZstdDecompressor().decompress),
    "zstd-9": (zstd.ZstdCompressor(level=9).compress, zstd.ZstdDecompressor().decompress),
}


def measure(chunks: list[bytes]) -> dict:
    total = sum(len(c) for c in chunks)
    res = {}
    for name, (comp, decomp) in CODECS.items():
        t = time.perf_counter(); out = [comp(c) for c in chunks]; ct = time.perf_counter() - t
        t = time.perf_counter(); [decomp(o) for o in out]; dt = time.perf_counter() - t
        csize = sum(len(o) for o in out)
        res[name] = {"ratio": round(total / csize, 3), "space_saved_pct": round(100 * (1 - csize / total), 1),
                     "compress_MBps_1core": round(total / ct / 1e6, 1),
                     "decompress_MBps_1core": round(total / dt / 1e6, 1)}
    return {"bytes": total, "codecs": res}


results = {"model": "Qwen2.5-1.5B-Instruct (GGUF F16 -> BF16)", "kv_bytes_per_token": kv_bytes_per_token,
           "block_tokens": BLOCK_TOKENS, "workload_A_tokens": sum(A_tokens), "workload_B_tokens": B_tokens,
           "cpu": open("/proc/cpuinfo").read().split("model name")[1].split("\n")[0].strip(": "),
           "threads_for_codecs": 1}

for wl, ks, vs in (("A_requests", A_k, A_v), ("B_transcript", [B_k], [B_v])):
    raw_blocks, split_blocks, fp8_blocks, raw_whole = [], [], [], []
    for k, v in zip(ks, vs):
        raw_whole.append(as_u16(k).tobytes() + as_u16(v).tobytes())
        for kb, vb in blocks_of(k, v):
            u = np.concatenate([as_u16(kb), as_u16(vb)])
            raw_blocks.append(u.tobytes()); split_blocks.append(split_planes(u))
            f8 = torch.cat([kb.reshape(-1), vb.reshape(-1)]).to(torch.float8_e4m3fn)
            fp8_blocks.append(f8.view(torch.uint8).numpy().tobytes())
    allraw = b"".join(raw_blocks)
    u = np.frombuffer(allraw, dtype=np.uint16)
    results[wl] = {
        "entropy_bits_per_byte": {"high_bytes_sign_exponent": round(entropy_bits((u >> 8).astype(np.uint8).tobytes()), 2),
                                  "low_bytes_mantissa": round(entropy_bits((u & 0xFF).astype(np.uint8).tobytes()), 2)},
        "bf16_raw_per_block": measure(raw_blocks),
        "bf16_byteplanes_per_block": measure(split_blocks),
        "bf16_raw_whole_request": measure(raw_whole),
        "fp8_e4m3_per_block": measure(fp8_blocks),
    }
    # K and V separately (keys are stored after rotary position encoding)
    kb_all = b"".join(split_planes(as_u16(k)) for k in ks)
    vb_all = b"".join(split_planes(as_u16(v)) for v in vs)
    z = zstd.ZstdCompressor(level=3)
    results[wl]["zstd3_byteplanes_K_vs_V_ratio"] = {"K": round(len(kb_all) / len(z.compress(kb_all)), 3),
                                                     "V": round(len(vb_all) / len(z.compress(vb_all)), 3)}
    print(f"done {wl}", flush=True)

json.dump(results, open("/kv/results/kv_compress.json", "w"), indent=2)
print(json.dumps(results, indent=1))

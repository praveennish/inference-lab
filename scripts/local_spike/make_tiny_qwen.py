"""Build a tiny, randomly initialised Qwen2-architecture model with the REAL Qwen2 tokenizer.

For the local rehearsal of images/spike/spike.sh only: Hugging Face is unreachable from the
build sandbox, so the rehearsal needs a model it can create offline. The tokenizer comes from
llama.cpp's `models/ggml-vocab-qwen2.gguf` (vocabulary, merges, special tokens), so llama.cpp's
converter recognises it exactly as it recognises Qwen2.5, and vLLM loads it through the same
Qwen2 code path. The weights are random: accuracy from this model means nothing.

  python make_tiny_qwen.py <llama.cpp checkout> <output dir>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

LLAMA = Path(sys.argv[1])
OUT = Path(sys.argv[2])
sys.path.insert(0, str(LLAMA / "gguf-py"))

import torch  # noqa: E402
from gguf import GGUFReader  # noqa: E402
from transformers import Qwen2Config, Qwen2ForCausalLM  # noqa: E402

QWEN2_SPLIT = (
    r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*"
    r"|\s*[\r\n]+|\s+(?!\S)|\s+"
)
CHATML = (
    "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content']"
    " + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}"
    "{{ '<|im_start|>assistant\n' }}{% endif %}"
)


def main() -> None:
    reader = GGUFReader(str(LLAMA / "models" / "ggml-vocab-qwen2.gguf"))
    f_tok = reader.fields["tokenizer.ggml.tokens"]
    tokens = [bytes(f_tok.parts[i]).decode("utf-8") for i in f_tok.data]
    f_type = reader.fields["tokenizer.ggml.token_type"]
    types = [int(f_type.parts[i][0]) for i in f_type.data]
    f_mrg = reader.fields["tokenizer.ggml.merges"]
    merges = [bytes(f_mrg.parts[i]).decode("utf-8") for i in f_mrg.data]
    control = [(i, t) for i, (t, ty) in enumerate(zip(tokens, types, strict=True)) if ty == 3]
    vocab = {t: i for i, (t, ty) in enumerate(zip(tokens, types, strict=True)) if ty == 1}
    ids = {t: i for i, t in control}
    print(
        f"tokens {len(tokens)}, normal {len(vocab)}, control {len(control)}, merges {len(merges)}"
    )

    OUT.mkdir(parents=True, exist_ok=True)
    byte_level = {
        "type": "ByteLevel",
        "add_prefix_space": False,
        "trim_offsets": False,
        "use_regex": False,
    }
    tokenizer = {
        "version": "1.0",
        "truncation": None,
        "padding": None,
        "added_tokens": [
            {
                "id": i,
                "content": t,
                "single_word": False,
                "lstrip": False,
                "rstrip": False,
                "normalized": False,
                "special": True,
            }
            for i, t in control
        ],
        "normalizer": {"type": "NFC"},
        "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
                {
                    "type": "Split",
                    "pattern": {"Regex": QWEN2_SPLIT},
                    "behavior": "Isolated",
                    "invert": False,
                },
                byte_level,
            ],
        },
        "post_processor": byte_level,
        "decoder": byte_level,
        "model": {
            "type": "BPE",
            "dropout": None,
            "unk_token": None,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": False,
            "byte_fallback": False,
            "ignore_merges": False,
            "vocab": vocab,
            "merges": merges,
        },
    }
    (OUT / "tokenizer.json").write_text(json.dumps(tokenizer, ensure_ascii=False))
    (OUT / "vocab.json").write_text(json.dumps(vocab, ensure_ascii=False))
    (OUT / "merges.txt").write_text("#version: 0.2\n" + "\n".join(merges) + "\n")
    (OUT / "tokenizer_config.json").write_text(
        json.dumps(
            {
                "tokenizer_class": "Qwen2Tokenizer",
                "model_max_length": 4096,
                "bos_token": None,
                "eos_token": "<|im_end|>",
                "pad_token": "<|endoftext|>",
                "unk_token": None,
                "chat_template": CHATML,
                "added_tokens_decoder": {
                    str(i): {
                        "content": t,
                        "lstrip": False,
                        "normalized": False,
                        "rstrip": False,
                        "single_word": False,
                        "special": True,
                    }
                    for i, t in control
                },
            },
            ensure_ascii=False,
        )
    )

    # Same family and head size as Qwen2.5-1.5B (head_dim 128, grouped KV), far fewer layers.
    config = Qwen2Config(
        vocab_size=len(tokens),
        hidden_size=256,
        intermediate_size=512,
        num_hidden_layers=2,
        num_attention_heads=2,
        num_key_value_heads=1,
        max_position_embeddings=4096,
        rope_theta=1_000_000.0,
        rms_norm_eps=1e-6,
        tie_word_embeddings=True,
        bos_token_id=ids["<|endoftext|>"],
        eos_token_id=ids["<|im_end|>"],
        torch_dtype="bfloat16",
    )
    torch.manual_seed(0)
    Qwen2ForCausalLM(config).to(torch.bfloat16).save_pretrained(OUT, safe_serialization=True)
    (OUT / "generation_config.json").write_text(
        json.dumps(
            {
                "bos_token_id": ids["<|endoftext|>"],
                "eos_token_id": [ids["<|im_end|>"], ids["<|endoftext|>"]],
                "do_sample": False,
            }
        )
    )
    print("wrote", sorted(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main()

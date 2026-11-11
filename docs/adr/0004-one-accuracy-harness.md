# 0004: One accuracy harness, one frozen prompt, every backend

- **Status:** accepted
- **Date:** 2026-11-11

## Context

Accuracy must sit next to speed, and the comparison is only fair if every model sees the same
input. Claude and the open models are reached through different APIs; the rules are code.

## Decision

`bench/classify` runs every backend over `data/classification.jsonl` and writes
`predictions.jsonl` (every raw output kept) and `summary.json` (with dataset SHA-256, source
commit, prompt version, client host, backend configuration). Backends:

- `rules`: pipeline-triage-agent's real classifier, imported from a checkout at a recorded commit.
- `anthropic`: Claude Opus 5.5 and Sonnet 5.5. Effort `low` (set explicitly; Opus 5.5 defaults
  to `medium` and cannot turn thinking off). Structured output restricts the answer to the four
  classes. No temperature: these models reject sampling parameters. **No server-side fallback:**
  a refusal must be recorded as a refusal, not answered by a different model.
- `openai`: any `/v1/chat/completions` server (vLLM, llama.cpp), temperature 0, seed 1234,
  `max_tokens` 16. Free-text output is parsed strictly; an unparseable answer counts as wrong.
  An optional constrained mode (vLLM structured outputs, `choice`) is reported as its own row.

The system prompt was written from the class definitions in pipeline-triage-agent before any
model output was seen, and is frozen (`PROMPT_VERSION` is tested). Reports show accuracy,
macro-F1, per-class recall and invalid outputs, because the classes are imbalanced (always
predicting `user_input_error` scores 0.31).

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Tune the prompt per model | Measures prompt engineering, not hardware or model; overfits 65 examples |
| Few-shot examples from the dataset | Leaks test data into the prompt |
| Accuracy only | Hides a model that never predicts a minority class |

## Consequences

Claude gets structured output and the open models get free text by default, which favours
Claude slightly; the constrained vLLM row shows how much of any gap is formatting. Latency
measured here is per-request at concurrency 1 and is not the performance benchmark.

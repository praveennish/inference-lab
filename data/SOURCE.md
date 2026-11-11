# Dataset provenance

`classification.jsonl` is a byte-for-byte copy. **Never edit it here**; change it upstream and
copy it again, recording the new commit below.

| Field | Value |
|---|---|
| Source repository | `praveennish/pipeline-triage-agent` |
| Source path | `evals/datasets/classification.jsonl` |
| Source branch | `feat/scaffold` |
| Source commit | `ac5bb27b912fb840be03b5e56f860b507ee21808` |
| Copied on | 2026-11-11 |
| SHA-256 | `4b4277b7b45acffe9417059abaa7fa5b53d5722868d30c4881a5586745805360` |
| Rows | 65 (user_input_error 20, cloud_outage 18, unsupported_transformation 15, unknown 12) |

Format: one JSON object per line, `{"id", "input", "label"}`; labels are `cloud_outage`,
`user_input_error`, `unsupported_transformation`, `unknown`. `make check` verifies the SHA-256,
so an accidental edit fails CI.

Class balance matters when reading accuracy: always predicting `user_input_error` scores 20/65
(0.31). Reports therefore include per-class recall and macro-F1, not accuracy alone.

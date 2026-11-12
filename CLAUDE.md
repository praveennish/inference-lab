# CLAUDE.md

Instructions for Claude Code working in this repository.

## What this project is

One question, measured: **which hardware and runtime should serve the cheap, high-volume step of
an AI agent, and at what latency, throughput, cost and accuracy?** The step is the failure
classifier of `praveennish/pipeline-triage-agent`. Headline comparison: Arm Graviton vs x86 CPU
at equal instance cost; GPU only as a reference if the quota allows. Method matters more than
model size.

## Invariants

1. **Never invent numbers.** Every number in a report is computed from a raw result file under
   `build/results/` (and its copy in S3). If a run failed, say so.
2. **Fair comparison.** Same model revision and dtype on every backend; thread counts set and
   recorded; warm-up discarded; at least 3 repetitions per cell; median and spread.
3. **Accuracy next to speed.** Every backend is scored on `data/classification.jsonl` with the
   one frozen prompt in `bench/classify/prompt.py`. Changing the prompt changes
   `PROMPT_VERSION`; never compare results across versions in one table.
4. **Never edit `data/classification.jsonl`.** It is a copy; provenance in `data/SOURCE.md`.
5. **Compute dies every night.** `make spike-down` (later `make destroy`) and `make leftovers`
   before the day ends. Show resources and estimated hourly cost before every apply; wait for
   the owner's yes.
6. **Credentials:** AWS profile `inference-lab` (credential_process), never exported keys.
   Secrets only from Secrets Manager. Never ask for secrets in chat.

## Fixed facts about the account (do not rediscover)

- Region `ap-southeast-2` only; AWS Free plan, no payment method. Bedrock Anthropic models are
  unavailable. An SCP blocks IAM OIDC providers, so deploys run from the Codespace.
- Terraform state: pipeline-triage-agent's bucket `triage-tfstate-<account>-ap-southeast-2`,
  keys under `inference-lab/`, `use_lockfile = true`. Every role carries
  `inference-lab-workload-boundary`; everything is tagged `project = inference-lab`.
- The Anthropic key is the secret `triage/anthropic-api-key`.

## Commands

```bash
make install          # uv sync
make check            # ruff, pytest, terraform fmt
make account-checks   # read-only account report
make baselines        # rules + Claude on the dataset (no AWS compute)
make bootstrap        # boundary + artifacts bucket (long-lived, cents/month)
make preflight        # everything an apply needs; exit 1 on any failure
make test-aws-local   # the real deploy path against a local AWS emulator (moto); run before make spike
make spike            # preflight, plan, owner's yes, apply, wait, collect, destroy: one summary
```

## Working rules

- Feature branch only; ask before pushing to `main` or opening a pull request.
- Commands for the owner: exact, one per code block, with expected output.
- Small commits with descriptive messages. Log generated work in `docs/ai-sdlc-log.md`.

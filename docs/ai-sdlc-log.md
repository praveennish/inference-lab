# AI in the SDLC: build log

How Claude Code was used to build this repository and what happened to its output. Evidence
for one question: does agentic AI improve delivery speed and quality, and how is its output kept
safe? Each entry is one piece of generated work. *Outcome* is accepted, edited or rejected;
*Caught by* names what found a problem.

## Working setup

- Claude Code (cloud session) with `CLAUDE.md` listing invariants and account facts.
- Feature branch only; the owner approves pushes to `main` and every `terraform apply`.
- Gates: ruff (with security rules), pytest, terraform fmt and validate.

## Entries

| Date | Work | Outcome | Caught by | Notes |
|---|---|---|---|---|
| 2026-11-11 | Read pipeline-triage-agent design doc, dataset README, credentials script | Accepted | — | Found that `main` there holds only an initial commit; the work is on `feat/scaffold` (`ac5bb27`). Dataset copied from that commit with SHA-256 recorded |
| 2026-11-11 | Reviewed vllm-explained-lab for reuse | **Rejected (code)**, accepted (ideas) | Human-style review of licensing | Lab code is third-party course content; not copied. Carried over the owner's own measurement notes (dtype parity, warm-up, TTFT/TPOT split, goodput, open-loop load) into ADR 0001 |
| 2026-11-11 | Accuracy harness (`bench/classify`): rules, Anthropic, OpenAI-compatible backends | Accepted | Tests, ruff | Rules backend reproduces the published baseline exactly: 54/65 (0.83). The 11 misses: 6 `unsupported_transformation` on a generic code, 3 `unknown` called `cloud_outage` by a "timed out" message match, 2 `cloud_outage` on generic codes |
| 2026-11-11 | Anthropic backend parameters | **Edited** | Checking current API docs before writing | First instinct was `temperature=0`; Opus 5.5 and Sonnet 5.5 reject sampling parameters, and Opus 5.5 cannot disable thinking. Used explicit `effort: low` and structured output instead; no server-side fallback so refusals are counted, not hidden |
| 2026-11-11 | ruff findings on the harness | **Edited** | ruff S105, S603/S607 | S105 flagged a secret *name*; annotated with reason rather than disabling the rule |
| 2026-11-11 | Terraform bootstrap and spike stacks | Accepted | terraform validate | Validated with providers fetched from HashiCorp's release site (the registry is blocked in the build sandbox). Spike subnets chosen from AZs that offer each instance type, so an AZ without c8g cannot fail the apply |
| 2026-11-12 | Backend tests against fake servers (Anthropic SDK over httpx2 MockTransport; OpenAI-compatible over httpx MockTransport) | Accepted | Tests | Proves the request we send (no sampling params, no fallbacks, effort and schema set; greedy, seeded, same prompt) and how replies, refusals and HTTP errors are read. Server-side acceptance is still unproven until the live baseline |
| 2026-11-12 | Spike script review before first AWS run | **Edited** | shellcheck; line-by-line review | Two real bugs fixed: an array mixed into a string for the vLLM bench fallback (SC2145), and a `grep \| head` under `pipefail` that would have marked a successful llama.cpp build as failed when no flag line matched. KV cache cut from 8 to 4 GiB after computing it (28 KiB/token × 32 × 4096 = 3.5 GiB) to protect a 16 GiB host. Image digest now recorded |
| 2026-11-12 | `make preflight`, `make spike` (one command, destroy on every exit) | Accepted | shellcheck, rendered user-data `bash -n`, rehearsal from an unpacked bundle against a fake server | A refused EKS cluster no longer strands the instances: apply errors are recorded, the hosts are still waited for, and destroy always runs |
| 2026-11-12 | Local AWS emulator test (`make test-aws-local`, moto) | Accepted after 5 iterations | Running it | First run: 15/32. **Product bug found:** preflight matched tab-separated `--output text` against spaces, so the instance-offering check would always fail on real AWS and block `make spike`; fixed. Harness issues fixed along the way: S3 Control's account-prefixed hostname (forwarding proxy), AWS-managed policies not loaded by default, fake hosts finishing before the apply, a bundle check run after destroy had deleted the bundle, a grep matching the archive header. Also confirmed the resilience path: a partial apply still waited for hosts and destroyed everything. Final: 32/32 (ADR 0006) |
| 2026-11-12 | Summary formatting | **Edited** | Reading the generated summary | An EKS error message broke the summary line across two lines; flattened |
| 2026-11-11 | Reuse of the triage permissions boundary | **Edited** | Reading the boundary policy | The prompt said reuse it; it lacks EC2/EKS/SSM/ECR actions, so nodes could not join a cluster. Created a separate boundary with the same pattern (ADR 0005) |

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
| 2026-11-11 | Reuse of the triage permissions boundary | **Edited** | Reading the boundary policy | The prompt said reuse it; it lacks EC2/EKS/SSM/ECR actions, so nodes could not join a cluster. Created a separate boundary with the same pattern (ADR 0005) |

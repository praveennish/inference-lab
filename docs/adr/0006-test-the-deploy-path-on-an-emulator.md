# 0006: Test the deploy path on a local AWS emulator before spending

- **Status:** accepted
- **Date:** 2026-11-12

## Context

Every apply costs Free-plan credit and an owner round trip, and Claude Code has no AWS access
of its own. Scripts that only passed `bash -n`, shellcheck and `terraform validate` had never
talked to an AWS API. The first emulator run found a bug that would have blocked the real run
(below), so "validated" was not "works".

## Decision

`make test-aws-local` runs the **real** Makefile, `preflight.sh`, both Terraform stacks and
`run_spike.sh` against **moto** in server mode, and checks 32 properties: approval prompt, what is
created (types, tags, IMDSv2, terminate-on-shutdown, rendered user-data, boundary on every role,
commit stamp, bundle contents), the summary file, destroy on every exit, a hung-host deadline,
and that bootstrap resources survive. The hosts are simulated: a fake host uploads results and
terminates its instance. Nothing in the product changes for the test except three explicit
environment hooks: `PREFLIGHT_EMULATOR_GAPS`, `SPIKE_POLL_SECONDS`, `SPIKE_GRACE_MINUTES`.
Terraform reaches the emulator through generated `*_override.tf` files and a separate
`TF_DATA_DIR`, both removed on exit.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| LocalStack Community | EKS emulation is in the paid edition; needs a Docker daemon (absent in the build sandbox) |
| Only `terraform validate` and shellcheck | Already passed while preflight had a real bug |
| A separate cheap AWS run per change | Costs credit and an owner round trip per iteration |

## Consequences

Found and fixed before any spend: preflight compared tab-separated CLI output against
space-separated text, so the instance-offering check would always have failed on real AWS and
blocked `make spike`. Not covered and still proven only by `make spike`: Free-plan limits, the EC2
vCPU quota (not emulated), prices, real EKS readiness, and everything on the hosts. Emulator
quirks handled in the harness, not the product: AWS-managed IAM policies must be loaded, and
account-prefixed S3 Control hostnames go through a small forwarding proxy.

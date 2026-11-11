# 0005: Account guardrails, shared state bucket, own permissions boundary

- **Status:** accepted
- **Date:** 2026-11-11

## Context

Same account as pipeline-triage-agent: Free plan, Sydney only, an SCP that blocks IAM OIDC
providers, short-lived credentials from `aws login`. That repo's bootstrap already created a
Terraform state bucket and a permissions boundary. Its boundary allows Lambda-era services
(S3, DynamoDB, SQS, Step Functions) but no EC2 control, EKS, SSM Session Manager or ECR push,
so EC2 nodes could not join a cluster or be reached.

## Decision

- Deploy from the Codespace with profile `inference-lab` (credential_process over
  `triage-admin`), as in pipeline-triage-agent ADR 0009. No exported keys.
- **Reuse** the state bucket with separate keys (`inference-lab/bootstrap.tfstate`,
  `inference-lab/spike.tfstate`, later `inference-lab/cluster.tfstate`), `use_lockfile = true`.
- **Own boundary** `inference-lab-workload-boundary` (path `/inference-lab/`), created by
  `infra/bootstrap`: the services this project needs, allowed in Sydney only, with an explicit
  deny for any other region, PassRole only for `/inference-lab/` roles, and read access to the
  one Anthropic secret. Every role created here carries it.
- Long-lived and near-free resources (boundary, artifacts bucket) live in `infra/bootstrap`;
  everything that costs by the hour lives in stacks destroyed nightly.
- Instances are reached by SSM Session Manager: no SSH keys, no inbound rules. Spike hosts power
  off and terminate themselves after a hard cap, even if nobody runs `make spike-down`.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Reuse the triage boundary unchanged | Lacks the EC2/EKS/SSM/ECR actions; nodes would fail to join |
| Widen the triage boundary | Changes another project's security ceiling for this project's needs |
| No boundary | The deploy identity could create a role more powerful than intended |
| GitHub Actions deploys | Blocked by the SCP on OIDC providers |

## Consequences

One extra small stack to apply once. The boundary is broader than the triage one (EC2 and EKS
are broad services), so the region condition and PassRole scoping carry more of the weight.

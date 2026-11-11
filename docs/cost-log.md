# Cost log

Every apply is listed with its resources, the estimated hourly cost shown before approval, and
the measured cost afterwards (Billing → Bills, or Cost Explorer, filtered to `project =
inference-lab` once the tag is activated as a cost allocation tag).

Prices marked *estimate* come from US-East on-demand rates scaled for Sydney and are **not
verified**; the Pricing API is not reachable from a Sydney-locked account. Replace them with the
console's Sydney prices (EC2 → Instance types, or the AWS Pricing Calculator) before using them
in any per-dollar result.

## Remaining credit

| Date | Remaining credit | Source |
|---|---|---|
| 2026-11-11 | to be read by `make account-checks` or Billing → Credits | |

## Applies

| Date | Stack | Resources | Estimated USD/hour | Planned hours | Approved | Measured USD |
|---|---|---|---|---|---|---|
| 2026-11-11 | bootstrap | IAM policy, S3 bucket | ~0 (storage cents/month) | long-lived | pending | |
| 2026-11-11 | spike | c8g.2xlarge, c7i.2xlarge, 2 × 80 GB gp3, 2 public IPv4, EKS control plane | ~1.00 (*estimate*: c8g ~0.40, c7i ~0.45, EKS 0.10, EBS+IPv4 ~0.03) | ≤ 2.5 (hard cap) | pending | |

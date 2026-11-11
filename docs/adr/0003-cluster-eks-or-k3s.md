# 0003: Kubernetes: EKS if the Free plan allows it, k3s on EC2 otherwise

- **Status:** proposed; decided by the Day-1 EKS probe
- **Date:** 2026-11-11

## Context

The serving stack runs on Kubernetes: node groups labelled by architecture, one model pod per
benchmark node with Guaranteed QoS and the static CPU manager policy, and a separate system node
for Prometheus and the load generator. The account is on the AWS Free plan, and it is unknown
whether that plan allows EKS. Compute is destroyed nightly, so cluster create and delete time
counts every day.

## Decision

The Day-1 spike stack creates an EKS control plane with no nodes (`infra/spike`,
`eks_probe = true`). If it reaches ACTIVE, Day 2 uses **EKS** with managed node groups
(`c8g.2xlarge`, `c7i.2xlarge`, a small system node, and a tainted GPU group if the quota
allows). If creation is refused, Day 2 uses **k3s on EC2**: one server on the system node and
agents on the benchmark nodes, with the same labels, taints and kubelet CPU-manager settings.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Plain EC2 with systemd, no Kubernetes | Loses the evidence the role asks for: scheduling, QoS, CPU manager, operators |
| kind or minikube on one host | All backends would share one machine, which breaks the one-model-per-node rule |
| ECS | Not Kubernetes; no CPU manager equivalent |

## Consequences

EKS costs a control-plane hourly fee and about 10 to 15 minutes to create each day; k3s is free
and faster but self-managed. The manifests in `deploy/` must not depend on EKS-only features, so
either choice runs the same workloads.

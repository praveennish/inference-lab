#!/usr/bin/env bash
# Preflight before spending: everything that would make an apply fail or overspend.
# Read-only. Exit code 0 only if every check passes. Writes build/results/<time>/preflight.md.
#   source scripts/aws-refresh.sh && make preflight
set -uo pipefail

REGION=ap-southeast-2
SPIKE_TYPES=(c8g.2xlarge c7i.2xlarge)   # must match infra/spike variable "instances"
NEED_VCPU=16
ENABLE_GPU=${ENABLE_GPU:-0}             # 1: also check the GPU host (make spike GPU=1)
GPU_TYPE=g6.xlarge; GPU_VCPU=4           # must match infra/spike gpu_instance_type
# Override if AWS renames it; run_spike passes the same value to Terraform.
GPU_AMI_PARAM=${GPU_AMI_PARAM:-/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id}
OUT_DIR=${OUT_DIR:-"build/results/$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/preflight.md"
FAILED=0
# Only the local emulator test sets this: checks the emulator cannot answer are shown as SKIP.
EMULATOR_GAPS=" ${PREFLIGHT_EMULATOR_GAPS:-} "

check() {  # check <description> <command...>: PASS if the command succeeds
  local desc=$1; shift
  local detail
  if [[ "$EMULATOR_GAPS" == *" $1 "* ]]; then
    printf '| SKIP | %s | not emulated locally; checked on real AWS |\n' "$desc" >>"$OUT"
    return 0
  fi
  if detail=$("$@" 2>&1); then
    printf '| PASS | %s | %s |\n' "$desc" "$(echo "$detail" | tr '\n|' ' /' | cut -c1-140)" >>"$OUT"
  else
    printf '| **FAIL** | %s | %s |\n' "$desc" "$(echo "$detail" | tr '\n|' ' /' | cut -c1-200)" >>"$OUT"
    FAILED=1
  fi
}

no_static_keys() { [ -z "${AWS_ACCESS_KEY_ID:-}" ] || { echo "AWS_ACCESS_KEY_ID is set: unset it (exported credentials freeze)"; return 1; }; }
profile_ok() { [ "${AWS_PROFILE:-}" = inference-lab ] || { echo "AWS_PROFILE=${AWS_PROFILE:-unset}; run: source scripts/aws-refresh.sh"; return 1; }; }
region_ok() { local r; r=$(aws configure get region); [ "$r" = "$REGION" ] && echo "$r" || { echo "region=$r"; return 1; }; }
identity() { aws sts get-caller-identity --query Arn --output text; }
tools() {
  local tf; tf=$(terraform version -json | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])')
  python3 -c "import sys;v=tuple(map(int,'$tf'.split('.')[:2]));sys.exit(0 if v>=(1,10) else 1)" || { echo "terraform $tf < 1.10 (use_lockfile)"; return 1; }
  echo "terraform $tf, $(aws --version 2>&1 | cut -d' ' -f1), $(uv --version)"
}
state_bucket() { aws s3api head-bucket --bucket "triage-tfstate-${ACCOUNT}-${REGION}" && echo "triage-tfstate-${ACCOUNT}-${REGION}"; }
bootstrap_done() {
  aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/inference-lab/inference-lab-workload-boundary" \
    --query Policy.PolicyName --output text || { echo "run: make bootstrap"; return 1; }
  aws s3api head-bucket --bucket "inference-lab-artifacts-${ACCOUNT}-${REGION}" || { echo "run: make bootstrap"; return 1; }
}
secret_ok() { aws secretsmanager describe-secret --secret-id triage/anthropic-api-key --query Name --output text; }
default_vpc() { aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text | grep -v None; }
offered() {  # type is offered in an AZ that has a default subnet
  local t=$1 azs subnets
  # --output text separates values with tabs: normalise to spaces before matching.
  azs=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$t" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ' ')
  subnets=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
    --query 'Subnets[].AvailabilityZone' --output text | tr '\t' ' ')
  for az in $azs; do [[ " $subnets " == *" $az "* ]] && { echo "$t in $az"; return 0; }; done
  echo "$t offered in [$azs], default subnets in [$subnets]"; return 1
}
vcpu_quota() {
  local quota running
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text)
  running=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
    --query 'sum(Reservations[].Instances[].CpuOptions.CoreCount)' --output text 2>/dev/null)
  # CoreCount x threads is the vCPU count; approximate with x2 to stay conservative.
  running=${running:-0}; [ "$running" = None ] && running=0
  python3 -c "import sys;q=float('$quota');r=2*float('$running');print(f'quota {q:.0f}, in use <= {r:.0f}, need {$NEED_VCPU}');sys.exit(0 if q-r>=$NEED_VCPU else 1)"
}
gpu_quota() {  # G and VT on-demand vCPUs; new accounts often have 0
  local q; q=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --query Quota.Value --output text) || return 1
  python3 -c "import sys;q=float('$q');print(f'G and VT quota {q:.0f}, need $GPU_VCPU');sys.exit(0 if q>=$GPU_VCPU else 1)" \
    || { echo "quota too low: run make gpu-quota-request and wait for approval"; return 1; }
}
gpu_ami() {  # the GPU image parameter must resolve in this account and region
  local id; id=$(aws ssm get-parameter --name "$GPU_AMI_PARAM" --query Parameter.Value --output text 2>/dev/null)
  if [ -n "$id" ] && [ "$id" != None ]; then echo "$id from $GPU_AMI_PARAM"; return 0; fi
  echo "parameter $GPU_AMI_PARAM not found; newest Amazon DLAMI base GPU images:"
  aws ec2 describe-images --owners amazon --filters "Name=name,Values=Deep Learning Base*GPU*Amazon Linux 2023*" \
    "Name=architecture,Values=x86_64" --query 'reverse(sort_by(Images,&CreationDate))[:2].[ImageId,Name]' --output text
  aws ssm get-parameters-by-path --path /aws/service/deeplearning/ami/x86_64 --query 'Parameters[].Name' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -i 'amazon-linux-2023' | head -5
  return 1
}
eks_api() { aws eks list-clusters --query 'clusters' --output text; echo "(list allowed; create is proven only by the probe)"; }
nothing_running() {
  local left; left=$(aws ec2 describe-instances --filters Name=tag:project,Values=inference-lab \
    Name=instance-state-name,Values=pending,running,stopping \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -z "$left" ] && echo "none" || { echo "still running: $left (make spike-down)"; return 1; }
}
credit() {  # informative only: the Free plan API may be refused by the region lock
  aws freetier get-account-plan-state --region us-east-1 \
    --query '[accountPlanType,accountPlanStatus,accountPlanRemainingCredits.amount,accountPlanRemainingCredits.unit]' \
    --output text 2>/dev/null || echo "not readable from CLI; check Billing -> Credits"
}

{
  echo "# Preflight $(date -u +%FT%TZ)"
  echo
  echo "| Result | Check | Detail |"
  echo "|---|---|---|"
} >"$OUT"

check "No exported static keys" no_static_keys
check "Profile is inference-lab" profile_ok
check "Region is $REGION" region_ok
check "Credentials work" identity
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
check "terraform >= 1.10, aws, uv" tools
check "Terraform state bucket (from pipeline-triage-agent)" state_bucket
check "Bootstrap applied (boundary, artifacts bucket)" bootstrap_done
check "Anthropic key secret exists" secret_ok
check "Default VPC" default_vpc
for t in "${SPIKE_TYPES[@]}"; do check "$t offered with a default subnet" offered "$t"; done
check "On-demand standard vCPU quota" vcpu_quota
if [ "$ENABLE_GPU" = 1 ]; then
  check "$GPU_TYPE offered with a default subnet" offered "$GPU_TYPE"
  check "GPU (G and VT) vCPU quota >= $GPU_VCPU" gpu_quota
  check "GPU image (Deep Learning Base AMI, AL2023) resolves" gpu_ami
fi
check "EKS API reachable" eks_api
check "No inference-lab instances left running" nothing_running
printf '| INFO | Remaining credit | %s |\n' "$(credit | tr '\n\t' '  ')" >>"$OUT"

echo
cat "$OUT"
if [ "$FAILED" -ne 0 ]; then echo; echo "Preflight FAILED: fix the rows marked FAIL." >&2; exit 1; fi
echo; echo "Preflight passed."

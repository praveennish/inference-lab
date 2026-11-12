#!/usr/bin/env bash
# Day-1 account checks. Read-only: creates nothing, costs nothing.
# Writes build/results/<time>/account-checks.md; paste that one file back.
#   source scripts/aws-refresh.sh && make account-checks
set -uo pipefail

REGION=ap-southeast-2
OUT_DIR="build/results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/account-checks.md"
TYPES="c8g.2xlarge,c7g.2xlarge,c7i.2xlarge,c8i.2xlarge,m8g.2xlarge,m7i.2xlarge,t4g.medium,t3.medium,g6.xlarge,g5.xlarge,g4dn.xlarge"

section() { printf '\n## %s\n\n```\n' "$1" >>"$OUT"; }
run() { printf '$ %s\n' "$*" >>"$OUT"; "$@" >>"$OUT" 2>&1 || echo "[exit $?]" >>"$OUT"; }
end() { printf '```\n' >>"$OUT"; }

{
  echo "# Account checks"
  echo
  echo "- Time (UTC): $(date -u +%FT%TZ)"
  echo "- AWS_PROFILE: ${AWS_PROFILE:-unset}"
  echo "- Static keys in env: $([ -n "${AWS_ACCESS_KEY_ID:-}" ] && echo 'YES (unset them: they freeze)' || echo no)"
} >"$OUT"

section "Identity and region"
run aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
run aws configure get region
end

section "Free plan state and remaining credit (may be refused by the region lock; then read Billing -> Credits in the console)"
run aws freetier get-account-plan-state --region us-east-1 --output json
run aws freetier get-account-plan-state --region "$REGION" --output json
end

section "Instance offerings per availability zone"
run aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
  --filters "Name=instance-type,Values=$TYPES" \
  --query 'sort_by(InstanceTypeOfferings,&InstanceType)[].[InstanceType,Location]' --output text
end

section "Instance details (vCPU, threads per core, memory, architecture)"
# shellcheck disable=SC2046 # the list is split into arguments on purpose
run aws ec2 describe-instance-types --region "$REGION" \
  --instance-types $(echo "$TYPES" | tr ',' ' ') \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,VCpuInfo.DefaultCores,VCpuInfo.DefaultThreadsPerCore,MemoryInfo.SizeInMiB,ProcessorInfo.SupportedArchitectures[0],ProcessorInfo.Manufacturer]' \
  --output text
end

section "vCPU quotas: on-demand standard (L-1216C47A), G and VT (L-DB2E81BA)"
run aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.[QuotaName,Value]' --output text
run aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-DB2E81BA \
  --query 'Quota.[QuotaName,Value]' --output text
run aws service-quotas list-requested-service-quota-change-history --region "$REGION" --service-code ec2 \
  --query 'RequestedQuotas[].[QuotaCode,DesiredValue,Status,Created]' --output text
end

section "EKS (read-only: listing works does not prove create works; see make eks-probe)"
run aws eks list-clusters --region "$REGION"
run aws eks describe-addon-versions --region "$REGION" --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].compatibilities[0].clusterVersion' --output text
end

section "Default VPC and subnets"
run aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
  --query 'Vpcs[].[VpcId,CidrBlock]' --output text
run aws ec2 describe-subnets --region "$REGION" --filters Name=default-for-az,Values=true \
  --query 'Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch]' --output text
end

section "Reused from pipeline-triage-agent: state bucket, boundary, secret, budgets"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
run aws s3api head-bucket --bucket "triage-tfstate-${ACCOUNT}-${REGION}"
run aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/triage/triage-workload-boundary" \
  --query 'Policy.[PolicyName,DefaultVersionId]' --output text
run aws secretsmanager describe-secret --region "$REGION" --secret-id triage/anthropic-api-key \
  --query '[Name,LastChangedDate]' --output text
run aws budgets describe-budgets --account-id "$ACCOUNT" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text
end

section "Anything left running (should be empty before and after each day)"
run aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`project`]|[0].Value]' --output text
end

echo "Wrote $OUT"

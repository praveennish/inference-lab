#!/usr/bin/env bash
# Show, or request, the EC2 "Running On-Demand G and VT instances" vCPU quota (L-DB2E81BA).
#   make gpu-quota            show the current value and any open requests (read-only)
#   make gpu-quota-request    request 4 vCPUs (one g6.xlarge) if below 4 and nothing is pending
# A request is free; AWS decides, which can take hours to days, and may refuse a Free-plan account.
set -uo pipefail
REGION=ap-southeast-2
CODE=L-DB2E81BA
WANT=${GPU_VCPU:-4}

current=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 \
  --quota-code "$CODE" --query Quota.Value --output text) || { echo "could not read the quota"; exit 1; }
echo "G and VT on-demand vCPU quota in $REGION: $current (need $WANT for one g6.xlarge)"
open=$(aws service-quotas list-requested-service-quota-change-history-by-quota --region "$REGION" \
  --service-code ec2 --quota-code "$CODE" \
  --query 'RequestedQuotas[?Status==`PENDING` || Status==`CASE_OPENED`].[Id,DesiredValue,Status,Created]' \
  --output text)
[ -n "$open" ] && { echo "Open request(s):"; echo "$open"; }

[ "${1:-}" = request ] || exit 0
if python3 -c "import sys;sys.exit(0 if float('$current')>=$WANT else 1)"; then
  echo "Quota already >= $WANT; nothing to request."; exit 0
fi
[ -n "$open" ] && { echo "A request is already open; not filing another."; exit 0; }
aws service-quotas request-service-quota-increase --region "$REGION" --service-code ec2 \
  --quota-code "$CODE" --desired-value "$WANT" \
  --query 'RequestedQuota.[Id,QuotaName,DesiredValue,Status]' --output text
echo "Filed. Check progress with: make gpu-quota"

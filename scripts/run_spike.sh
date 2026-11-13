#!/usr/bin/env bash
# One command, one results file: preflight -> plan -> (your yes) -> apply -> wait -> collect ->
# destroy. Destroy runs on every exit after the apply starts, including failures and Ctrl-C.
#   source scripts/aws-refresh.sh && make spike
# Paste back: build/results/spike-<run>/summary.md
set -uo pipefail

tf() { terraform -chdir=infra/spike "$@"; }
tfb() { terraform -chdir=infra/bootstrap "$@"; }
REGION=ap-southeast-2
MAX_MINUTES=${MAX_MINUTES:-150}
POLL_SECONDS=${SPIKE_POLL_SECONDS:-120}     # the local emulator test shortens these two
GRACE_MINUTES=${SPIKE_GRACE_MINUTES:-10}
ENABLE_GPU=${ENABLE_GPU:-0}                 # make spike GPU=1 adds the g6.xlarge host
LABELS=(graviton x86); GPU_TF=false
if [ "$ENABLE_GPU" = 1 ]; then LABELS+=(gpu); GPU_TF=true; fi
export ENABLE_GPU                           # preflight checks the GPU quota and image too

mkdir -p build
RUN=$(date -u +%Y%m%dT%H%M%SZ)
echo "$RUN" > build/spike_run_id
RES="build/results/spike-$RUN"
mkdir -p "$RES"
LOG="$RES/run.log"
exec > >(tee -a "$LOG") 2>&1

# Every result carries the commit it was produced from (the hosts get a zip, not a clone).
{ git rev-parse HEAD; [ -n "$(git status --porcelain)" ] && echo "dirty"; } | paste -sd' ' > .bundle-commit
echo "Run $RUN from commit $(cat .bundle-commit)"

# ------------------------------------------------------------------ preflight
OUT_DIR="$RES" ./scripts/preflight.sh || exit 1

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="triage-tfstate-${ACCOUNT}-${REGION}"
tfb init -input=false -reconfigure -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="region=$REGION" >/dev/null
BOUNDARY=$(tfb output -raw boundary_arn)
BUCKET=$(tfb output -raw artifacts_bucket)
VARS=(-var="boundary_arn=$BOUNDARY" -var="artifacts_bucket=$BUCKET" -var="run_id=$RUN"
      -var="max_minutes=$MAX_MINUTES" -var="enable_gpu=$GPU_TF")
[ -n "${GPU_AMI_PARAM:-}" ] && VARS+=(-var="gpu_ami_parameter=$GPU_AMI_PARAM")

# ------------------------------------------------------------------ plan and approval
tf init -input=false -reconfigure -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="region=$REGION" >/dev/null || exit 1
tf plan -input=false "${VARS[@]}" -out=spike.tfplan > "$RES/plan.txt" || { cat "$RES/plan.txt"; exit 1; }
echo
echo "Resources to create:"
grep -E '^  # .* will be created' "$RES/plan.txt" | sed 's/^  # /  /; s/ will be created//'
grep -E '^Plan:' "$RES/plan.txt"
HOURLY=1.0
echo
echo "Estimated cost (on-demand, Sydney; ESTIMATES, check the EC2 console):"
echo '  c8g.2xlarge ~$0.40/h, c7i.2xlarge ~$0.45/h, EKS control plane $0.10/h,'
echo '  2 x 80 GB gp3 + 2 public IPv4 ~$0.03/h  =>  ~$1.00/h.'
if [ "$ENABLE_GPU" = 1 ]; then
  HOURLY=2.1
  echo '  GPU host: g6.xlarge ~$1.05/h + 150 GB gp3 and IPv4 ~$0.03/h  =>  total ~$2.10/h.'
fi
echo "  Hosts terminate themselves after at most $MAX_MINUTES minutes; this script then destroys"
echo "  everything, EKS probe included. Worst case ~\$$(python3 -c "print(round($MAX_MINUTES/60*$HOURLY+0.2,2))")."
echo
read -r -p "Apply, run the spike, then destroy everything? Type yes: " answer
[ "$answer" = yes ] || { echo "Not applied."; exit 0; }

# ------------------------------------------------------------------ apply (destroy on any exit)
destroy() {
  echo; echo "=== Destroying spike stack"
  tf destroy -input=false -auto-approve "${VARS[@]}" > "$RES/destroy.txt" 2>&1 \
    && echo "Destroyed." || { echo "DESTROY FAILED: see $RES/destroy.txt and run make spike-down"; }
  {
    echo; echo "## Left running after destroy"; echo; echo '```'
    aws ec2 describe-instances --filters Name=tag:project,Values=inference-lab \
      Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text
    aws eks list-clusters --query clusters --output text
    echo '```'
  } >> "$RES/summary.md"
  echo "Paste back: $RES/summary.md"
}
trap destroy EXIT

START=$(date +%s)
if tf apply -input=false spike.tfplan > "$RES/apply.txt" 2>&1; then
  APPLY=ok
else
  # A refused EKS cluster must not strand the instances: record it and carry on.
  APPLY=failed
  echo "Apply reported errors (see apply.txt):"; grep -E 'Error' "$RES/apply.txt" | head -5
fi
tf output -json > "$RES/outputs.json" 2>/dev/null

# ------------------------------------------------------------------ wait for the hosts
ids=$(aws ec2 describe-instances --filters "Name=tag:stack,Values=spike" \
  "Name=instance-state-name,Values=pending,running" --query 'Reservations[].Instances[].InstanceId' --output text)
echo "Hosts: ${ids:-none}"
deadline=$((START + (MAX_MINUTES + GRACE_MINUTES) * 60))
while [ -n "$ids" ] && [ "$(date +%s)" -lt "$deadline" ]; do
  live=$(aws ec2 describe-instances --instance-ids $ids \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text)
  [ -z "$live" ] && break
  for l in "${LABELS[@]}"; do
    last=$(aws s3 cp --quiet "s3://$BUCKET/spike/$RUN/$l/steps.tsv" - 2>/dev/null | tail -1 | cut -f1,2)
    printf '%s %-8s %s\n' "$(date -u +%H:%M)" "$l" "${last:-starting}"
  done
  sleep "$POLL_SECONDS"
done
[ -n "${live:-}" ] && echo "Deadline reached with hosts still alive: $live (destroy will remove them)"

# ------------------------------------------------------------------ collect
aws s3 sync --quiet "s3://$BUCKET/spike/$RUN/" "$RES/" --exclude bundle.zip
EKS=$(aws eks describe-cluster --name inference-lab-probe --query 'cluster.[status,version,platformVersion]' --output text 2>&1 | tr '\n\t' '  ')
{
  echo "# Spike $RUN"
  echo
  echo "- Commit: \`$(cat .bundle-commit)\`"
  echo "- Apply: $APPLY; wall time $(( ($(date +%s) - START) / 60 )) min"
  echo "- EKS probe (control plane only): $EKS"
  grep -E 'Error' "$RES/apply.txt" | head -5 | sed 's/^/- Apply error: /'
  echo
  sed -n '/^| Result/,$p' "$RES/preflight.md"
  echo
  for l in "${LABELS[@]}"; do
    if [ -f "$RES/$l/spike-summary.md" ]; then cat "$RES/$l/spike-summary.md"
    else echo "## $l: no spike-summary.md (see $RES/$l/spike.log)"; fi
    echo
  done
} > "$RES/summary.md"

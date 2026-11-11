#!/usr/bin/env bash
# Set up AWS credentials for this shell. Usage:
#   source scripts/aws-refresh.sh
#
# Copied from pipeline-triage-agent. `aws login` issues ~15-minute credentials and refreshes
# them in the background. Exported credentials freeze, so a long run fails halfway. Profile
# "inference-lab" uses credential_process instead: boto3 and Terraform ask the AWS CLI for
# fresh credentials whenever the old ones expire, for as long as the login lasts.
LOGIN_PROFILE="${LOGIN_PROFILE:-triage-admin}"
export AWS_REGION="ap-southeast-2"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION

if ! aws sts get-caller-identity --profile "$LOGIN_PROFILE" >/dev/null 2>&1; then
  echo "Not logged in: starting aws login."
  aws login --remote --profile "$LOGIN_PROFILE"
fi

aws configure set credential_process \
  "aws configure export-credentials --profile $LOGIN_PROFILE --format process" --profile inference-lab
aws configure set region ap-southeast-2 --profile inference-lab
export AWS_PROFILE=inference-lab

if aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1; then
  echo "AWS ready: profile 'inference-lab' refreshes credentials automatically."
else
  echo "AWS credentials not working; run: aws login --remote --profile $LOGIN_PROFILE" >&2
fi

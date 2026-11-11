# Long-lived, near-zero-cost resources that survive the nightly destroy:
# the permissions boundary, the artifacts bucket (weights, results) and the image registries.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  iam_path   = "/inference-lab/"
}

# ---------------------------------------------------------------------------
# Permissions boundary. pipeline-triage-agent's boundary is the right idea but the wrong
# ceiling here: it has no EC2, EKS, SSM or ECR-push actions, so nodes could not join a cluster
# and the spike instance could not be reached. Same pattern, own ceiling (ADR 0005).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "boundary" {
  statement {
    sid    = "ProjectServicesInRegion"
    effect = "Allow"
    actions = [
      "ec2:*", "elasticloadbalancing:*", "autoscaling:*", "eks:*", "ecr:*",
      "s3:*", "logs:*", "cloudwatch:*", "kms:Decrypt", "kms:GenerateDataKey*",
      "ssm:UpdateInstanceInformation", "ssm:ListInstanceAssociations", "ssm:GetParameter*",
      "ssm:DescribeAssociation", "ssm:GetDocument", "ssm:PutInventory",
      "ssm:UpdateInstanceAssociationStatus", "ssmmessages:*", "ec2messages:*",
      "sts:AssumeRoleWithWebIdentity", "sts:GetCallerIdentity",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "ReadTheAnthropicKeyOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:triage/anthropic-api-key-*"]
  }

  statement {
    sid       = "PassProjectRolesOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole", "iam:GetRole", "iam:ListAttachedRolePolicies"]
    resources = ["arn:aws:iam::${local.account_id}:role${local.iam_path}*"]
  }

  # EKS creates its service-linked roles on first use.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  # Belt and braces: no role under this boundary can ever leave Sydney or touch billing.
  statement {
    sid         = "DenyOtherRegions"
    effect      = "Deny"
    not_actions = ["iam:*", "sts:*", "support:*", "cloudfront:*", "route53:*"]
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "inference-lab-workload-boundary"
  path        = local.iam_path
  description = "Ceiling for every role inference-lab creates."
  policy      = data.aws_iam_policy_document.boundary.json
}

# ---------------------------------------------------------------------------
# Artifacts: model weights (downloaded once), harness bundle, raw results. Kept across nights.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  #checkov:skip=CKV_AWS_18:Access logging needs a second bucket; synthetic data and public weights only.
  #checkov:skip=CKV_AWS_144:Single-region account; cross-region replication is not possible.
  #checkov:skip=CKV_AWS_145:SSE-S3 is enough for public weights and benchmark results.
  #checkov:skip=CKV2_AWS_62:No consumers of event notifications.
  bucket = "inference-lab-artifacts-${local.account_id}-${var.region}"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "tidy"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

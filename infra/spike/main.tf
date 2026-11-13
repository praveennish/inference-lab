# Day-1 spike: one Graviton and one x86 host run images/spike/spike.sh, upload results to S3 and
# terminate themselves. Optional EKS control plane answers "does the Free plan allow EKS?".
# Nothing here is meant to live past the day: `make spike-down` destroys it all.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Default subnets keyed by AZ, and the AZs that offer each spike instance type.
data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# CPU hosts always; the GPU host only when enable_gpu is set.
locals {
  hosts = merge(var.instances, var.enable_gpu ? {
    gpu = { type = var.gpu_instance_type, arch = "x86_64" }
  } : {})
}

data "aws_ec2_instance_type_offerings" "spike" {
  for_each      = local.hosts
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [each.value.type]
  }
}

locals {
  subnet_by_az = { for s in data.aws_subnet.default : s.availability_zone => s.id }
  spike_subnet = {
    for k, o in data.aws_ec2_instance_type_offerings.spike :
    k => local.subnet_by_az[sort([for az in o.locations : az if contains(keys(local.subnet_by_az), az)])[0]]
  }
}

data "aws_ssm_parameter" "al2023" {
  for_each = toset(["arm64", "x86_64"])
  name     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${each.key}"
}

data "aws_ssm_parameter" "gpu_ami" {
  count = var.enable_gpu ? 1 : 0
  name  = var.gpu_ami_parameter
}

# The harness and dataset, so the instances run the same eval code as the Codespace.
data "archive_file" "bundle" {
  type        = "zip"
  output_path = "${path.module}/../../build/bundle.zip"
  source_dir  = "${path.module}/../.."
  excludes = [
    ".git", ".git/**", ".venv", ".venv/**", "build", "build/**", "infra", "infra/**",
    "docs", "docs/**", "**/__pycache__/**", ".ruff_cache/**", ".pytest_cache/**",
  ]
}

resource "aws_s3_object" "bundle" {
  bucket      = var.artifacts_bucket
  key         = "spike/${var.run_id}/bundle.zip"
  source      = data.archive_file.bundle.output_path
  source_hash = data.archive_file.bundle.output_base64sha256
}

# ---------------------------------------------------------------------------
# Instance role: Session Manager access (no SSH, no inbound ports) and the artifacts bucket.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spike" {
  name                 = "inference-lab-spike"
  path                 = "/inference-lab/"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = var.boundary_arn
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.spike.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}/spike/*", "arn:aws:s3:::${var.artifacts_bucket}/models/*"]
  }
}

resource "aws_iam_role_policy" "artifacts" {
  name   = "artifacts"
  role   = aws_iam_role.spike.id
  policy = data.aws_iam_policy_document.artifacts.json
}

resource "aws_iam_instance_profile" "spike" {
  name = "inference-lab-spike"
  path = "/inference-lab/"
  role = aws_iam_role.spike.name
}

resource "aws_security_group" "spike" {
  name        = "inference-lab-spike"
  description = "No inbound; outbound for packages, model download and S3"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "spike" {
  #checkov:skip=CKV_AWS_88:Public IP needed for outbound internet in the default VPC (no NAT); no inbound rules.
  #checkov:skip=CKV_AWS_126:Detailed monitoring not needed for a 2-hour spike.
  #checkov:skip=CKV2_AWS_41:Instance profile is attached.
  for_each = local.hosts

  ami                                  = each.key == "gpu" ? data.aws_ssm_parameter.gpu_ami[0].value : data.aws_ssm_parameter.al2023[each.value.arch].value
  instance_type                        = each.value.type
  subnet_id                            = local.spike_subnet[each.key]
  vpc_security_group_ids               = [aws_security_group.spike.id]
  iam_instance_profile                 = aws_iam_instance_profile.spike.name
  associate_public_ip_address          = true
  instance_initiated_shutdown_behavior = "terminate"
  ebs_optimized                        = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = each.key == "gpu" ? 150 : 80 # the CUDA image and the GPU AMI need more room
    encrypted   = true
  }

  user_data = templatefile("${path.module}/../../images/spike/user-data.sh.tftpl", {
    bucket         = var.artifacts_bucket
    run_id         = var.run_id
    label          = each.key
    max_minutes    = var.max_minutes
    vllm_version   = var.vllm_version
    model_id       = var.model_id
    model_revision = var.model_revision
    llama_cpp_ref  = var.llama_cpp_ref
    bundle_key     = aws_s3_object.bundle.key
  })
  user_data_replace_on_change = true

  tags = { Name = "inference-lab-spike-${each.key}" }
}

# ---------------------------------------------------------------------------
# EKS probe: control plane only. Cost is the control-plane hourly fee while it exists.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_probe" {
  count                = var.eks_probe ? 1 : 0
  name                 = "inference-lab-eks-probe"
  path                 = "/inference-lab/"
  assume_role_policy   = data.aws_iam_policy_document.eks_trust.json
  permissions_boundary = var.boundary_arn
}

resource "aws_iam_role_policy_attachment" "eks_probe" {
  count      = var.eks_probe ? 1 : 0
  role       = aws_iam_role.eks_probe[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "probe" {
  #checkov:skip=CKV_AWS_37:Probe only; no workloads, deleted the same day.
  #checkov:skip=CKV_AWS_38:Public endpoint for a probe with no nodes.
  #checkov:skip=CKV_AWS_39:Public endpoint for a probe with no nodes.
  #checkov:skip=CKV_AWS_58:No secrets stored in a probe cluster.
  count    = var.eks_probe ? 1 : 0
  name     = "inference-lab-probe"
  role_arn = aws_iam_role.eks_probe[0].arn

  access_config {
    authentication_mode = "API"
  }

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }

  depends_on = [aws_iam_role_policy_attachment.eks_probe]
}

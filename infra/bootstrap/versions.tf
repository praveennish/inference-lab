terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Reuses pipeline-triage-agent's state bucket with a separate key (passed by `make`).
  backend "s3" {
    key          = "inference-lab/bootstrap.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "inference-lab", managed_by = "terraform", stack = "bootstrap" }
  }
}

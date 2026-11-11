variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "boundary_arn" {
  description = "From infra/bootstrap output boundary_arn."
  type        = string
}

variable "artifacts_bucket" {
  description = "From infra/bootstrap output artifacts_bucket."
  type        = string
}

variable "run_id" {
  description = "Results go to s3://<bucket>/spike/<run_id>/<instance type>/."
  type        = string
}

variable "instances" {
  description = "Spike hosts. Same vCPU count (8) on each; Graviton vCPU = core, x86 vCPU = hyperthread."
  type        = map(object({ type = string, arch = string }))
  default = {
    graviton = { type = "c8g.2xlarge", arch = "arm64" }
    x86      = { type = "c7i.2xlarge", arch = "x86_64" }
  }
}

variable "max_minutes" {
  description = "Hard cap: each instance powers off (and terminates) after this many minutes."
  type        = number
  default     = 150
}

variable "eks_probe" {
  description = "Create an EKS control plane (no nodes) to learn whether the Free plan allows EKS."
  type        = bool
  default     = true
}

variable "vllm_version" {
  type    = string
  default = "0.33.0"
}

variable "model_id" {
  type    = string
  default = "Qwen/Qwen2.5-1.5B-Instruct"
}

variable "model_revision" {
  description = "Empty on the first spike: the script resolves main's commit and records it. Pin afterwards."
  type        = string
  default     = ""
}

variable "llama_cpp_ref" {
  description = "Empty on the first spike: the latest release tag is resolved and recorded. Pin afterwards."
  type        = string
  default     = ""
}

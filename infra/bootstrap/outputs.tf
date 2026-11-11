output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

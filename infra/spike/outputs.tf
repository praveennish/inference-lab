output "instances" {
  value = { for k, i in aws_instance.spike : k => { id = i.id, type = i.instance_type, az = i.availability_zone } }
}

output "results_prefix" {
  value = "s3://${var.artifacts_bucket}/spike/${var.run_id}/"
}

output "eks_probe" {
  value = var.eks_probe ? { name = aws_eks_cluster.probe[0].name, status = aws_eks_cluster.probe[0].status, version = aws_eks_cluster.probe[0].version } : null
}

output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Put this in envs/<clinic>/backend.tf."
  value       = aws_s3_bucket.state.id
}

output "terraform_ci_role_arn" {
  description = "Role ARN for terraform plan/apply in CI."
  value       = aws_iam_role.terraform_ci.arn
}

output "github_ci_role_arn" {
  description = "Role ARN for Docker build/push + ECS deploy in CI."
  value       = aws_iam_role.github_ci.arn
}

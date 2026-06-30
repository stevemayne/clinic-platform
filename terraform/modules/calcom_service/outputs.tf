output "url" {
  description = "Public URL for Cal.com."
  value       = "https://${local.fqdn}"
}

output "service_name" {
  value = aws_ecs_service.calcom.name
}

output "ecr_repository_url" {
  description = "Push the per-clinic Cal.com image here from CI."
  value       = aws_ecr_repository.calcom.repository_url
}

output "migrate_task_definition_arn" {
  description = "Run this with `aws ecs run-task` to apply Prisma migrations."
  value       = aws_ecs_task_definition.migrate.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.calcom.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.calcom.name
}

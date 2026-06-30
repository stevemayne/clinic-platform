output "url" {
  description = "Public URL for n8n."
  value       = "https://${local.fqdn}"
}

output "service_name" {
  value = aws_ecs_service.n8n.name
}

output "target_group_arn" {
  value = aws_lb_target_group.n8n.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.n8n.name
}

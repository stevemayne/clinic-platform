output "url" {
  description = "Public URL for the chat UI."
  value       = "https://${local.fqdn}"
}

output "service_name" {
  value = aws_ecs_service.chat.name
}

output "target_group_arn" {
  value = aws_lb_target_group.chat.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.chat.name
}

output "oidc_redirect_uri" {
  description = "Redirect URI for the clinic's Google OAuth client (Open WebUI's generic OIDC callback)."
  value       = "https://${local.fqdn}/oauth/oidc/callback"
}

output "name_servers" {
  description = "Delegate the registrar's NS records to these."
  value       = aws_route53_zone.public.name_servers
}

output "alb_dns_name" {
  value = module.ingress.alb_dns_name
}

output "n8n_url" {
  value = module.n8n.url
}

output "calcom_url" {
  value = module.calcom.url
}

output "chat_url" {
  value = module.chat.url
}

output "chat_oidc_redirect_uri" {
  description = "Give this to the clinic's Workspace admin when creating the Google OAuth client."
  value       = module.chat.oidc_redirect_uri
}

output "calcom_ecr_repository_url" {
  description = "Push the per-clinic Cal.com image here from CI."
  value       = module.calcom.ecr_repository_url
}

output "n8n_bedrock_user_name" {
  description = "IAM user for n8n's AWS credential (Bedrock). Create its access key out-of-band; see DEPLOY.md §10."
  value       = module.n8n.bedrock_user_name
}

output "ecs_cluster_name" {
  value = module.ecs_cluster.cluster_name
}

output "db_address" {
  value = module.data.db_address
}

output "db_master_secret_arn" {
  value = module.data.db_master_secret_arn
}

output "binary_data_bucket" {
  value = module.data.binary_data_bucket
}

output "documents_bucket" {
  value = module.data.documents_bucket
}

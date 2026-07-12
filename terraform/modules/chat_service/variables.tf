variable "name_prefix" {
  description = "Prefix for resource names (e.g. \"acc\")."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

# --- Cluster / compute ------------------------------------------------------

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "execution_role_arn" {
  description = "ECS task execution role ARN (pulls images, writes logs, injects secrets)."
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units (shared by both containers)."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Fargate task memory (MiB). Open WebUI runs a local embedding model for RAG; 2 GB is the practical floor."
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Number of chat tasks. Keep at 1: Open WebUI needs sticky websockets or a Redis broker to scale out."
  type        = number
  default     = 1
}

variable "open_webui_image" {
  description = "Open WebUI container image. PoC pulls the public image directly; front with an ECR pull-through cache for production (see n8n_service/main.tf for the pattern)."
  type        = string
  default     = "ghcr.io/open-webui/open-webui:v0.10.2"
}

variable "litellm_image" {
  description = "LiteLLM proxy container image (Bedrock -> OpenAI-compatible gateway for Open WebUI)."
  type        = string
  default     = "ghcr.io/berriai/litellm:v1.92.0"
}

# --- Networking -------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets the task runs in."
  type        = list(string)
}

variable "ecs_security_group_id" {
  description = "Shared ECS security group (this module adds an ALB->task ingress rule on the chat port)."
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB security group, allowed to reach the task."
  type        = string
}

# --- Ingress ----------------------------------------------------------------

variable "https_listener_arn" {
  description = "ALB HTTPS listener ARN to attach the host-based rule to."
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name (for the Route53 alias)."
  type        = string
}

variable "alb_zone_id" {
  description = "ALB hosted zone ID (for the Route53 alias)."
  type        = string
}

variable "zone_id" {
  description = "Route53 hosted zone ID for the clinic domain."
  type        = string
}

variable "domain_name" {
  description = "Clinic apex domain (e.g. acc.example.com)."
  type        = string
}

variable "subdomain" {
  description = "Subdomain label for the chat UI."
  type        = string
  default     = "chat"
}

# --- Bedrock models ---------------------------------------------------------

variable "bedrock_models" {
  description = "Bedrock models exposed in the chat UI, via LiteLLM. model_id must be an inference-profile ID enabled in the account (us.anthropic.*)."
  type = list(object({
    name     = string # model name shown in Open WebUI
    model_id = string # Bedrock inference-profile ID
  }))
  default = [
    { name = "claude-opus-4-8", model_id = "us.anthropic.claude-opus-4-8" },
    { name = "claude-sonnet-5", model_id = "us.anthropic.claude-sonnet-5" },
    { name = "claude-haiku-4-5", model_id = "us.anthropic.claude-haiku-4-5-20251001-v1:0" },
  ]
}

variable "default_model" {
  description = "Model pre-selected for new chats (must match a bedrock_models name). Sonnet per the COSTS.md model split."
  type        = string
  default     = "claude-sonnet-5"
}

# --- Auth (Google Workspace via generic OIDC) --------------------------------

variable "oauth_client_id" {
  description = <<-EOT
    OAuth client ID from the clinic's Google Cloud project (non-sensitive; the
    secret goes in the oauth_client_secret placeholder). Empty = SSO not yet
    configured: the module falls back to local email/password login so the
    admin account can be claimed. Set it to flip the service to SSO-only.
  EOT
  type        = string
  default     = ""
}

variable "oauth_allowed_email_domains" {
  description = "Comma-separated email domains allowed to sign in via SSO (the clinic's Workspace domain). Empty = any domain the IdP authenticates — the Internal consent screen still limits sign-in to the clinic's Workspace."
  type        = string
  default     = ""
}

# --- Data / secrets ---------------------------------------------------------

variable "documents_bucket" {
  description = "Clinic documents bucket; chat uploads live under chat/uploads/, the LiteLLM config under chat/."
  type        = string
}

variable "kms_key_arn" {
  description = "Clinic CMK ARN (the task role needs it for the encrypted S3 objects)."
  type        = string
}

variable "database_url_secret_arn" {
  description = "Secrets Manager ARN holding Open WebUI's DATABASE_URL (postgresql://chatui:<pw>@<host>:5432/chatui?sslmode=require)."
  type        = string
}

variable "webui_secret_key_secret_arn" {
  description = "Secrets Manager ARN holding WEBUI_SECRET_KEY (JWT signing + at-rest encryption; auto-generation would not survive Fargate task replacement)."
  type        = string
}

variable "oauth_client_secret_arn" {
  description = "Secrets Manager ARN holding the Google OAuth client secret."
  type        = string
}

variable "litellm_master_key_secret_arn" {
  description = "Secrets Manager ARN holding the LiteLLM master key (value must start with \"sk-\"). Shared with Open WebUI as its OPENAI_API_KEY."
  type        = string
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

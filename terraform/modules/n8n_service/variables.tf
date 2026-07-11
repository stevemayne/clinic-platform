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
  description = "ECS task execution role ARN (pulls image, writes logs, injects secrets)."
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Number of n8n tasks (keep at 1 in main mode; scale via queue mode later)."
  type        = number
  default     = 1
}

variable "n8n_image" {
  description = "n8n container image. PoC pulls the public image directly; front with an ECR pull-through cache for production (see main.tf)."
  type        = string
  # 2.x is required for N8N_EXTERNAL_STORAGE_S3_AUTH_AUTO_DETECT (task-role
  # S3 auth) — 1.x only supported access key/secret. 2.29.10 = stable channel.
  default = "docker.n8n.io/n8nio/n8n:2.29.10"
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
  description = "Shared ECS security group (this module adds an ALB->task ingress rule on the n8n port)."
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
  description = "Subdomain label for n8n."
  type        = string
  default     = "n8n"
}

# --- Data / secrets ---------------------------------------------------------

variable "db_host" {
  description = "RDS endpoint hostname."
  type        = string
}

variable "db_port" {
  description = "RDS port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Postgres database for n8n (created by the app init step)."
  type        = string
  default     = "n8n"
}

variable "db_user" {
  description = "Postgres role for n8n (created by the app init step)."
  type        = string
  default     = "n8n"
}

variable "binary_data_bucket" {
  description = "S3 bucket for n8n binary data."
  type        = string
}

variable "kms_key_arn" {
  description = "Clinic CMK ARN (the task role needs it to read/write encrypted S3 objects)."
  type        = string
}

variable "encryption_key_secret_arn" {
  description = "Secrets Manager ARN holding N8N_ENCRYPTION_KEY."
  type        = string
}

variable "db_password_secret_arn" {
  description = "Secrets Manager ARN holding the n8n DB password."
  type        = string
}

variable "timezone" {
  description = "n8n GENERIC_TIMEZONE."
  type        = string
  default     = "Etc/UTC"
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

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
  description = "ECS task execution role ARN."
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
  description = "Number of Cal.com tasks."
  type        = number
  default     = 1
}

variable "image_tag" {
  description = "Tag of the per-clinic Cal.com image in the ECR repo this module creates. CI builds & pushes it with NEXT_PUBLIC_WEBAPP_URL baked in."
  type        = string
  default     = "latest"
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
  description = "Shared ECS security group (this module adds an ALB->task ingress rule on the Cal.com port)."
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
  description = "Subdomain label for Cal.com."
  type        = string
  default     = "cal"
}

# --- Secrets ----------------------------------------------------------------

variable "database_url_secret_arn" {
  description = "Secrets Manager ARN holding the full DATABASE_URL (postgresql://calcom:<pw>@<host>:5432/calcom)."
  type        = string
}

variable "nextauth_secret_arn" {
  description = "Secrets Manager ARN holding NEXTAUTH_SECRET."
  type        = string
}

variable "encryption_key_secret_arn" {
  description = "Secrets Manager ARN holding CALENDSO_ENCRYPTION_KEY."
  type        = string
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

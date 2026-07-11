variable "name_prefix" {
  description = "Prefix for resource names (e.g. \"acc\")."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the DB subnet group."
  type        = list(string)
}

variable "ecs_security_group_id" {
  description = "ECS security group allowed to reach Postgres on 5432."
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage (GB)."
  type        = number
  default     = 30
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling (GB)."
  type        = number
  default     = 100
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (days). 7 is the production baseline; AWS free-plan accounts cap this at 1."
  type        = number
  default     = 7
}

variable "performance_insights_enabled" {
  description = "Enable RDS Performance Insights."
  type        = bool
  default     = true
}

variable "multi_az" {
  description = "Multi-AZ RDS (HA). Per-clinic upsell; default single-AZ."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the RDS instance from deletion."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

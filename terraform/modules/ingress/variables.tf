variable "name_prefix" {
  description = "Prefix for resource names (e.g. \"acc\")."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (ALB egress target)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB."
  type        = list(string)
}

variable "domain_name" {
  description = "Apex domain for this clinic (e.g. acc.example.com)."
  type        = string
}

variable "zone_id" {
  description = "Route53 hosted zone ID for domain_name."
  type        = string
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

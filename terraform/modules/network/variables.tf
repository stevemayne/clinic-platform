variable "name_prefix" {
  description = "Prefix for resource names (e.g. \"acc\")."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used to build VPC endpoint service names)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "azs" {
  description = "Availability zones."
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs (one per AZ)."
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs (one per AZ). ECS tasks and RDS live here."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cheaper) vs one per AZ (HA)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}

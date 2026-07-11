variable "clinic" {
  description = "Short clinic slug, used to name the state bucket (e.g. \"acc\")."
  type        = string
}

variable "aws_region" {
  description = "Region for the state bucket and bootstrap resources."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the CI roles via OIDC."
  type        = string
  default     = "stevemayne/clinic-platform"
}

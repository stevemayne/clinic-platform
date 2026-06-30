provider "aws" {
  region = local.region

  # In CI, the terraform-github-actions-role in ACC's account is assumed before
  # running. For local runs, use credentials/profile for ACC's account.

  default_tags {
    tags = {
      Clinic      = local.clinic
      Environment = local.environment
      Project     = local.project
      ManagedBy   = "terraform"
    }
  }
}

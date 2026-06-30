provider "aws" {
  region = local.region

  # In CI, the terraform-github-actions-role in the clinic's account is assumed
  # before running. For local runs, use credentials/profile for that account.

  default_tags {
    tags = {
      Clinic      = local.clinic
      Environment = local.environment
      Project     = local.project
      ManagedBy   = "terraform"
    }
  }
}

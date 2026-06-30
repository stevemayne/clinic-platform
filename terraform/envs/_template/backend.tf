terraform {
  backend "s3" {
    # Per-account bucket from scripts/bootstrap: tfstate-<clinic>-<account_id>.
    bucket       = "tfstate-__CLINIC__-000000000000"
    key          = "platform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

terraform {
  backend "s3" {
    # Per-account bucket created by scripts/bootstrap. Name is deterministic:
    # tfstate-<clinic>-<account_id>.
    bucket       = "tfstate-acc-185818464031"
    key          = "platform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

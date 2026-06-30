terraform {
  backend "s3" {
    # Per-account bucket created by scripts/bootstrap. Name is deterministic:
    # tfstate-<clinic>-<account_id>. Replace the account ID below with ACC's.
    bucket       = "tfstate-acc-000000000000"
    key          = "platform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

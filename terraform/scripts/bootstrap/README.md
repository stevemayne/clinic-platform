# Bootstrap (run once per clinic account)

Creates the per-account Terraform **state bucket** (S3-native locking, no DynamoDB) and the **GitHub OIDC provider + CI roles**. Run with credentials for the clinic's *own* AWS account, before the first `apply` in `envs/<clinic>`.

```bash
cd terraform/scripts/bootstrap

terraform init   # local state — this dir bootstraps the remote backend itself
terraform apply -var 'clinic=acc' -var 'github_repo=your-org/acc'
```

Then copy the `state_bucket_name` output into `envs/<clinic>/backend.tf` (it's deterministic: `tfstate-<clinic>-<account_id>`).

> This directory uses **local state** by design — it's the chicken-and-egg root that creates the backend everything else uses. Commit nothing but the `.tf` files.

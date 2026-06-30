# Clinic Platform — Terraform

Modular Terraform for standing up a HIPAA-compliant clinic environment (n8n + Cal.com + supporting services) on AWS. See [../implementation.md](../implementation.md) for the architecture and conventions.

## Layout

```
terraform/
├── modules/          # reusable building blocks
│   ├── network/      # VPC, subnets, NAT, VPC endpoints, ECS security group
│   ├── ecs_cluster/  # ECS cluster + task execution role
│   ├── data/         # KMS, RDS Postgres, S3 buckets
│   └── ingress/      # ACM cert + ALB (HTTP→HTTPS, default 503)
├── envs/
│   ├── _template/    # copy this to onboard a new clinic
│   └── acc/          # Andrews Counseling & Consulting (proof of concept)
└── scripts/
    └── bootstrap/    # one-time per-account: state bucket + GitHub OIDC roles
```

Each **clinic is an environment** with its **own AWS account** and its **own S3 state bucket**.

## Onboarding a clinic (summary)

1. Create the clinic's AWS account in the Org.
2. With credentials for that account, run `scripts/bootstrap` (see its README) to create the per-account state bucket and CI roles.
3. `cp -r envs/_template envs/<clinic>` and edit `locals.tf` + `backend.tf`.
4. Populate the Secrets Manager placeholders (see `secrets.tf`).
5. `terraform init && terraform apply` from `envs/<clinic>`.

## Conventions

- Region: **us-east-1** (US healthcare; matches the cost model).
- State: **per-account** S3 bucket, `key = "platform.tfstate"`, `use_lockfile = true` (S3-native locking, no DynamoDB).
- Versions: `aws >= 6.30 < 7`, `terraform >= 1.13 < 2`; every module ships `versions.tf`.
- Naming: `${basename(path.cwd)}-<resource>` → `envs/acc` yields `acc-vpc`, `acc-ecs-cluster`, `acc-alb`.
- Tags: product-neutral default tags (`Clinic`, `Environment`, `Project`, `ManagedBy`). No org/namespace prefix.

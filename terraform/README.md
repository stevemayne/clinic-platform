# Clinic Platform — Terraform

Modular Terraform for standing up a HIPAA-compliant clinic environment (n8n + Cal.com + supporting services) on AWS. See [../implementation.md](../implementation.md) for the architecture and conventions.

## Layout

```
terraform/
├── modules/              # reusable building blocks
│   ├── network/          # VPC, subnets, NAT, VPC endpoints, ECS security group
│   ├── ecs_cluster/      # ECS cluster + task execution role
│   ├── data/             # KMS, RDS Postgres (n8n/calcom/chatui DBs), S3 buckets
│   ├── ingress/          # ACM cert + ALB (HTTP→HTTPS, default 503)
│   ├── n8n_service/      # n8n at automate.<domain> + Bedrock IAM user for its AWS credential
│   ├── calcom_service/   # Cal.com at cal.<domain>: per-clinic ECR repo, service, Prisma migrate task
│   └── chat_service/     # Open WebUI + LiteLLM sidecar → Bedrock at chat.<domain>, Google-OIDC-ready
├── envs/
│   ├── _template/    # copy this to onboard a new clinic
│   └── acc/          # Andrews Counseling & Consulting (proof of concept)
└── scripts/
    └── bootstrap/    # one-time per-account: state bucket + GitHub OIDC roles
```

Each **clinic is an environment** with its **own AWS account** and its **own S3 state bucket**.

## Onboarding a clinic (summary)

The full ordered runbook (with the real ACC values) is [../DEPLOY.md](../DEPLOY.md); in outline:

1. Create the clinic's AWS account in the Org.
2. With credentials for that account, run `scripts/bootstrap` (see its README) to create the per-account state bucket and CI roles.
3. `cp -r envs/_template envs/<clinic>` and edit `locals.tf` + `backend.tf`.
4. Two-phase apply: hosted zone first (`-target=aws_route53_zone.public`), delegate NS at the registrar, then full `terraform apply`.
5. Populate the Secrets Manager placeholders (see `secrets.tf`) and run the DB init step (`n8n`/`calcom`/`chatui` roles + databases + pgvector — DEPLOY.md §7); services crash-loop until both exist.
6. Build + push the per-clinic Cal.com image and run the Prisma migrate task (DEPLOY.md §8 / CI workflow).

## Conventions

- Region: **us-east-1** (US healthcare; matches the cost model).
- State: **per-account** S3 bucket, `key = "platform.tfstate"`, `use_lockfile = true` (S3-native locking, no DynamoDB).
- Versions: `aws >= 6.30 < 7`, `terraform >= 1.13 < 2`; every module ships `versions.tf`.
- Naming: `${basename(path.cwd)}-<resource>` → `envs/acc` yields `acc-vpc`, `acc-ecs-cluster`, `acc-alb`.
- Tags: product-neutral default tags (`Clinic`, `Environment`, `Project`, `ManagedBy`). No org/namespace prefix.

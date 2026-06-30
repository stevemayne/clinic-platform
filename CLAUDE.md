# CLAUDE.md

Guidance for working in this repo.

## What this is

The base installation set for standing up **HIPAA-compliant clinic environments** on AWS — self-hosted n8n (automations) + Cal.com (scheduling) + Claude via Amazon Bedrock, isolated per clinic. ACC (Andrews Counseling & Consulting) is the first tenant / proof of concept; the platform is built to replicate across many clinics.

## Documents (read these for context)

- **RECOMMENDATIONS.md** — architecture rationale: HIPAA stack, vendor compliance, EHR/billing strategy, data co-op.
- **implementation.md** — the build spec: packaging decision, module catalog, per-clinic model, milestones (M0–M6), open decisions. **The source of truth for what we're building and why.**
- **COSTS.md** — per-tenant AWS cost model (shared vs per-client).
- **terraform/** — the implementation. See `terraform/README.md`.

When a change affects architecture or cost, update the relevant doc in the same change.

## Repo layout

```
terraform/
├── modules/      network · ecs_cluster · data · ingress · n8n_service · calcom_service   (chat_service, bedrock_access = TODO)
├── envs/         acc (real PoC) · _template (copy-source for new clinics)
└── scripts/bootstrap/   one-time per-account: state bucket + GitHub OIDC roles
```

## Non-negotiable conventions

Match these exactly when adding Terraform — they are load-bearing:

- **Account-per-tenant.** Each clinic is its own AWS account *and* its own Terraform env under `envs/<clinic>`. A clinic is an environment.
- **Per-account state.** Each account has its own S3 state bucket (`tfstate-<clinic>-<account_id>`, created by bootstrap), `key = "platform.tfstate"`, `use_lockfile = true`. **No DynamoDB lock table, no shared state bucket.**
- **Region:** `us-east-1`.
- **Version pins:** `aws >= 6.30.0, < 7.0.0`; `terraform >= 1.13.1, < 2.0.0`. Every module ships a `versions.tf`.
- **Naming:** `${basename(path.cwd)}-<resource>` (so `envs/acc` → `acc-vpc`). The clinic slug must equal the env directory name.
- **Tags:** product-neutral default tags only — `Clinic`, `Environment`, `Project` (`clinic-platform`), `ManagedBy` (`terraform`). **No org/vendor namespace prefix.**
- **Module shape:** `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf`, split by concern for larger modules (`iam.tf`, `alb.tf`).
- **Secrets:** Secrets Manager **placeholder pattern** — create the secret with `secret_string = "placeholder-populate-me"` + `lifecycle { ignore_changes = [secret_string] }`; populate out-of-band; inject into tasks via ECS `secrets` (`valueFrom`). Real secrets never live in code/state.
- **ECS services:** Fargate, tasks in **private** subnets (`assign_public_ip = false`), behind the shared ALB via host-based listener rules; `lifecycle { ignore_changes = [task_definition] }` so CD owns image rollouts.

Conventions are intentionally aligned with the team's other infrastructure. Do **not** introduce a vendor/product name into tags or docs.

## Working with the Terraform

Validate without AWS credentials or a backend:

```bash
cd terraform && terraform fmt -recursive
cd envs/acc && terraform init -backend=false && terraform validate
# clean up afterward:
find terraform -type d -name .terraform -exec rm -rf {} + ; find terraform -name .terraform.lock.hcl -delete
```

Always `fmt -recursive` and `validate` (acc + _template) after changes. A real apply needs: bootstrap run first, the account ID in `envs/<clinic>/backend.tf`, and the real domain in `locals.tf`.

## Decisions already made (do not relitigate)

- Containers on **ECS Fargate** (not AMIs/Marketplace/Ansible).
- **One n8n instance per clinic** (n8n has no real multi-tenancy).
- **Cal.com = self-hosted Cal.diy (MIT), free.** Not AGPL anymore (changed April 2026). Commercial license only if Teams/SSO are needed.
- **Claude via Amazon Bedrock** under the AWS BAA (one BAA covers compute + inference).
- **No Org/landing-zone layer yet** — accounts are assumed to exist; bootstrap runs inside them. This is M6 (future).

## Gotchas

- **DB roles/databases (`n8n`, `calcom`) are created by an app init step, not Terraform** — the RDS instance is private, so a TF Postgres provider can't reach it. Services crash-loop until the role + password (matching the `*_db_password` secret) exist.
- **RDS has `deletion_protection = true` and the state bucket has `prevent_destroy`** — both block `destroy` by design.
- **n8n image** is pulled from the public registry for the PoC; ECR pull-through cache (needs a Docker Hub credential secret) is the documented production upgrade.
- **n8n S3 external-storage credentials** — verify IAM-role vs access-key/secret model during testing.
- **Cal.com (M3):** `NEXT_PUBLIC_WEBAPP_URL` is baked at **build time** → CI must build a per-clinic image; Prisma migrations run as a one-off ECS task.

## Status

M0 (bootstrap) + M1 (network/ecs_cluster/data/ingress) + M2 (n8n_service) + M3 (calcom_service: per-clinic ECR repo, service, Prisma migration task) done and validated. **Next: M4 — Bedrock access IAM + chat_service (LibreChat), then CI/CD (`.github/workflows`).**

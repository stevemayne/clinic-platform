# Implementation Spec: ACC Platform Base Installation

**Status:** Draft v0.1 · **Prepared:** 28 June 2026
**Purpose:** Turn this repo into the **base installation set** for standing up a HIPAA-compliant clinic environment (n8n + Cal.com + supporting services) on AWS, defined as modular Terraform that follows our established infrastructure-as-code conventions. One `terraform apply` should stand up a complete clinic; onboarding a new clinic should be copying an env directory and editing a tfvars/locals file.

See [RECOMMENDATIONS.md](RECOMMENDATIONS.md) for the architecture rationale and [COSTS.md](COSTS.md) for the cost model this build realises.

---

## 1. Packaging decision: containers on ECS Fargate

**Recommendation: Docker containers on ECS Fargate, defined entirely in Terraform.** No baked AMIs, no Marketplace listings, no Ansible.

Both n8n and Cal.com ship official, well-maintained container images and are designed to run as containers. This is also exactly how our other services run (Fargate everywhere), so we inherit our existing patterns, CI templates, and operational muscle memory.

| Option | Verdict | Why |
|---|---|---|
| **Containers on ECS Fargate** | ✅ **Chosen** | Official images for both apps; immutable & reproducible; no servers to patch; matches our Fargate-everywhere convention; per-clinic isolation via separate accounts/services; trivial to pin versions by digest. |
| Baked AMIs (Packer) | ❌ | Requires a separate image-bake pipeline and a golden-image lifecycle; you still run mutable EC2 underneath and own OS patching. Heavier for no benefit when official containers exist. |
| AWS Marketplace AMIs | ❌ | n8n community AMIs exist but lock us into someone else's packaging/licensing; Cal.com isn't meaningfully available; least control, hardest to replicate cleanly per clinic. |
| Ansible on EC2 | ❌ | Config-management of long-lived mutable servers — the paradigm we're explicitly moving away from. Causes drift, undermines the "replicate identically per clinic" goal. |

**Compute shape:** ECS Fargate services behind one ALB per clinic, with host-based routing (`n8n.<clinic>.<apex>`, `cal.<clinic>.<apex>`, `chat.<clinic>.<apex>`). Mirrors our standard ECS service module pattern.

---

## 2. Repository layout (mirrors our standard IaC conventions)

Each **clinic is an environment** — the natural extension of our `envs/dev`, `envs/prod` pattern. Onboarding a clinic = copy `envs/_template` → `envs/<clinic>` and edit `locals.tf`.

```
acc/
├── RECOMMENDATIONS.md
├── COSTS.md
├── implementation.md
└── terraform/
    ├── modules/
    │   ├── network/          # VPC, subnets, NAT, VPC endpoints, SGs (wraps terraform-aws-modules/vpc)
    │   ├── data/             # RDS Postgres (n8n + calcom DBs), S3 buckets, KMS keys
    │   ├── ingress/          # ALB (terraform-aws-modules/alb), ACM cert, Route53 records
    │   ├── ecs_cluster/      # ECS cluster + shared task execution role + log groups
    │   ├── n8n_service/      # task def, service, target group, ECR pull-through ref, secrets
    │   ├── calcom_service/   # task def, service, target group, ECR repo, migration task, secrets
    │   ├── chat_service/     # LibreChat/Open WebUI (phase 2 — stubbed)
    │   └── bedrock_access/   # IAM policy for bedrock:InvokeModel from task roles
    ├── envs/
    │   ├── _template/        # copy this to onboard a clinic
    │   │   ├── main.tf       # module wiring
    │   │   ├── locals.tf     # per-clinic config (domain, sizing, region, account)
    │   │   ├── providers.tf  # aws provider + assume-role into clinic account + default_tags
    │   │   ├── backend.tf    # s3 backend in the clinic's own account, key = "platform.tfstate"
    │   │   ├── lookups.tf    # data sources (route53 zone, etc.)
    │   │   ├── secrets.tf    # Secrets Manager placeholders (placeholder-populate-me pattern)
    │   │   └── outputs.tf
    │   └── acc/              # first clinic (proof of concept)
    └── scripts/
        └── bootstrap/        # per-account state bucket + DynamoDB lock + GitHub OIDC role
```

**Conventions carried over from our standard IaC setup (do not deviate):**

- **Naming:** `${basename(path.cwd)}-<resource>` → `envs/acc` yields `acc-vpc`, `acc-ecs-cluster`, `acc-alb`.
- **Versions:** `aws ~> ">= 6.30.0, < 7.0.0"`, `required_version ">= 1.13.1, < 2.0.0"`; every module ships a `versions.tf`.
- **Config:** `locals.tf` per env holds environment-specific values; minimal input variables.
- **Module split:** `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf`, split by concern for larger modules (`iam.tf`, `ecs_service.tf`, `alb.tf`, `lookups.tf`).
- **Tagging:** `default_tags` on the provider with product-neutral keys — `Environment`, `Clinic`, `Service`, `Project`, `ManagedBy = "terraform"`. No org/namespace prefix.
- **Public modules:** `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/alb/aws`, pinned.

---

## 3. Per-clinic isolation model

- **One AWS account per clinic** under the Org (strongest isolation; clean offboarding; per-clinic billing). The `providers.tf` in each env assumes a role into that clinic's account; `scripts/bootstrap` runs once per account to create state + OIDC.
- **State:** **per-account** — each clinic account has its own S3 state bucket (created by `scripts/bootstrap`) with `key = "platform.tfstate"` and `use_lockfile = true`. No shared/cross-account state bucket.
- **Within a clinic, one RDS instance hosts two logical databases** (`n8n`, `calcom`) with separate roles. The isolation boundary is the clinic account, so co-locating the two app DBs is fine and matches the `db.t4g.small` line in the cost model.

> **Current assumption / known gap:** there is **no AWS Organization or landing-zone layer yet**. The build assumes the clinic account already exists and that `scripts/bootstrap` is run inside it with that account's credentials. This is fine for the ACC PoC and the first few clinics, but an **Org + account-factory layer will become important as we scale** — see the future-phase milestone in §13.

---

## 4. n8n service module (`modules/n8n_service`)

n8n is very container-friendly. Run it in **main mode** (single task, no separate workers) initially; the cost model assumes 1 vCPU / 2 GB.

**Image:** official `docker.n8n.io/n8nio/n8n`, **mirrored into ECR via a pull-through cache** and pinned by digest (avoids Docker Hub rate limits, gets `scan_on_push`, keeps deploys reproducible).

**Key configuration (Fargate task definition env):**

| Variable | Value / source |
|---|---|
| `DB_TYPE` | `postgresdb` |
| `DB_POSTGRESDB_HOST/PORT/DATABASE/USER` | from `data` module outputs (RDS endpoint, `n8n` DB) |
| `DB_POSTGRESDB_PASSWORD_FILE` | injected from Secrets Manager (use `_FILE` suffix / ECS `secrets` `valueFrom`) |
| `N8N_ENCRYPTION_KEY` | Secrets Manager (credential encryption — **back this up; losing it bricks stored credentials**) |
| `N8N_HOST` / `WEBHOOK_URL` / `N8N_PROTOCOL` | `n8n.<clinic>.<apex>` / `https` |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `s3` → clinic S3 bucket (filesystem mode needs EFS on Fargate; S3 avoids that and is required for queue mode later) |
| `EXECUTIONS_DATA_PRUNE` / `..._MAX_AGE` | conservative retention — keep PHI out of long-lived execution logs |

- **Postgres 13+** required (RDS Postgres satisfies this).
- **Scaling path (documented, not built yet):** switch `EXECUTIONS_MODE=queue`, add ElastiCache Redis + worker tasks. Queue mode **requires** S3 binary-data mode (already set above), so we're forward-compatible.
- **Secrets** never passed as plain env where avoidable — use the `_FILE` convention so values load from mounted secrets.

Sources: [n8n Docker docs](https://docs.n8n.io/hosting/installation/docker/) · [n8n queue mode](https://docs.n8n.io/hosting/scaling/queue-mode/) · [n8n DB env vars](https://docs.n8n.io/hosting/configuration/environment-variables/database/)

---

## 5. Cal.com service module (`modules/calcom_service`)

Cal.com is the trickier of the two. Three things must be handled explicitly:

### 5a. Build-time URL gotcha → we build our own image

`NEXT_PUBLIC_WEBAPP_URL` is **inlined by Next.js at build time** — it cannot be set purely at runtime. Changing it requires rebuilding the image. ([Cal.com Docker docs](https://cal.com/docs/self-hosting/docker), [issue #3704](https://github.com/calcom/cal.com/discussions/3704))

**Decision:** CI builds a Cal.com image **per clinic domain**, passing `--build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.<clinic>.<apex>`, and pushes to a per-clinic ECR repo/tag. This is an accepted, recurring per-clinic build cost — note it in the onboarding runbook. (Alternative: standardise every clinic on a subdomain of one apex and bake a single image with a wildcard-aware reverse proxy — more complex; defer unless build overhead becomes painful.)

### 5b. Database migrations

Cal.com uses Prisma migrations that must run against the `calcom` DB on deploy. Run them as a **one-off ECS task** (`yarn prisma migrate deploy`) gated before the service rolls — modeled as a separate task definition triggered in the deploy workflow, not baked into the long-running container.

### 5c. Licensing & HIPAA posture

- **As of April 2026 (Cal.com v6.4), the free self-hosted edition is "Cal.diy" under the permissive MIT license** (previously AGPLv3). Self-hosting Cal.diy costs nothing — no per-user fee, no copyleft obligation; we may run, modify, and white-label it freely. ([Cal.com v6.4 license change](https://cal.com/blog/calcom-v6-4), [Cal.diy](https://cal.diy/))
- **Trade-offs of the free edition:** Cal.com positions Cal.diy as "personal, non-production, use at your own risk" with no security guarantees, and it omits Teams, Organizations, SAML SSO, Analytics, and Admin Panels (and Cal.com Workflows — but n8n covers automation). MIT still permits production use; we simply own all hardening and patching ourselves. The **proprietary commercial Cal.com** (now closed-source, ≥30-user minimum) is the paid alternative if Teams/SSO become hard requirements.
- **HIPAA:** self-hosting inside our BAA-covered AWS environment means **compliance is ours** (good — no dependency on Cal.com's cloud BAA). Cal.diy replaces Calendly, which can't sign a BAA (see RECOMMENDATIONS §vendor map).

### 5d. Configuration

| Variable | Value / source |
|---|---|
| `NEXT_PUBLIC_WEBAPP_URL` | **build arg** = `https://cal.<clinic>.<apex>` |
| `DATABASE_URL` | RDS endpoint, `calcom` DB — from Secrets Manager |
| `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY` | Secrets Manager |
| `NEXTAUTH_URL` | `https://cal.<clinic>.<apex>/api/auth` |
| Email (SMTP) | Paubox/Workspace SMTP creds from Secrets Manager |

**Sizing:** 1 vCPU / 2 GB at runtime; **build in CI, not at runtime** (the Next.js build is memory-hungry).

---

## 6. Shared data layer (`modules/data`)

- **RDS Postgres** `db.t4g.small`, single-AZ for the PoC (Multi-AZ as a per-clinic toggle), encrypted with a clinic KMS key. Creates databases `n8n` and `calcom` with distinct roles (via a Postgres provider or a bootstrap SQL task).
- **S3 buckets** (KMS-encrypted): n8n binary data, Cal.com/app uploads, document/intake storage. Versioned; public-access blocked.
- **KMS** customer-managed keys (RDS, S3, Secrets). 2–3 keys per the cost model.
- **AWS Backup** plan for RDS + S3.

---

## 7. Networking & ingress (`modules/network`, `modules/ingress`)

- **`network`:** wrap `terraform-aws-modules/vpc/aws` (as `../terraform` does) — private subnets for ECS/RDS, 1 NAT Gateway (single-AZ PoC), **VPC interface endpoints** for Bedrock, ECR (api+dkr), Secrets Manager, CloudWatch Logs, and an S3 gateway endpoint, so PHI-bearing traffic stays off the public internet. Security groups via `${basename(path.cwd)}-*-sg`.
- **`ingress`:** wrap `terraform-aws-modules/alb/aws` — HTTP→HTTPS redirect, HTTPS listener with an ACM cert (DNS-validated via Route53), host-based routing rules to the n8n / Cal.com / chat target groups. Mirrors the ALB block in `../terraform/envs/*`.

---

## 8. Image supply chain (ECR)

- **n8n & base images:** ECR **pull-through cache** rules → pin by digest in task defs. `scan_on_push = true`, lifecycle policy to expire untagged images >7 days (per our standard ECR module).
- **Cal.com:** dedicated ECR repo per clinic (or per apex), populated by the CI build in §5a.
- Task defs reference `${account}.dkr.ecr.${region}.amazonaws.com/<repo>@<digest>`.

---

## 9. Secrets & config management

Follow our **placeholder pattern**: Terraform creates the Secrets Manager secret with `secret_string = "placeholder-populate-me"` and `lifecycle { ignore_changes = [secret_string] }`; real values are populated out-of-band (CLI/console) and read back via a `data` source. Task definitions inject them via ECS `secrets` (`valueFrom`). Cross-service values (domains, endpoints) published to SSM Parameter Store.

Secrets per clinic: RDS passwords (×2 roles), `N8N_ENCRYPTION_KEY`, `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY`, SMTP creds, any EHR/clearinghouse API keys.

---

## 10. State backend & bootstrap (`scripts/bootstrap`)

Per our standard bootstrap pattern: in each clinic account, create that account's own S3 state bucket (versioned, public-access-blocked, `prevent_destroy`), DynamoDB lock table (or rely on `use_lockfile`), the **GitHub OIDC provider**, and the `terraform-github-actions-role` / `github-ci-role` IAM roles. Run once at clinic onboarding before the first `apply`.

---

## 11. CI/CD (mirror our standard pipeline)

- **Terraform CI:** reusable `terraform-ci-template.yml` from our shared `ci-templates` repo, **matrix over clinics** (each entry = env name + clinic account role ARN + region), `tf_working_dir = envs/<clinic>`, OIDC auth. PR plan / main apply.
- **Cal.com image build:** `ecr-docker-build` workflow with `--build-arg NEXT_PUBLIC_WEBAPP_URL`, per-clinic tag, then `aws ecs update-service --force-new-deployment` (the `deploy-to-slot.yml` pattern), gated behind the Prisma migration task.
- **n8n mirror:** scheduled job to refresh the ECR pull-through cache and bump the pinned digest via PR.
- **n8n workflow library:** workflows stored as JSON in-repo, deployed to each clinic's n8n via its public API in CI, parameterized per clinic (board IDs, domains, credential names).
- Task-definition `lifecycle { ignore_changes = [task_definition] }` so CD owns image rollouts (our convention).

---

## 12. Onboarding a new clinic (the economies-of-scale payoff)

1. Create the clinic AWS account in the Org; run `scripts/bootstrap` against it.
2. `cp -r envs/_template envs/<clinic>`; edit `locals.tf` (domain, region, account ID, sizing, Multi-AZ toggle).
3. Add the clinic to the CI matrix.
4. Populate Secrets Manager placeholders.
5. CI builds the per-clinic Cal.com image; `terraform apply`.
6. Deploy the n8n workflow library to the new instance.
7. DNS: point `*.<clinic>.<apex>` at the clinic ALB.

Everything clinic-specific lives in `locals.tf` + secrets + the Cal.com build arg. The modules and workflow library are shared and versioned.

---

## 13. Implementation milestones

1. **M0 — Scaffolding:** `terraform/` skeleton, `versions.tf`, providers, bootstrap script; stand up state for the ACC account.
2. **M1 — Foundation:** `network`, `data`, `ecs_cluster`, `ingress` modules; ALB serving a placeholder 503.
3. **M2 — n8n:** `n8n_service` module live at `n8n.acc.<apex>`, Postgres-backed, S3 binary data, secrets wired.
4. **M3 — Cal.com:** ✅ `calcom_service` module — per-clinic ECR repo, Fargate service at `cal.acc.<apex>`, one-off Prisma migration task. (CI image build wiring still to land in the `.github/workflows` step.)
5. **M4 — Bedrock + chat (phase 2):** `bedrock_access` IAM; `chat_service` (LibreChat) module.
6. **M5 — Productize:** extract `envs/_template`, write onboarding runbook, dry-run a second clinic into a fresh account.
7. **M6 — Org / landing-zone (future, scaling):** stand up AWS Organizations with an account-factory so new clinic accounts come pre-hardened (baseline SCPs, GuardDuty/Config/CloudTrail, centralized logging) rather than hand-created. **Not built yet** — currently clinic accounts are assumed to exist. Likely **AWS Control Tower** or a Terraform account-factory; our per-account `scripts/bootstrap` is the first piece. Becomes important once we're onboarding clinics regularly and need governance/audit at the Org level.

---

## 14. Open decisions

- **Cal.com image strategy:** per-clinic build (simple, more images) vs single apex + wildcard proxy (fewer images, more infra). Default: per-clinic build for the PoC.
- **n8n single-instance vs queue mode:** start main-mode; define the volume threshold that triggers Redis + workers.
- **Legal:** n8n Sustainable Use vs Embed license is the main item for compliance-counsel review. Cal.com is low-risk now — just confirm we deploy the **Cal.diy MIT community edition**, not the paid commercial product, and accept owning security/patching for the unsupported edition.

---

## Sources

- [n8n Docker docs](https://docs.n8n.io/hosting/installation/docker/) · [n8n queue mode](https://docs.n8n.io/hosting/scaling/queue-mode/) · [n8n DB env vars](https://docs.n8n.io/hosting/configuration/environment-variables/database/)
- [Cal.com Docker self-hosting](https://cal.com/docs/self-hosting/docker) · [Cal.com build-time env discussion #3704](https://github.com/calcom/cal.com/discussions/3704) · [Cal.com v6.4 license change (Cal.diy / MIT)](https://cal.com/blog/calcom-v6-4) · [Cal.diy community edition](https://cal.diy/) · [Cal.com commercial license](https://i.cal.com/sales/commercial-license)
- [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/) · [Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)

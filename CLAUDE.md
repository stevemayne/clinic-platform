# CLAUDE.md

Guidance for working in this repo.

## What this is

The base installation set for standing up **HIPAA-compliant clinic environments** on AWS — self-hosted n8n (automations) + Cal.com (scheduling) + Claude via Amazon Bedrock, isolated per clinic. ACC (Andrews Counseling & Consulting) is the first tenant / proof of concept; the platform is built to replicate across many clinics.

## Documents (read these for context)

- **RECOMMENDATIONS.md** — architecture rationale: HIPAA stack, vendor compliance, EHR/billing strategy, data co-op.
- **implementation.md** — the build spec: packaging decision, module catalog, per-clinic model, milestones (M0–M6), open decisions. **The source of truth for what we're building and why.**
- **COSTS.md** — per-tenant AWS cost model (shared vs per-client).
- **TODO.md** — the live work list for picking up in a fresh session (remaining milestones, pre-apply steps, CI/CD). Check here for what's next.
- **DEPLOY.md** — ordered, copy-pasteable runbook for standing up the ACC clinic (bootstrap → two-phase apply → DB init → Cal.com image/migrate → verify). The step-by-step counterpart to TODO.md §1.
- **CALCOM_IMAGE.md** — how to source, pin, and build the per-clinic Cal.com image (build-time `NEXT_PUBLIC_WEBAPP_URL`, upstream ref pinning, ECR tagging, build resource needs). Prerequisite for DEPLOY.md §8 and the CI image-build workflow. The pinned upstream ref lives in **CALCOM_REF**.
- **terraform/** — the implementation. See `terraform/README.md`.

When a change affects architecture or cost, update the relevant doc in the same change.

## Repo layout

```
terraform/
├── modules/      network · ecs_cluster · data · ingress · n8n_service · calcom_service · chat_service
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
- **Cal.com = self-hosted Cal.diy (MIT), free — as the INTERIM scheduler, per-clinician booking links only** (decided 2026-07-18). **Team features are not buyable for self-hosted:** Cal.diy has Teams/round-robin, Organizations, Workflows/reminders, SSO, and Insights **deleted from the codebase** (verified at our pinned SHA — `packages/features/ee` doesn't exist), not license-gated; the paid path is Cal.com's hosted SaaS (~$12+/user/mo, BAA historically enterprise-tier — a compliance dead end for PHI). So: intake routing + appointment reminders live in **n8n**, and the long-term scheduler is expected from the EHR decision (Tebra/Healthie both include self-scheduling). Fallback if round-robin is needed sooner: Easy!Appointments (GPLv3, multi-provider core, needs MySQL) or roll our own. Build detail: MIT lives only on the untagged `main` branch (newest tag `v6.2.0` is still AGPLv3+ee), so we build from `main` pinned to a commit SHA (`CALCOM_REF`); see `CALCOM_IMAGE.md`. Repo renamed `calcom/cal.com` → `calcom/cal.diy`.
- **Claude via Amazon Bedrock** under the AWS BAA (one BAA covers compute + inference).
- **Chat UI = Open WebUI + LiteLLM sidecar, not LibreChat** (decided 2026-07). LibreChat hard-requires MongoDB — DocumentDB (~$60+/mo per clinic) or a self-managed mongod holding PHI — while Open WebUI runs on the existing encrypted RDS (`chatui` DB + pgvector) and reaches Bedrock via a stateless LiteLLM proxy in the same task, on task-role creds. No separate `bedrock_access` module: invoke statements live inline in the service task roles.
- **n8n is hosted at `automate.<clinic>.<apex>`, not `n8n.*`** — hostnames containing "n8n" trip Chrome's lookalike/phishing warning.
- **No Org/landing-zone layer yet** — accounts are assumed to exist; bootstrap runs inside them. This is M6 (future).

## Gotchas

- **DB roles/databases (`n8n`, `calcom`, `chatui`) are created by an app init step, not Terraform** — the RDS instance is private, so a TF Postgres provider can't reach it. Services crash-loop until the role + password (matching the corresponding secret) exist. `chatui` also needs `CREATE EXTENSION vector` (pgvector, for Open WebUI's RAG store).
- **Open WebUI persists env config to its DB on first boot** and then ignores env changes — the chat_service module sets `ENABLE_PERSISTENT_CONFIG=false` so the task definition stays authoritative. Keep it that way.
- **RDS has `deletion_protection = true` and the state bucket has `prevent_destroy`** — both block `destroy` by design.
- **n8n image** is pulled from the public registry for the PoC; ECR pull-through cache (needs a Docker Hub credential secret) is the documented production upgrade.
- **n8n binary data is in `database` mode, not S3** — S3 external storage is Enterprise-licensed (verified 2026-07); community edition refuses to start with it. The binary bucket + task-role grant remain for a future licensed upgrade (task-role auth via `N8N_EXTERNAL_STORAGE_S3_AUTH_AUTO_DETECT`, needs n8n 2.x).
- **Cal.com (M3):** `NEXT_PUBLIC_WEBAPP_URL` is baked at **build time** → CI must build a per-clinic image; Prisma migrations run as a one-off ECS task.
- **Author-identity commit guard:** `.githooks/pre-commit` blocks commits unless the author email matches the one hard-coded in the hook. It is opt-in — activate with `git config core.hooksPath .githooks`. If commits are unexpectedly rejected, that hook is why.

## Status

M0 (bootstrap) + M1 (network/ecs_cluster/data/ingress) + M2 (n8n_service) + M3 (calcom_service: per-clinic ECR repo, service, Prisma migration task) + M4 (chat_service: Open WebUI + LiteLLM → Bedrock, Google-OIDC-ready) done and validated; ACC is live. **Next: chat SSO cutover (Workspace OAuth client), n8n workflow library, then M5 — productize / second-clinic dry-run.**

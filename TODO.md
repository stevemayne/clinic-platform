# TODO

Outstanding work for the clinic platform, for picking up in a fresh session. Read [CLAUDE.md](CLAUDE.md) first, then [implementation.md](implementation.md) (build spec / milestones) and [RECOMMENDATIONS.md](RECOMMENDATIONS.md) (architecture + business decisions).

**Where we are:** M0–M3 of the Terraform are built and `validate` clean — bootstrap, `network`, `ecs_cluster`, `data`, `ingress`, `n8n_service`, `calcom_service`, wired into `envs/acc` and `envs/_template`. Nothing has been `apply`-ed to a real account yet.

---

## 1. Before any real `terraform apply`

- [ ] Create ACC's AWS account in the Org (manually for now — no landing-zone layer yet).
- [ ] Run `terraform/scripts/bootstrap` in that account: `terraform apply -var 'clinic=acc' -var 'github_repo=<owner>/acc'`.
- [ ] Put the bootstrap `state_bucket_name` output (account ID) into [terraform/envs/acc/backend.tf](terraform/envs/acc/backend.tf) (currently `tfstate-acc-000000000000`).
- [ ] Set the real domain in [terraform/envs/acc/locals.tf](terraform/envs/acc/locals.tf) (`domain_name`, currently `acc.example.com`).
- [ ] `terraform init && terraform apply` from `envs/acc`.
- [ ] Delegate the registrar's NS records to the `name_servers` output.
- [ ] Populate the Secrets Manager placeholders (see §5).

---

## 2. Terraform — remaining build

- [ ] **M4 — `bedrock_access` module:** IAM policy/role for `bedrock:InvokeModel` (n8n already has it inline in its task role; factor out / extend for the chat service and confirm region + model access is enabled in the account).
- [ ] **M4 — `chat_service` module (LibreChat or Open WebUI):** Fargate service at `chat.<domain>`, pointed at Bedrock, SSO via Google Workspace, clinical prompt templates. Mirror `n8n_service` structure.
- [ ] **M5 — Productize:** finalize `envs/_template`, write the onboarding runbook, and dry-run a second clinic into a fresh account to prove replication.
- [ ] **ECR pull-through cache for n8n** (production upgrade): add the `aws_ecr_pull_through_cache_rule` (Docker Hub upstream — needs a Docker Hub credential secret), then point `var.n8n_image` at the cache URI and pin by digest. Documented inline in [terraform/modules/n8n_service/main.tf](terraform/modules/n8n_service/main.tf).
- [ ] **Tighten the execution-role secret/KMS access** in [terraform/modules/ecs_cluster/main.tf](terraform/modules/ecs_cluster/main.tf) from `"*"` to specific secret + key ARNs.
- [ ] **Multi-AZ / HA toggle:** confirm `multi_az` + dual-NAT behave as a clean per-clinic upsell (cost ~+$75/mo).

---

## 3. CI/CD (`.github/workflows`) — not started

- [ ] **terraform-ci** workflow: matrix over clinics (env name + clinic account role ARN + region), `tf_working_dir = envs/<clinic>`, OIDC auth, PR-plan / main-apply.
- [ ] **Cal.com image build** workflow: build per-clinic image with `--build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.<clinic>.<apex>`, push to the clinic's ECR repo, run the Prisma **migrate** task (`aws ecs run-task` on the `*-calcom-migrate` task def), then `aws ecs update-service --force-new-deployment`.
- [ ] **n8n workflow library** deploy: store workflows as JSON in-repo, deploy to each clinic's n8n via its public API, parameterized per clinic (board IDs, domains, credential names).
- [ ] Stand up the shared `ci-templates` repo (or inline the reusable workflows).

---

## 4. Verify during M2/M3 testing (caveats baked into the code)

- [ ] **DB roles/databases are NOT created by Terraform.** Build the app init step (one-off task or psql) that creates the `n8n` and `calcom` databases + least-privilege roles, with passwords matching the `n8n_db_password` / `calcom_database_url` secrets. Services crash-loop until this runs.
- [ ] **n8n S3 external-storage credentials:** confirm whether n8n uses the task IAM role or requires explicit access key/secret for `N8N_EXTERNAL_STORAGE_S3_*`. Adjust [terraform/modules/n8n_service/main.tf](terraform/modules/n8n_service/main.tf) if keys are needed.
- [ ] **Cal.com health-check path + matcher:** verify `/` + `200-399` is right for the chosen image (may need `/auth/login`). See [terraform/modules/calcom_service/alb.tf](terraform/modules/calcom_service/alb.tf).
- [ ] **Cal.com migrate command:** verify `npx prisma migrate deploy --schema packages/prisma/schema.prisma` against the chosen image. See [terraform/modules/calcom_service/migrate.tf](terraform/modules/calcom_service/migrate.tf).
- [ ] **Cal.com first-apply** leaves the service unhealthy until CI pushes the image — confirm the build→migrate→deploy order works end to end.
- [ ] Confirm Bedrock model access is enabled and the `bedrock-runtime` VPC endpoint resolves from private subnets.

---

## 5. Per-clinic operational steps (onboarding runbook material)

- [ ] Populate Secrets Manager placeholders (created with `placeholder-populate-me`): `n8n_encryption_key` (**back this up — losing it bricks n8n credentials**), `n8n_db_password`, `calcom_nextauth_secret`, `calcom_encryption_key`, `calcom_database_url`.
- [ ] RDS master password is AWS-managed — use it to run the DB init step.
- [ ] Migrate ACC's existing Make.com scenarios into n8n (intake → consents → insurance verification → scheduling → discharge).

---

## 6. Open technical decisions (from implementation.md §14)

- [ ] **Cal.com image strategy:** per-clinic build (current default) vs single apex + wildcard proxy. Revisit if per-clinic build overhead bites.
- [ ] **n8n main-mode vs queue mode:** define the volume threshold that triggers Redis (ElastiCache) + worker tasks.
- [ ] **Cal.com edition:** confirm we deploy **Cal.diy MIT community edition**, not the paid commercial product; accept owning security/patching. Buy commercial license only if Teams/SSO become hard requirements.

---

## 7. Business / compliance / external (non-AWS)

- [ ] **n8n licensing:** confirm Sustainable Use vs Embed license for the managed-service model **before signing client #2**.
- [ ] **Monday.com:** verify ACC is on Enterprise with HIPAA activated + BAA (25-seat min) — otherwise the ops control center itself isn't HIPAA-covered.
- [ ] **Sign BAAs:** AWS (covers Bedrock), Google Workspace, pdf.co. Paubox already covered.
- [ ] **Calendly → Cal.com cutover** (replacement now self-hosted; compliance is ours).
- [ ] **EHR decision:** run the Tebra demo + validate Healthie (API tier, cost, BAA, claim-submission path). Decide whether to migrate ACC. (Kipu only if SUD/residential; AdvancedMD if billing depth dominates.)
- [ ] **Billing decision:** OfficeAlly call — API docs, per-transaction pricing, Medicaid enrollment; compare against EHR-native RCM on a per-claim basis. Build the 837 submit → 276/277 status → 835 denial-analysis loop.
- [ ] Engage compliance counsel for reusable BAA/DUA templates.

---

## 8. Future phases

- [ ] **M6 — Org / landing-zone layer:** AWS Organizations + account-factory (Control Tower or Terraform) so new clinic accounts come pre-hardened (baseline SCPs, GuardDuty/Config/CloudTrail, centralized logging). Currently accounts are assumed to exist; our per-account bootstrap is the first piece.
- [ ] **Data co-op / clean room:** separate AWS account, HIPAA Expert Determination de-identification, cross-clinic benchmarking. Keep the per-clinic data model consistent now to preserve the option. Demand-create when there's clinic appetite.

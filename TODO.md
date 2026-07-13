# TODO

Outstanding work for the clinic platform, for picking up in a fresh session. Read [CLAUDE.md](CLAUDE.md) first, then [implementation.md](implementation.md) (build spec / milestones) and [RECOMMENDATIONS.md](RECOMMENDATIONS.md) (architecture + business decisions).

**Where we are:** M0–M4 of the Terraform are built and `validate` clean — bootstrap, `network`, `ecs_cluster`, `data`, `ingress`, `n8n_service`, `calcom_service`, `chat_service` (Open WebUI + LiteLLM → Bedrock), wired into `envs/acc` and `envs/_template`. ACC (`185818464031`) is live: n8n at `automate.acc.secureclinic.co` (renamed from `n8n.*` — Chrome phishing heuristic), Cal.com, and chat deployed — temporarily downsized to the AWS free plan (see §1).

---

## 1. Before any real `terraform apply`

> The steps below are expanded into an ordered, copy-pasteable runbook in [DEPLOY.md](DEPLOY.md) (with the real ACC values: account `185818464031`, domain `acc.secureclinic.co`).

- [x] Create ACC's AWS account in the Org (manually for now — no landing-zone layer yet).
- [x] Run `terraform/scripts/bootstrap` in that account: `terraform apply -var 'clinic=acc' -var 'github_repo=stevemayne/clinic-platform'` (applied 2026-07 — OIDC provider, both CI roles, state bucket verified).
- [x] Put the bootstrap `state_bucket_name` output (account ID) into [terraform/envs/acc/backend.tf](terraform/envs/acc/backend.tf) (`tfstate-acc-185818464031`).
- [ ] **Revert the temporary free-plan RDS sizing** in [terraform/envs/acc/locals.tf](terraform/envs/acc/locals.tf) (`db.t4g.micro`, 20 GB, autoscaling off, 1-day backups, Performance Insights off) once the account moves off the AWS free plan — **before real PHI lands**: 1-day backup retention is below the platform's HIPAA posture. The `data` module defaults are the production values; deleting the override block restores them.
- [x] Set the real domain in [terraform/envs/acc/locals.tf](terraform/envs/acc/locals.tf) — `domain_name = "acc.secureclinic.co"` (apex `secureclinic.co`, registered, DNS at GoDaddy).
- [ ] **Two-phase apply** (ACM validation runs in-apply, so the zone must exist and be delegated first): (a) `terraform apply -target=aws_route53_zone.public` to create the zone and emit `name_servers`; (b) in **GoDaddy DNS for `secureclinic.co`**, add an `NS` record for host `acc` → the 4 zone name servers, wait for propagation; (c) `terraform apply` for the rest.
- [ ] **Google Workspace OAuth client (M4/chat):** ACC's Workspace admin creates an OpenID Connect / OAuth 2.0 client in ACC's Google Cloud project (consent screen = Internal), redirect URI `https://chat.acc.secureclinic.co/oauth/oidc/callback` (the `chat_oidc_redirect_uri` output — Open WebUI's generic-OIDC path, not `/oauth/google/callback` as originally speced); client secret → `acc/chat_oauth_client_secret`, client ID + Workspace domain → `chat_oauth_client_id` / `chat_oauth_allowed_domains` in `envs/acc/locals.tf`, then apply + `update-service` (DEPLOY.md §11). **Until then chat runs with local login — claim the admin account.** Per-clinic onboarding dependency.
- [ ] Populate the Secrets Manager placeholders (see §5).

---

## 2. Terraform — remaining build

- [x] **M4 — Bedrock access:** no separate `bedrock_access` module — `bedrock:InvokeModel` statements live inline in the n8n + chat task roles (scoped to Anthropic foundation-model + inference-profile ARNs), plus the `<clinic>-n8n-bedrock` IAM user for n8n's key-based credential. Model access confirmed enabled in the ACC account (2026-07).
- [x] **M4 — `chat_service` module:** built 2026-07 — **Open WebUI** (not LibreChat: it hard-requires MongoDB → DocumentDB ~$60+/mo or self-managed mongod holding PHI; Open WebUI reuses the encrypted RDS — `chatui` DB + pgvector RAG store) with a **LiteLLM sidecar** proxying OpenAI-compatible calls to Bedrock (model list = Terraform-owned S3 config object; task-role creds, no keys). Fargate service at `chat.<domain>`, mirrors `n8n_service` structure.
  - Auth = **Google Workspace via generic OIDC** (`OAUTH_*`/`OPENID_*`, issuer `https://accounts.google.com`), SSO-only once `chat_oauth_client_id` is set (local-login bootstrap until then), `OAUTH_ALLOWED_DOMAINS` = Workspace domain, JIT provisioning. Redirect URI = `/oauth/oidc/callback` (see §1 item). Secrets: `chat_database_url`, `chat_webui_secret_key`, `chat_oauth_client_secret`, `chat_litellm_master_key`.
  - Clinical prompt templates still to be loaded (Open WebUI workspace prompts/models) — onboarding-runbook material.
  - **Note:** Google SSO is free in Open WebUI; Cal.com SSO is a commercial-license feature and n8n SSO is Enterprise-tier — don't assume one login spans all three apps for free.
- [ ] **M5 — Productize:** finalize `envs/_template`, write the onboarding runbook, and dry-run a second clinic into a fresh account to prove replication.
- [ ] **ECR pull-through cache for n8n** (production upgrade): add the `aws_ecr_pull_through_cache_rule` (Docker Hub upstream — needs a Docker Hub credential secret), then point `var.n8n_image` at the cache URI and pin by digest. Documented inline in [terraform/modules/n8n_service/main.tf](terraform/modules/n8n_service/main.tf).
- [ ] **Tighten the execution-role secret/KMS access** in [terraform/modules/ecs_cluster/main.tf](terraform/modules/ecs_cluster/main.tf) from `"*"` to specific secret + key ARNs.
- [ ] **Multi-AZ / HA toggle:** confirm `multi_az` + dual-NAT behave as a clean per-clinic upsell (cost ~+$75/mo).

---

## 3. CI/CD (`.github/workflows`) — not started

- [x] **terraform-ci** workflow — drafted at [.github/workflows/terraform-ci.yml](.github/workflows/terraform-ci.yml): credential-less fmt + backendless validate of every env + bootstrap, then per-clinic matrix (ACC only today) OIDC → `terraform-github-actions-role`, plan on PRs (published to the run summary), apply of the saved plan on main. Serialized per clinic via concurrency groups. OIDC role assumption verified against the real ACC account (2026-07, via the calcom-image workflow using the same bootstrap-created providers); the plan/apply path itself hasn't run on a push to main yet. A clinic's *first* apply stays manual (bootstrap + two-phase zone delegation, DEPLOY.md §3–5) — CI takes over from the second apply. Consider gating apply behind a GitHub `production` environment approval later.
- [x] **Cal.com image build** workflow — drafted at [.github/workflows/calcom-image.yml](.github/workflows/calcom-image.yml): OIDC → `github-ci-role`, builds from the pinned `CALCOM_REF` SHA (MIT-license guard), pushes `:latest` + `:main-<sha>` to the clinic's ECR, gates on the Prisma migrate task exit code, then force-new-deployment + wait for stable. Matrixed over clinics (ACC only today). **Verified end-to-end against ACC (2026-07)** — build → ECR push → migrate gate → deploy all green on `ubuntu-latest` (build RAM was fine; revisit runner size only if it OOMs).
- [ ] **n8n workflow library** deploy: store workflows as JSON in-repo, deploy to each clinic's n8n via its public API, parameterized per clinic (board IDs, domains, credential names).
- [ ] Stand up the shared `ci-templates` repo (or inline the reusable workflows).

---

## 4. Verify during M2/M3 testing (caveats baked into the code)

- [x] **DB roles/databases are NOT created by Terraform.** Done for ACC (2026-07) via a one-off Fargate task (`postgres:17-alpine`, private subnets, `acc-ecs-sg`, passwords injected via ECS `secrets`); SQL per DEPLOY.md §7 — note the `GRANT <role> TO postgres` now documented there (required on RDS PG 16+). The `chatui` DB additionally needs `CREATE EXTENSION vector` (pgvector, for Open WebUI's RAG store).
- [x] **n8n binary-data storage:** S3 external storage turned out to be **Enterprise-licensed** (verified 2026-07 on 2.29.10) — community edition refuses to start with it. Now using n8n 2.x `database` mode (binary data in the encrypted RDS; persistent, unlicensed). The binary bucket + task-role S3 grant remain for a future licensed upgrade — mechanism confirmed: `N8N_EXTERNAL_STORAGE_S3_AUTH_AUTO_DETECT=true` (task IAM role, needs 2.x). See [terraform/modules/n8n_service/main.tf](terraform/modules/n8n_service/main.tf).
- [x] **Cal.com health-check path + matcher:** verified — `/` returns 307 (→ `/auth/login`), which the `200-399` matcher accepts.
- [x] **Cal.com migrate command:** verified against the pinned image — needed `DATABASE_DIRECT_URL` set alongside `DATABASE_URL` (both from the same secret; no pooler).
- [x] **Cal.com first-apply** build→migrate→deploy order confirmed end to end via the calcom-image workflow (2026-07); setup wizard reachable at `/auth/setup`.
- [ ] Confirm Bedrock model access is enabled and the `bedrock-runtime` VPC endpoint resolves from private subnets. (Model access confirmed 2026-07 with a live invoke; the VPC-endpoint path gets verified by the first chat/n8n Bedrock call from a task.)
- [ ] **Harden DB TLS verification:** all three apps connect to RDS over TLS but skip certificate verification (`PGSSLMODE=no-verify` for Cal.com, `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false` for n8n, `sslmode=require` for chat) because the RDS CA bundle isn't in the images' trust store. Ship the bundle (bake into image or mount) and switch to verified TLS.
- [ ] **Chat scale-out caveat:** `chat_service` is pinned to `desired_count = 1` — Open WebUI needs a Redis broker + sticky sessions to run multiple replicas. Fine for a single clinic; revisit if a large clinic needs HA chat.

---

## 5. Per-clinic operational steps (onboarding runbook material)

- [x] Populate Secrets Manager placeholders — done for ACC (2026-07), including the chat secrets (`chat_database_url` with `?sslmode=require`, `chat_webui_secret_key`, `chat_litellm_master_key`). `calcom_database_url` carries `?sslmode=no-verify` (see the DB-TLS hardening item in §4). `chat_oauth_client_secret` is still the placeholder — populated at SSO cutover (DEPLOY.md §11). **Still outstanding: back up `acc/n8n_encryption_key` outside AWS — losing it bricks n8n credentials.**
- [x] RDS master password is AWS-managed — used for the ACC DB init step.
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

# DEPLOY.md — ACC first deployment runbook

Ordered, copy-pasteable steps to stand up the **acc** clinic (`envs/acc`) from nothing to a running n8n + Cal.com + chat (Open WebUI). Read [CLAUDE.md](CLAUDE.md) and [implementation.md](implementation.md) first for the why; this file is the how.

The chat service deploys with everything else in Phase B; its Google Workspace SSO cutover is a separate post-deploy step ([§11](#11-chat-open-webui--google-workspace-sso)) gated on the clinic's Workspace admin creating the OAuth client.

## Facts for this clinic

| | |
|---|---|
| Clinic slug | `acc` |
| AWS account | `185818464031` |
| AWS CLI profile | `acc` |
| Region | `us-east-1` |
| Clinic domain | `acc.secureclinic.co` |
| Apex (DNS at GoDaddy) | `secureclinic.co` |
| State bucket (deterministic) | `tfstate-acc-185818464031` |
| Service URLs | `automate.acc.secureclinic.co` (n8n) · `cal.acc.secureclinic.co` · `chat.acc.secureclinic.co` |

Every AWS CLI call below assumes `--profile acc --region us-east-1`. Every Terraform call runs from `terraform/envs/acc` unless stated.

> **Convention:** RDS has `deletion_protection = true` and the state bucket has `prevent_destroy` — both block `destroy` by design. Secrets use the placeholder pattern: Terraform creates them as `placeholder-populate-me` and ignores the value afterward, so populating/rotating them out-of-band never fights Terraform.

---

## 0. Prerequisites (external / one-time)

- [ ] **AWS BAA signed** for the ACC account — gate for any PHI. One BAA covers compute, storage, and Bedrock inference.
- [ ] **Bedrock model access enabled** in `us-east-1` for the Claude models you'll use (Bedrock console → Model access). Needed by n8n's Bedrock credential and the chat service's LiteLLM proxy (models pinned in the `chat_service` module's `bedrock_models` variable).
- [ ] **CLI profile `acc`** resolves to account `185818464031`:
  ```bash
  aws sts get-caller-identity --profile acc
  ```
- [ ] **Apex `secureclinic.co`** is registered with DNS at GoDaddy (confirmed). You need access to edit its DNS records for [§4](#4-delegate-the-subdomain-at-godaddy).

---

## 1. Bootstrap the account (state bucket + CI OIDC roles)

One-time per account, run on **local state** (this is the chicken-and-egg root that creates the backend everything else uses).

```bash
cd terraform/scripts/bootstrap
terraform init
terraform apply \
  -var 'clinic=acc' \
  -var 'github_repo=<owner>/clinic-platform'  # this repo (owner/name) — the workflows run from here, not from a per-clinic repo
```

Confirm the output:

```bash
terraform output state_bucket_name    # expect: tfstate-acc-185818464031
```

---

## 2. Point the env backend at the state bucket

Edit [terraform/envs/acc/backend.tf](terraform/envs/acc/backend.tf): change the placeholder bucket to the real one.

```hcl
bucket = "tfstate-acc-185818464031"   # was tfstate-acc-000000000000
```

Then initialise the env against its remote backend:

```bash
cd terraform/envs/acc
terraform init
```

---

## 3. Phase-A apply — create the hosted zone only

ACM certificate validation runs **inside** the apply and blocks until DNS resolves publicly. A brand-new zone isn't delegated yet, so we create the zone first, delegate it, then apply the rest.

```bash
terraform apply -target=aws_route53_zone.public
terraform output name_servers          # 4 AWS name servers — copy these
```

---

## 4. Delegate the subdomain at GoDaddy

In **GoDaddy's DNS for `secureclinic.co`**, add an `NS` record set:

- **Host / name:** `acc`
- **Type:** `NS`
- **Value:** the 4 name servers from `terraform output name_servers` (one per record, no trailing dot issues per GoDaddy's UI)

Wait for propagation, then verify:

```bash
dig +short NS acc.secureclinic.co      # should return the 4 AWS name servers
```

Don't proceed until this resolves — otherwise the Phase-B apply hangs on ACM validation (~45 min) and fails.

---

## 5. Phase-B apply — everything else

```bash
terraform apply
```

This creates the VPC, RDS, ALB + wildcard cert (now validates), ECR repo, and the n8n + Cal.com + chat services. The services will **crash-loop** until the DB roles, secrets, and (for Cal.com) the image exist — that's expected, and the apply itself won't wait on steady state. Capture the outputs:

```bash
terraform output
# note: db_address, db_master_secret_arn, calcom_ecr_repository_url,
#       ecs_cluster_name, n8n_url, calcom_url, chat_url,
#       chat_oidc_redirect_uri, n8n_bedrock_user_name
```

---

## 6. Populate the Secrets Manager placeholders

Nine secrets, named `acc/<key>`. Generate strong random values; **back up `acc/n8n_encryption_key`** — losing it bricks all stored n8n credentials. (`acc/chat_oauth_client_secret` is the exception: its value comes from the Google OAuth client in [§11](#11-chat-open-webui--google-workspace-sso), not from openssl.)

```bash
# Pick/generate values first (examples use openssl):
N8N_ENC=$(openssl rand -hex 32)
N8N_DB_PW=$(openssl rand -base64 24 | tr -d '/+=')
CAL_NEXTAUTH=$(openssl rand -hex 32)
CAL_ENC=$(openssl rand -base64 32)
CAL_DB_PW=$(openssl rand -base64 24 | tr -d '/+=')
CHAT_DB_PW=$(openssl rand -base64 24 | tr -d '/+=')
CHAT_WEBUI_KEY=$(openssl rand -hex 32)
LITELLM_KEY=sk-$(openssl rand -hex 24)   # LiteLLM requires the sk- prefix

DB_HOST=$(terraform output -raw db_address)

aws secretsmanager put-secret-value --secret-id acc/n8n_encryption_key     --secret-string "$N8N_ENC"      --profile acc --region us-east-1
aws secretsmanager put-secret-value --secret-id acc/n8n_db_password        --secret-string "$N8N_DB_PW"    --profile acc --region us-east-1
aws secretsmanager put-secret-value --secret-id acc/calcom_nextauth_secret --secret-string "$CAL_NEXTAUTH" --profile acc --region us-east-1
aws secretsmanager put-secret-value --secret-id acc/calcom_encryption_key  --secret-string "$CAL_ENC"      --profile acc --region us-east-1
# sslmode=no-verify is required: RDS defaults rds.force_ssl=1 and Cal.com's
# node-postgres driver won't use TLS without it (Prisma migrate ignores the
# unknown value and TLSes anyway). TLS on, cert verification off — see the
# DB-TLS hardening item in TODO.md §4.
aws secretsmanager put-secret-value --secret-id acc/calcom_database_url \
  --secret-string "postgresql://calcom:${CAL_DB_PW}@${DB_HOST}:5432/calcom?sslmode=no-verify" \
  --profile acc --region us-east-1

# Chat (Open WebUI + LiteLLM). sslmode=require: SQLAlchemy/psycopg2 speaks
# libpq, which accepts require (TLS on, cert verification off — same
# hardening TODO as above).
aws secretsmanager put-secret-value --secret-id acc/chat_database_url \
  --secret-string "postgresql://chatui:${CHAT_DB_PW}@${DB_HOST}:5432/chatui?sslmode=require" \
  --profile acc --region us-east-1
aws secretsmanager put-secret-value --secret-id acc/chat_webui_secret_key   --secret-string "$CHAT_WEBUI_KEY" --profile acc --region us-east-1
aws secretsmanager put-secret-value --secret-id acc/chat_litellm_master_key --secret-string "$LITELLM_KEY"    --profile acc --region us-east-1
```

The `calcom`/`chatui` role passwords are embedded in their `*_database_url` secrets and must match the roles you create in [§7](#7-create-the-database-roles--databases). The `n8n` role uses `acc/n8n_db_password`.

---

## 7. Create the database roles + databases

RDS is private and Terraform can't reach it, so the `n8n` and `calcom` roles/databases are created by hand as the **app init step**. Connect as the AWS-managed master (`postgres`) from inside the VPC.

Get the master password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw db_master_secret_arn)" \
  --query SecretString --output text --profile acc --region us-east-1
# → JSON {"username":"postgres","password":"..."}
```

Reach the private DB from within the VPC — either SSM port-forward through a bastion, or a one-off Fargate task running a `postgres` client image in the **private subnets** on the **`acc-ecs-sg`** security group (which RDS allows on 5432). Discover the network config:

```bash
PRIV=$(aws ec2 describe-subnets --profile acc --region us-east-1 \
  --filters 'Name=tag:Name,Values=acc-vpc-private-*' \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
ECSSG=$(aws ec2 describe-security-groups --profile acc --region us-east-1 \
  --filters 'Name=group-name,Values=acc-ecs-sg' \
  --query 'SecurityGroups[0].GroupId' --output text)
echo "subnets=$PRIV  ecs_sg=$ECSSG"
```

Then run this SQL as `postgres` (passwords must match the secrets from §6):

```sql
CREATE ROLE n8n LOGIN PASSWORD '<value of acc/n8n_db_password>';
GRANT n8n TO postgres;          -- RDS PG 16+: master must be a member to create a DB owned by the role
CREATE DATABASE n8n OWNER n8n;
REVOKE n8n FROM postgres;

CREATE ROLE calcom LOGIN PASSWORD '<the CAL_DB_PW embedded in calcom_database_url>';
GRANT calcom TO postgres;
CREATE DATABASE calcom OWNER calcom;
REVOKE calcom FROM postgres;

CREATE ROLE chatui LOGIN PASSWORD '<the CHAT_DB_PW embedded in chat_database_url>';
GRANT chatui TO postgres;
CREATE DATABASE chatui OWNER chatui;
REVOKE chatui FROM postgres;
```

Then, **connected to the `chatui` database** (`\c chatui` or a second psql invocation), enable pgvector — Open WebUI's RAG store (`VECTOR_DB=pgvector`) needs it:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

> The exact connection mechanism (bastion vs one-off task) is a testing-time decision — the modules intentionally leave DB init out of Terraform. Whatever you choose, it must sit in the VPC on `acc-ecs-sg`.

---

## 8. Build + push the Cal.com image, then migrate

Cal.com bakes `NEXT_PUBLIC_WEBAPP_URL` at **build time**, so the image is per-clinic. The ECR repo was created empty by the Phase-B apply. **See [CALCOM_IMAGE.md](CALCOM_IMAGE.md) for how to source, pin, and build the image** (version pinning, full build-arg list, resource needs) — the snippet below is the short form.

```bash
# Source the pinned upstream ref (repo + SHA) — see CALCOM_REF / CALCOM_IMAGE.md.
source ../../../CALCOM_REF                # CALCOM_REPO, CALCOM_SHA  (adjust path to repo root)
git clone "$CALCOM_REPO" /tmp/cal.diy && git -C /tmp/cal.diy checkout "$CALCOM_SHA"
TAG=main-$(git -C /tmp/cal.diy rev-parse --short HEAD)   # → main-f004349

ECR=$(terraform output -raw calcom_ecr_repository_url)
aws ecr get-login-password --profile acc --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR%/*}"

docker build -f /tmp/cal.diy/Dockerfile \
  --build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.acc.secureclinic.co \
  --build-arg CALCOM_TELEMETRY_DISABLED=1 \
  --build-arg DATABASE_URL=postgresql://build:build@localhost:5432/build \
  -t "$ECR:latest" -t "$ECR:$TAG" /tmp/cal.diy
docker push "$ECR:latest" && docker push "$ECR:$TAG"
```
(The `DATABASE_URL` build arg is a **throwaway** — needed only for Prisma generate during the build; real secrets are injected at runtime. `NEXTAUTH_SECRET`/`CALENDSO_ENCRYPTION_KEY` use their dummy build defaults. Needs ~8 GB RAM for the build.)

Run the one-off Prisma migration task (needs the `calcom` DB from §7 and `acc/calcom_database_url` from §6), using the `$PRIV`/`$ECSSG` from §7:

```bash
CLUSTER=$(terraform output -raw ecs_cluster_name)
aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE \
  --task-definition acc-calcom-migrate \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV],securityGroups=[$ECSSG],assignPublicIp=DISABLED}" \
  --profile acc --region us-east-1
```

Then roll the service onto the freshly-pushed image:

```bash
aws ecs update-service --cluster "$CLUSTER" --service acc-calcom \
  --force-new-deployment --profile acc --region us-east-1
```

---

## 9. Recover n8n and verify

n8n uses the public image (no build needed); once its DB role and secrets exist it recovers on the next task retry, or force it:

```bash
aws ecs update-service --cluster "$CLUSTER" --service acc-n8n \
  --force-new-deployment --profile acc --region us-east-1
```

Verify both services reach steady state and the URLs serve over TLS:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services acc-n8n acc-calcom \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount}' \
  --profile acc --region us-east-1

curl -sI https://automate.acc.secureclinic.co | head -1
curl -sI https://cal.acc.secureclinic.co | head -1
```

(n8n lives at `automate.*`, not `n8n.*` — hostnames containing "n8n" trip Chrome's lookalike/phishing warning.)

Deployment complete for n8n + Cal.com.

---

## 10. n8n Bedrock credential (for AI workflow nodes)

Terraform creates a per-clinic IAM user (`acc-n8n-bedrock`, in the `n8n_service` module) scoped to invoking Anthropic models. n8n's AWS credential type only supports access key/secret — the task IAM role can't be used for workflow credentials — so create the key out-of-band (it never lives in code or state, same philosophy as the secrets placeholders):

```bash
aws iam create-access-key \
  --user-name "$(terraform output -raw n8n_bedrock_user_name)" \
  --profile acc --region us-east-1
# → AccessKeyId + SecretAccessKey (shown once)
```

In n8n: **Credentials → New → AWS**, paste the key pair, region `us-east-1`. Then use the **AWS Bedrock Chat Model** node (attached to an AI Agent / Basic LLM Chain). Model IDs must be **cross-region inference profiles** (`us.anthropic.*` — bare `anthropic.*` IDs are rejected for on-demand invocation): `us.anthropic.claude-opus-4-8` as the default, `us.anthropic.claude-haiku-4-5-20251001-v1:0` for cheap/high-volume steps. Traffic from the tasks reaches Bedrock via the private `bedrock-runtime` VPC endpoint; the first workflow call verifies that path end to end.

Rotate by creating a second key, updating the n8n credential, then deleting the old key.

---

## 11. Chat (Open WebUI) — Google Workspace SSO

The `chat_service` module (Open WebUI + a LiteLLM sidecar proxying to Bedrock) deploys with the Phase-B apply; it needs the `chatui` database from §7 and the three `chat_*` secrets from §6. Both containers use the **task role** for Bedrock and S3 — no access keys. Verify it's up:

```bash
curl -sI https://chat.acc.secureclinic.co | head -1   # expect 200
```

**Until SSO is configured, the chat UI runs with local email/password login — the first account to sign up becomes admin. Claim it immediately.**

To flip to SSO-only:

1. **ACC Workspace admin** creates an OAuth 2.0 client in ACC's Google Cloud project (consent screen = **Internal** — this alone restricts sign-in to ACC's Workspace), redirect URI:

   ```bash
   terraform output -raw chat_oidc_redirect_uri
   # → https://chat.acc.secureclinic.co/oauth/oidc/callback
   ```

   (Open WebUI's generic-OIDC callback path — note it is `/oauth/oidc/callback`, not the `/oauth/google/callback` path the original spec guessed.)

2. Populate the client secret and set the non-sensitive config in [terraform/envs/acc/locals.tf](terraform/envs/acc/locals.tf) (`chat_oauth_client_id`, `chat_oauth_allowed_domains` = ACC's Workspace email domain):

   ```bash
   aws secretsmanager put-secret-value --secret-id acc/chat_oauth_client_secret \
     --secret-string '<client secret from Google Cloud>' --profile acc --region us-east-1
   ```

3. `terraform apply` (registers a new task-definition revision — local login off, OIDC on), then point the service at it:

   ```bash
   aws ecs update-service --cluster "$CLUSTER" --service acc-chat \
     --task-definition acc-chat --force-new-deployment --profile acc --region us-east-1
   ```

New SSO users are provisioned just-in-time as regular users; the pre-SSO local admin merges into its SSO identity by email. Google sees identity claims only — no PHI crosses to Google.

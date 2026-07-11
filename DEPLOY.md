# DEPLOY.md — ACC first deployment runbook

Ordered, copy-pasteable steps to stand up the **acc** clinic (`envs/acc`) from nothing to a running n8n + Cal.com. Read [CLAUDE.md](CLAUDE.md) and [implementation.md](implementation.md) first for the why; this file is the how.

The **chat service (M4)** and its Google Workspace OIDC auth are **not built yet** — see [§10](#10-deferred--m4-chat--google-workspace-oidc). This runbook deploys n8n + Cal.com only.

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
| Service URLs | `n8n.acc.secureclinic.co` · `cal.acc.secureclinic.co` · `chat.acc.secureclinic.co` (M4) |

Every AWS CLI call below assumes `--profile acc --region us-east-1`. Every Terraform call runs from `terraform/envs/acc` unless stated.

> **Convention:** RDS has `deletion_protection = true` and the state bucket has `prevent_destroy` — both block `destroy` by design. Secrets use the placeholder pattern: Terraform creates them as `placeholder-populate-me` and ignores the value afterward, so populating/rotating them out-of-band never fights Terraform.

---

## 0. Prerequisites (external / one-time)

- [ ] **AWS BAA signed** for the ACC account — gate for any PHI. One BAA covers compute, storage, and Bedrock inference.
- [ ] **Bedrock model access enabled** in `us-east-1` for the Claude models you'll use (Bedrock console → Model access). Needed by n8n's Bedrock calls now and the chat service in M4.
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
  -var 'github_repo=<owner>/acc'      # the GitHub repo allowed to assume CI roles
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

This creates the VPC, RDS, ALB + wildcard cert (now validates), ECR repo, and the n8n + Cal.com services. The services will **crash-loop** until the DB roles, secrets, and (for Cal.com) the image exist — that's expected, and the apply itself won't wait on steady state. Capture the outputs:

```bash
terraform output
# note: db_address, db_master_secret_arn, calcom_ecr_repository_url,
#       ecs_cluster_name, n8n_url, calcom_url
```

---

## 6. Populate the Secrets Manager placeholders

Five secrets, named `acc/<key>`. Generate strong random values; **back up `acc/n8n_encryption_key`** — losing it bricks all stored n8n credentials.

```bash
# Pick/generate values first (examples use openssl):
N8N_ENC=$(openssl rand -hex 32)
N8N_DB_PW=$(openssl rand -base64 24 | tr -d '/+=')
CAL_NEXTAUTH=$(openssl rand -hex 32)
CAL_ENC=$(openssl rand -base64 32)
CAL_DB_PW=$(openssl rand -base64 24 | tr -d '/+=')

DB_HOST=$(terraform output -raw db_address)

aws secretsmanager put-secret-version --secret-id acc/n8n_encryption_key     --secret-string "$N8N_ENC"      --profile acc --region us-east-1
aws secretsmanager put-secret-version --secret-id acc/n8n_db_password        --secret-string "$N8N_DB_PW"    --profile acc --region us-east-1
aws secretsmanager put-secret-version --secret-id acc/calcom_nextauth_secret --secret-string "$CAL_NEXTAUTH" --profile acc --region us-east-1
aws secretsmanager put-secret-version --secret-id acc/calcom_encryption_key  --secret-string "$CAL_ENC"      --profile acc --region us-east-1
aws secretsmanager put-secret-version --secret-id acc/calcom_database_url \
  --secret-string "postgresql://calcom:${CAL_DB_PW}@${DB_HOST}:5432/calcom" \
  --profile acc --region us-east-1
```

The `calcom` role password is embedded in `calcom_database_url` and must match the role you create in [§7](#7-create-the-database-roles--databases). The `n8n` role uses `acc/n8n_db_password`.

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
CREATE DATABASE n8n OWNER n8n;

CREATE ROLE calcom LOGIN PASSWORD '<the CAL_DB_PW embedded in calcom_database_url>';
CREATE DATABASE calcom OWNER calcom;
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

curl -sI https://n8n.acc.secureclinic.co | head -1
curl -sI https://cal.acc.secureclinic.co | head -1
```

Deployment complete for n8n + Cal.com.

---

## 10. Deferred — M4 chat + Google Workspace OIDC

Not built yet (see [TODO.md](TODO.md) §2 and [implementation.md](implementation.md) M4). When the `chat_service` module lands, the added steps are:

- **ACC Workspace admin** creates an OpenID Connect / OAuth 2.0 client in ACC's Google Cloud project (consent screen = **Internal**), redirect URI `https://chat.acc.secureclinic.co/oauth/google/callback`.
- Add a `chat_oauth_client_secret` Secrets Manager placeholder and populate it with the client secret (client ID is non-sensitive config).
- Configure LibreChat's generic `OPENID_*` provider: issuer `https://accounts.google.com`, scopes `openid email profile`, **SSO-only** (disable local signup), restrict by validating the `hd` claim = ACC's Workspace domain.

Google sees identity claims only — no PHI crosses to Google.

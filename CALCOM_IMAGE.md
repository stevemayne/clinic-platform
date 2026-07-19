# CALCOM_IMAGE.md — sourcing, pinning, and building the Cal.com image

The prerequisite behind [DEPLOY.md](DEPLOY.md) §8 and the CI "Cal.com image build" workflow in [TODO.md](TODO.md) §3. Cal.com bakes `NEXT_PUBLIC_WEBAPP_URL` at **build time**, so there is no generic prebuilt image we can use — we build **one image per clinic domain** from pinned upstream source and push it to that clinic's ECR repo.

## Why we build from source (not a prebuilt tag)

`NEXT_PUBLIC_WEBAPP_URL` is inlined into the Next.js bundle at build time and cannot be fully overridden at runtime. The module sets it at runtime too as a best-effort fallback ([calcom_service/main.tf:8-13](terraform/modules/calcom_service/main.tf#L8-L13)), but the authoritative value is the build arg. So each clinic's URL (`https://cal.acc.secureclinic.co`) requires its own build.

## Source & licensing (verified 2026-07-05)

- **Upstream:** the monorepo formerly at `calcom/cal.com`, **renamed to `calcom/cal.diy`** (old URLs still redirect; Docker Hub image is still `calcom/cal.com`). We build with its **official root-level `Dockerfile`** (multi-stage, Node 20, yarn/Turbo) — the old separate `calcom/docker` repo is legacy.
- **The licensing catch (resolved — see [§ Chosen ref](#chosen-ref-decided-2026-07-11)):** the April-2026 relicensing to **MIT ("Cal.diy")** is real, but it currently lives **only on the untagged `main` branch**. The newest *tagged / Docker-published* release is **`v6.2.0` (2026-03-01), which is still AGPLv3 + the `ee/` commercial-license directories.** There is no MIT-licensed *tag* yet, so "pin to MIT" and "pin to a stable tag" are mutually exclusive today. **We pinned `main@<sha>` for MIT.**
- **Feature boundary (resolved 2026-07-18):** in Cal.diy the enterprise features aren't license-gated — they're **gone from the codebase**. Verified at our pinned SHA: `packages/features/ee` does not exist; Teams/round-robin, Organizations, Workflows/reminders, SSO, and Insights are all removed. Nothing to accidentally "enable"; there is also **no self-hosted commercial upgrade path** (Teams exists only in Cal.com's hosted SaaS). We run per-clinician booking as the interim scheduler; routing + reminders live in n8n (see [CLAUDE.md](CLAUDE.md) "Decisions already made").

## Chosen ref (decided 2026-07-11)

**Option A — MIT via `main` pinned to a commit SHA.** Recorded in the top-level [CALCOM_REF](CALCOM_REF) file:

- **Repo:** `https://github.com/calcom/cal.diy.git`
- **SHA:** `f00434927386c9ecdcbd7e6c5f82d22044a245bc` (main HEAD, 2026-07-09)
- **License at this SHA:** MIT (verified 2026-07-11)
- **ECR image tag:** `main-f004349`

This honors the CLAUDE.md "Cal.diy MIT" decision and avoids AGPL entirely. The trade-off accepted: `main` is an untagged branch, so there's no "stable release" assurance — reproducibility comes from the pinned SHA. **Bumping Cal.com = update `CALCOM_SHA` in [CALCOM_REF](CALCOM_REF), then re-verify the LICENSE at the new SHA is still MIT before building.** CI checks out upstream at that SHA at build time — **the monorepo is not vendored.**

_Alternatives considered and rejected: `v6.2.0` (newest tag, but AGPLv3+ee — heavier legal story, contradicts the MIT decision); waiting for a post-relicense MIT tag (none exists yet, would block the deploy)._

**ECR tagging:** push `:latest` (what the task defs pull by default via `var.image_tag`) **and** an immutable `:<calcom-ref>` (the tag, or `main-<short-sha>`). Optionally pin the service to the image **digest**. The ECR repo is `MUTABLE` today ([calcom_service/ecr.tf:10](terraform/modules/calcom_service/ecr.tf#L10)); the ref/digest tag gives immutability in practice.

**Same image serves both the service and the migration task** ([migrate.tf:22](terraform/modules/calcom_service/migrate.tf#L22)) — so the Prisma schema always matches the running code. Never build them separately.

## Build inputs — the contract with the running service

The module already fixes the runtime contract, so the build has exactly **one per-clinic input**:

| Value | Where it's set | Per-clinic? |
|---|---|---|
| `NEXT_PUBLIC_WEBAPP_URL` | **build arg** (this doc) + runtime fallback | **Yes** — `https://cal.<clinic>.<apex>` |
| `NEXTAUTH_URL` | runtime env | derived (`https://cal.<clinic>.<apex>`) |
| `DATABASE_URL` | runtime secret `acc/calcom_database_url` | yes, but not a build input |
| `NEXTAUTH_SECRET` | runtime secret `acc/calcom_nextauth_secret` | yes, but not a build input |
| `CALENDSO_ENCRYPTION_KEY` | runtime secret `acc/calcom_encryption_key` | yes, but not a build input |
| Listen port | container `3000` (Cal.com default, wired in [alb.tf:4](terraform/modules/calcom_service/alb.tf#L4)) | no |

For ACC: `--build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.acc.secureclinic.co`.

### Full build-arg list (verified from the Dockerfile at `v6.2.0` and `main` — identical set)

```
ARG NEXT_PUBLIC_LICENSE_CONSENT
ARG NEXT_PUBLIC_WEBSITE_TERMS_URL
ARG NEXT_PUBLIC_WEBSITE_PRIVACY_POLICY_URL
ARG CALCOM_TELEMETRY_DISABLED
ARG DATABASE_URL
ARG NEXTAUTH_SECRET=secret            # dummy default — build-time only
ARG CALENDSO_ENCRYPTION_KEY=secret    # dummy default — build-time only
ARG MAX_OLD_SPACE_SIZE=6144           # → ENV NODE_OPTIONS=--max-old-space-size=6144
ARG NEXT_PUBLIC_API_V2_URL
ARG CSP_POLICY
ARG NEXT_PUBLIC_SINGLE_ORG_SLUG
ARG ORGANIZATIONS_ENABLED
ARG NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000   # ← per-clinic; override this
```

What this confirms for our build:
- **`NEXT_PUBLIC_WEBAPP_URL`** is a build ARG (baked into the bundle, re-exported as ENV in the runner) — our per-clinic build requirement holds. It's the **only** value we must override per clinic; the rest can take defaults.
- **`DATABASE_URL`, `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY` are consumed at BUILD time** (Prisma generate / typegen during `next build`). `NEXTAUTH_SECRET` and `CALENDSO_ENCRYPTION_KEY` have dummy defaults (`secret`) so the build succeeds without them; **`DATABASE_URL` has no default**, so pass a throwaway value at build, e.g. `--build-arg DATABASE_URL=postgresql://build:build@localhost:5432/build`. These build-time values are **throwaway** — the real secrets are injected at runtime by the task def, unchanged.
- Optionally pass `--build-arg CALCOM_TELEMETRY_DISABLED=1`.
- Container listens on **`3000`** (`EXPOSE 3000`, healthcheck probes `:3000`) — matches [alb.tf:4](terraform/modules/calcom_service/alb.tf#L4). ✅

## Build resource requirements

The Cal.com build is **heavy** — a full Next.js monorepo build. Budget:

- **Memory:** the Dockerfile itself sets the OOM mitigation — `MAX_OLD_SPACE_SIZE=6144` → `NODE_OPTIONS=--max-old-space-size=6144` (6 GB Node heap during `next build`). Provision the build host/runner with **headroom above that (~8 GB RAM)**. Raise the `MAX_OLD_SPACE_SIZE` build arg if a future ref needs more. (6144 is the authoritative number from the Dockerfile; no separate prose minimum-RAM doc exists.)
- **Time:** ~15–30+ min from cold, longer without layer cache.
- **Runner:** a laptop can do it (slowly); in CI use a large runner and cache the Docker layers / yarn store. This is why it's a dedicated workflow, not an inline step.

## Local build (DEPLOY.md §8 fallback)

```bash
# Ref is pinned in the CALCOM_REF file (sourced here):
source ./CALCOM_REF                     # CALCOM_REPO, CALCOM_SHA
git clone "$CALCOM_REPO" cal.diy && cd cal.diy
git checkout "$CALCOM_SHA"
TAG=main-$(git rev-parse --short HEAD)   # → main-f004349

ECR=$(terraform -chdir=../clinic-platform/terraform/envs/acc output -raw calcom_ecr_repository_url)
aws ecr get-login-password --profile acc --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR%/*}"

docker build -f Dockerfile \
  --build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.acc.secureclinic.co \
  --build-arg CALCOM_TELEMETRY_DISABLED=1 \
  --build-arg DATABASE_URL=postgresql://build:build@localhost:5432/build \
  -t "$ECR:latest" -t "$ECR:$TAG" .
  # NEXTAUTH_SECRET / CALENDSO_ENCRYPTION_KEY use their dummy build defaults;
  # real values are injected at runtime by the task def.

docker push "$ECR:latest"
docker push "$ECR:$TAG"
```

Then run the Prisma migrate task and force-new-deployment exactly as in [DEPLOY.md](DEPLOY.md) §8.

> **Note — Cal.com auto-migrates on boot.** `scripts/start.sh` runs `npx prisma migrate deploy` on container startup, so the separate `acc-calcom-migrate` one-off task is a belt-and-suspenders gate, not strictly required (`migrate deploy` is idempotent). Running it explicitly before rolling the service is still the safer sequence — it surfaces migration failures on a throwaway task instead of in a crash-looping service.

## CI workflow shape (TODO §3)

The build's productized form — one reusable workflow, matrixed over clinics:

1. Read `CALCOM_REF`; checkout `calcom/cal.com` at that ref.
2. For each clinic in the matrix: OIDC-assume that clinic's `github-ci-role`; `docker build` with `--build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.<clinic>.<apex>`; push `:latest` + `:<ref>` to that clinic's ECR.
3. `aws ecs run-task` on `<clinic>-calcom-migrate` (gate on success).
4. `aws ecs update-service --force-new-deployment` for `<clinic>-calcom`.

## Upgrading Cal.com later

Forward-only, per clinic: bump `CALCOM_REF` → rebuild + push → run the migrate task (`prisma migrate deploy` is idempotent) → roll the service. Test in a non-production clinic first once one exists.

## Verified (2026-07-05) — items closed

- [x] **Build-arg list** locked from the Dockerfile (`v6.2.0` and `main` are identical) — see the list above.
- [x] **Build-time secrets:** `DATABASE_URL` (no default → pass a throwaway), `NEXTAUTH_SECRET` / `CALENDSO_ENCRYPTION_KEY` (dummy default `secret`) are all consumed at build; real values are runtime-only.
- [x] **Container port** = `3000` (`EXPOSE 3000` + healthcheck) — matches [alb.tf:4](terraform/modules/calcom_service/alb.tf#L4).
- [x] **Migrate command** confirmed: `start.sh` runs `npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma` (same relative path as [migrate.tf:24](terraform/modules/calcom_service/migrate.tf#L24)) — our task def is correct. Cal.com also auto-migrates on boot (see note above).
- [x] **Build memory** = 6 GB Node heap (`MAX_OLD_SPACE_SIZE=6144`); provision ~8 GB.

## Still open (decisions, not facts)

- [x] **Ref chosen** — MIT `main@f004349`, recorded in [CALCOM_REF](CALCOM_REF).
- [ ] Decide `:latest` vs image-**digest** pinning for the service task def.
- [x] Confirm the exact set of features that require the commercial edition post-relicense — **resolved 2026-07-18**: not a license boundary at all; the ee tree (Teams, Organizations, Workflows, SSO, Insights) is deleted from Cal.diy at our pinned SHA. See "Feature boundary" note above.
- [x] Write the CI image-build workflow ([TODO.md](TODO.md) §3) — done, verified end-to-end against ACC (2026-07).

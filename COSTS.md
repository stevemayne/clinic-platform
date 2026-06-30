# AWS & Platform Cost Estimate

**Prepared:** 16 June 2026 · **Revised:** 28 June 2026 (added self-hosted Cal.com)
**Scope:** Monthly cost to run the platform in [RECOMMENDATIONS.md](RECOMMENDATIONS.md), split into **shared costs** (one set, amortized across all clinics) and **per-client costs** (one set per clinic). Answers the brief's question: *"What is the cost to host a single client instance?"*

**Basis & exclusions:**

- Region **us-east-1**, **on-demand**, **730 hrs/month**, **free tier ignored**.
- **Excludes** n8n licensing, Monday Enterprise seats, EHR subscription/RCM fees, clearinghouse per-claim fees, Paubox, and your own setup/maintenance margin — these sit outside AWS. (Cal.com is now **self-hosted on AWS**, replacing Calendly, so its compute is included below. The free community edition — **Cal.diy, MIT-licensed** — carries no subscription fee; an optional paid commercial Cal.com license is a separate, non-AWS cost — see the licensing note in [RECOMMENDATIONS.md](RECOMMENDATIONS.md).)
- Bedrock figures are usage-based estimates; they move with clinical volume and model choice.

---

## 1. Shared costs (one set, amortized across all clinics)

These live in the management / shared-services account and get cheaper *per client* as you sign more.

| Component | Spec | $/mo |
|---|---|---|
| Management + shared-services account | Terraform state (S3/DynamoDB), CI/CD runners, artifact storage | 20 |
| Centralized monitoring/logging | Cross-account CloudWatch dashboards, alerting | 25 |
| Route 53 + ACM + WAF (shared) | DNS, certs, edge protection | 15 |
| Shared tooling / sandbox | Dev/test environment for workflow library | 40 |
| **Shared subtotal** | | **≈ $100/mo** |

> The workflow library, Terraform module, and runbooks are largely a **one-time build** (your labor), not a recurring AWS cost — that's the biggest economy of scale and lands in your setup fee, not the monthly AWS bill.

---

## 2. Per-client costs

### 2a. Fixed infrastructure baseline (per clinic, single-AZ "typical")

| Component | Spec | $/mo |
|---|---|---|
| n8n — ECS Fargate | 1 vCPU / 2 GB, always-on | 36 |
| Cal.com (scheduling) — ECS Fargate | 1 vCPU / 2 GB, always-on; shares RDS + ALB | 36 |
| Chat UI — ECS Fargate | 0.5 vCPU / 1 GB, always-on | 18 |
| RDS Postgres | db.t4g.small single-AZ, ~30 GB gp3 + backups; hosts `n8n` + `calcom` DBs | 29 |
| Application Load Balancer | 1 shared, host-based routing (n8n / Cal.com / chat) | 20 |
| Networking | 1 NAT Gateway + VPC interface endpoints (Bedrock/ECR private) | 35 |
| CloudWatch + CloudTrail | log ingestion/storage + audit trail | 12 |
| S3 | ~50 GB documents / intake PDFs | 3 |
| KMS | 2–3 customer-managed keys | 4 |
| Secrets Manager | ~9 secrets (incl. Cal.com) + ECR image storage | 4 |
| Data transfer out | modest egress | 8 |
| AWS Backup | beyond RDS automated backups | 5 |
| **Fixed subtotal** | | **≈ $210** |

> **Cal.com adds ~$36/mo**, almost entirely its Fargate task — it reuses the existing per-clinic RDS (as a second `calcom` database) and ALB (as another host rule), so there's no new database or load balancer. A leaner 0.5 vCPU / 1 GB task (~$18) is possible if metrics allow, but 1 GB can be tight for Cal.com's Node runtime.

### 2b. Variable Bedrock (Claude) — "typical" medium clinic

Assumptions: ~15 clinicians, ~80 sessions/day × 22 days ≈ **1,760 sessions/month**. Rates per million tokens (in/out): **Opus 4.8 $5/$25**, **Sonnet $3/$15**, **Haiku ~$1/$5**. Batch ≈ 50% off; prompt caching up to 90% off cached input.

| Workload | Model | Rough volume | $/mo |
|---|---|---|---|
| Session-note & discharge summarization | **Opus 4.8** | ~4.9M in / 1.3M out | 58 |
| Clinician chat interface | **Sonnet** | ~11.9M in / 2.8M out | 77 |
| Leadership analytics / chat-with-data | Sonnet (batch) | — | 25 |
| Claim denial analysis (AI checking) | Opus, low volume | — | 10 |
| **Bedrock subtotal** | | | **≈ $170** |

### Per-client total — three scenarios

| Scenario | Fixed infra | Bedrock | **Per-client AWS total** |
|---|---|---|---|
| **Lean** — small clinic, single-AZ, mostly Sonnet, lean Cal.com task | ~$170 | ~$70 | **≈ $240/mo** |
| **Typical** — medium clinic, single-AZ | ~$210 | ~$170 | **≈ $380/mo** |
| **Production-hardened** — Multi-AZ RDS, dual NAT (HA), heavy Opus | ~$290 | ~$400 | **≈ $690/mo** |

---

## 3. Fully-loaded cost per client (shared amortized + per-client)

Shared cost (~$100/mo) divided across N clients, plus the per-client total. Using the **typical ≈ $380** per-client figure:

| Clients signed | Shared cost / client | Per-client AWS | **Fully-loaded AWS / client / mo** |
|---|---|---|---|
| 1 (ACC alone) | $100 | $380 | **≈ $480** |
| 3 | $33 | $380 | **≈ $413** |
| 5 | $20 | $380 | **≈ $400** |
| 10 | $10 | $380 | **≈ $390** |
| 25 | $4 | $380 | **≈ $384** |

**Takeaways:**

- **A single client instance costs roughly $380/month in raw AWS** (typical), or ~$480 fully-loaded while ACC is the only client.
- **Per-client cost falls toward ~$380** as the shared overhead amortizes — most of the gain is realized by ~5 clients. The shared AWS pool is small; the *real* economy of scale is your one-time build labor (workflow library, Terraform module) spread across the client base, which sits in setup fees rather than this AWS bill.
- **Bedrock is the only line with no scale economy** — it's pure usage. Control it with model choice (Opus only where it matters) and prompt caching, not volume.

---

## The levers that move this most

- **Model choice is the biggest lever.** Running clinician chat on Opus instead of Sonnet pushes that line from ~$77 to ~$130; all-Opus roughly doubles Bedrock. The "Opus for documentation, Sonnet/Haiku for chat and routing" split keeps a typical clinic near $380.
- **Prompt caching** cuts cached input up to 90%; clinical templates and system prompts are highly cacheable, so real Bedrock spend likely lands **below** these figures.
- **Multi-AZ + dual NAT** ≈ **+$75/mo** for HA. Start ACC single-AZ; make HA a per-clinic upsell.
- **Always-on Fargate** is now ~$90/mo of fixed cost across three tasks (n8n $36 + Cal.com $36 + chat $18). Scale n8n/Cal.com to zero off-hours only if a clinic has no overnight webhooks/scheduled jobs — though scheduling tools generally need to stay up.

---

## Sources

- [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/)
- [Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)

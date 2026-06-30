# Per-Tenant AWS Cost Estimate

**Prepared:** 16 June 2026
**Scope:** Estimated monthly AWS resource cost for **one clinic tenant** built on the architecture in [RECOMMENDATIONS.md](RECOMMENDATIONS.md) (self-hosted n8n + clinician chat UI + Claude via Amazon Bedrock, isolated per clinic).

**Basis & exclusions:**

- Region **us-east-1**, **on-demand** pricing, **730 hours/month**, **free tier ignored**.
- **Excludes** n8n licensing (set aside per request), your own setup/maintenance margin, Monday.com Enterprise seats, and any Cal.com / Paubox / pdf.co subscriptions — these sit outside AWS.
- Bedrock figures are usage-based estimates and will move with clinical volume and model choice.

---

## Fixed infrastructure baseline

Paid whether the clinic is busy or idle. "Typical" single-AZ configuration.

| Component | Spec | $/mo |
|---|---|---|
| n8n — ECS Fargate | 1 vCPU / 2 GB, always-on | 36 |
| Chat UI — ECS Fargate | 0.5 vCPU / 1 GB, always-on | 18 |
| RDS Postgres | db.t4g.small single-AZ, ~30 GB gp3 + backups | 29 |
| Application Load Balancer | 1 shared, host-based routing for both services | 20 |
| Networking | 1 NAT Gateway + a few VPC interface endpoints (Bedrock/ECR private) | 35 |
| CloudWatch + CloudTrail | log ingestion/storage + audit trail | 12 |
| S3 | ~50 GB documents / intake PDFs | 3 |
| KMS | 2–3 customer-managed keys | 4 |
| Secrets Manager | ~6 secrets | 3 |
| Data transfer out | modest egress | 8 |
| AWS Backup | beyond RDS automated backups | 5 |
| **Fixed subtotal** | | **≈ $173** |

---

## Variable Bedrock (Claude) — "typical" medium clinic

Assumptions: ~15 clinicians, ~80 sessions/day × 22 working days ≈ **1,760 sessions/month**.

Current Bedrock Claude rates (per million tokens, input / output): **Opus 4.8 $5 / $25**, **Sonnet $3 / $15**, **Haiku ~$1 / $5**. Batch jobs are ~50% off; prompt caching is up to 90% off cached input.

| Workload | Model | Rough volume | $/mo |
|---|---|---|---|
| Session-note & discharge summarization | **Opus 4.8** ($5 / $25) | ~4.9M in / 1.3M out | 58 |
| Clinician chat interface | **Sonnet** ($3 / $15) | ~11.9M in / 2.8M out | 77 |
| Leadership analytics / chat-with-data | Sonnet (batch) | — | 25 |
| **Bedrock subtotal** | | | **≈ $160** |

---

## Bottom line — three scenarios

| Scenario | Fixed infra | Bedrock | **Per-tenant total** |
|---|---|---|---|
| **Lean** — small clinic, single-AZ, mostly Sonnet | ~$150 | ~$70 | **≈ $220/mo** |
| **Typical** — medium clinic, single-AZ | ~$175 | ~$160 | **≈ $335/mo** |
| **Production-hardened** — Multi-AZ RDS, dual NAT (HA), heavy Opus | ~$250 | ~$400 | **≈ $650/mo** |

A typical tenant lands around **$300–350/month** all-in, with a floor near **$200** and busy/HA tenants approaching **$650**.

---

## The levers that move this most

- **Model choice is the biggest lever.** Running the clinician chat on Opus instead of Sonnet pushes that line from ~$77 to ~$130; running *everything* on Opus easily doubles the Bedrock bill. The "Opus for final documentation, Sonnet/Haiku for chat and routing" split is what keeps the typical tenant near $335 rather than $600+.
- **Prompt caching** cuts cached input by up to 90%. Clinical prompt templates and system prompts are highly cacheable, so realistic Bedrock spend is likely **below** the table figures once enabled.
- **Multi-AZ + dual NAT** is the main fixed-cost decision: roughly **+$75/mo** for high availability. For a single proof-of-concept tenant (ACC), start single-AZ and make Multi-AZ a per-clinic upsell.
- **Always-on Fargate** is ~$54/mo of the fixed cost. If a clinic doesn't need 24/7 automations, n8n can scale to zero off-hours — but for intake webhooks and scheduled jobs, always-on is the safe default.

---

## Sources

- [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/)
- [Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)

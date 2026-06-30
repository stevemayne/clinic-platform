# Recommendations: ACC HIPAA-Compliant Automation & AI Environment

**Prepared:** 10 June 2026
**Scope:** Response to the Andrews Counseling and Consulting (ACC) brief — HIPAA-compliant automations (Make.com → self-hosted n8n), per-clinic data isolation, and HIPAA-compliant AI tooling (Claude) for clinicians and automations.

---

## TL;DR

1. **Run one n8n instance per clinic, not one multi-tenant instance.** n8n has no true multi-tenancy — instance-per-clinic is the only hard isolation, and it satisfies the data-portability requirement for free.
2. **Resolve the n8n licensing question before building.** The Sustainable Use License prohibits hosting n8n as a paid service for clients. The "setup fee + ongoing maintenance" model sits close to that line — structure it so each clinic licenses/owns its own instance and you bill for services, or talk to n8n about an Embed license.
3. **Use AWS as the compliance umbrella, with Claude via Amazon Bedrock.** One AWS BAA covers compute, storage, *and* Claude inference. Define the whole per-clinic stack in Terraform so onboarding a new clinic is `terraform apply` with new variables.
4. **Two vendors in the current stack are silently non-compliant** beyond Make.com: Calendly (no BAA, ToS prohibits PHI) and possibly Monday.com itself (HIPAA requires Enterprise plan + activated BAA, with a 25-seat minimum). These need remediation in phase 1, not later.
5. **Replace clinician ChatGPT use with a self-hosted chat UI backed by Bedrock Claude** inside the same HIPAA environment, plus a written acceptable-use policy. This is the most urgent risk in the brief — PHI is leaving the compliance boundary today.

---

## The explicit question: n8n multi-tenancy

**No — a single n8n instance does not provide tenant data isolation.** n8n has no first-class multi-tenancy. The Enterprise "Projects"/RBAC features are access control within one shared environment: one database, one credential store, one execution log. A misconfigured workflow or an over-permissioned user can cross tenant boundaries, and a breach in one clinic's workflow is a breach of the shared instance. For PHI, that's disqualifying.

**Recommendation: one n8n instance per clinic** — its own container, its own encrypted Postgres database, its own credential store. This gives you:

- Real data isolation (the HIPAA answer)
- Clean offboarding — a departing clinic's data is "their database + their workflow JSON," handed over wholesale
- Per-clinic blast radius for incidents and upgrades
- Simple BAA/audit scoping per clinic

The cost is more infrastructure to run, which Terraform absorbs (see architecture below).

### Licensing (important)

Under n8n's [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/), hosting n8n for customers and charging for access is **not allowed** — that requires a commercial/Embed license. What *is* allowed is consulting: building workflows and managing instances that clients use for their own internal business purposes.

The safe structure for the business model: **each clinic is the licensee of its own self-hosted instance** (it's in their AWS account or contractually theirs), and fees are for setup, automation development, and managed services — not for "access to n8n." Given the plan to scale to many clinics, get written confirmation from n8n or price an Embed license before signing client #2. ([n8n license use cases](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case), [licensing overview](https://www.fatcamel.ai/blog/n8n-licensing-101-understanding-commercial-embed-and-sustainable-use-licenses))

---

## Reference architecture (replicated per clinic)

```
AWS Organization (management account, AWS BAA signed)
└── Clinic AWS account  (e.g. acc-prod)          ← isolation boundary
    ├── VPC (private subnets, VPC endpoints, no public DB access)
    ├── ECS Fargate / EC2: n8n (self-hosted)
    ├── ECS Fargate: chat UI (LibreChat or Open WebUI)
    ├── RDS Postgres (encrypted, KMS) — n8n DB + clinical data store
    ├── S3 (encrypted) — documents, intake PDFs
    ├── Amazon Bedrock — Claude inference (PHI never leaves AWS)
    └── CloudTrail + CloudWatch — audit logging, PHI scrubbed from logs
```

Key design choices:

- **One AWS account per clinic** under AWS Organizations. This is the strongest isolation primitive AWS offers, makes per-clinic billing trivial (pass-through infrastructure costs), and makes "take your data with you" a literal account handover if ever needed.
- **Everything in Terraform as a `clinic` module** — VPC, n8n service, database, chat UI, Bedrock access policies, logging. New clinic = new tfvars file + apply.
- **n8n workflows in git as JSON**, deployed via the n8n public API in CI. Parameterize per-clinic differences (Monday board IDs, email addresses, credential names) so the same workflow library deploys everywhere. This is the replication story for the automations themselves, separate from the infra.
- **HIPAA hygiene baked into the module:** encryption at rest (KMS) and in transit everywhere, no PHI in n8n execution logs where avoidable (conservative execution-data retention), MFA + SSO for admin access, audit logging on by default, automated encrypted backups.

---

## Vendor compliance map

| Vendor | Status | Action |
|---|---|---|
| Make.com | Not HIPAA-compliant, no BAA | Replace with self-hosted n8n (as planned) |
| Monday.com | HIPAA **only** on Enterprise plan with BAA activated (25-seat minimum) | Verify ACC's plan. If not Enterprise+BAA: either upgrade, or keep PHI out of Monday (IDs/initials only, PHI lives in the clinic database) |
| Calendly | **Not HIPAA-compliant**, won't sign a BAA, ToS prohibits PHI | Replace with Cal.com (self-hostable; Enterprise plan signs a BAA) — fits the self-hosted stack — or strictly strip PHI from booking flows |
| Gmail / Drive / Docs | Compliant **if** Google Workspace BAA is signed (free, covers Gmail, Drive, Docs) | Confirm the Workspace BAA is executed for ACC's domain |
| Paubox | HIPAA-compliant by design (BAA included) | Keep for patient-facing email |
| pdf.co | Advertises HIPAA compliance | Verify and execute their BAA, or move PDF generation in-house (n8n can do most of it with document libraries) |
| ChatGPT (consumer) | Not HIPAA-compliant | Replace with the Claude chat interface below + written acceptable-use policy |

The Monday.com finding deserves emphasis: the brief treats Monday as the stable center of the architecture, but if ACC isn't on Enterprise with HIPAA activated, the ops control center itself is out of compliance today — independent of the middleware problem.

Sources: [monday.com HIPAA support doc](https://support.monday.com/hc/en-us/articles/360006506699-monday-com-and-HIPAA), [monday.com BAA](https://monday.com/l/privacy/hipaa-baa/), [Calendly HIPAA status](https://www.paubox.com/blog/is-calendly-hipaa-compliant), [Cal.com healthcare](https://cal.com/scheduling/healthcare), [Make HIPAA status](https://www.paubox.com/blog/integromat-hipaa-compliant)

---

## The AI layer

### Why Bedrock as the primary path

Claude on Amazon Bedrock is HIPAA-eligible under the **AWS BAA already needed for the rest of the stack** — one agreement covers compute, storage, and inference, and prompts/outputs never leave AWS ([AWS Bedrock security & compliance](https://aws.amazon.com/bedrock/security-compliance/), [AWS re:Post on Bedrock + Anthropic models](https://repost.aws/questions/QUszPnXyW0RHyJkSt_Th3mcg/aws-bedrock-anthropic-foundational-models-hipaa-compliance)).

The alternative — Anthropic's first-party API, which offers a [BAA with zero data retention for HIPAA-enabled organizations](https://privacy.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers) — is worth keeping in reserve for Anthropic-only features (server-side tools and Managed Agents aren't on Bedrock). But for a small MSP serving small clinics, one BAA with one vendor is the simpler compliance story to replicate and audit.

### Clinician chat interface (per clinic)

Self-host **LibreChat or Open WebUI** in each clinic's VPC, pointed at Bedrock Claude. This fits the business model better than buying per-clinic Claude Enterprise seats (which also supports a HIPAA BAA, but adds a second vendor relationship, per-seat cost, and seat minimums to every clinic deal):

- Same Terraform module, same replication story as everything else
- Control of clinic-specific prompt templates — "summarize this session into a SOAP/DAP note," "draft a discharge summary," "draft client communication at a 6th-grade reading level" — which is where the real time savings live, beyond raw chat
- Per-clinician auth via the clinic's Google Workspace SSO, full audit trail of usage

### Claude in automations

n8n calls Bedrock directly (native AWS credentials node or HTTP node). Use **Claude Opus 4.8** (`anthropic.claude-opus-4-8` on Bedrock) for clinical documentation drafting and summarization — clinical language is high-stakes and worth the top model — and drop to Sonnet/Haiku only for cheap classification/routing steps.

Concrete automation candidates from the brief:

- Intake packet → structured extraction (structured outputs against a JSON schema) → pre-populated Monday items + clinic DB rows
- Session notes → draft summaries and data-collection fields, with **clinician review before anything is filed** (human-in-the-loop is both a quality and a compliance posture)
- Discharge workflow → assemble the discharge summary draft from the treatment record
- Nightly/weekly batch jobs for leadership analytics (Bedrock batch inference is half price)

### Data layer and "chat with your data"

Keep a **per-clinic Postgres clinical data store** as the source of truth for structured behavioral-health data, with n8n syncing the reporting slice back into Monday.com for its native dashboards (this covers the fixed-reports requirement).

For the chat-with-data requirement, add a Claude tool-use endpoint that queries a **read-only replica** with row-level scoping — leadership asks questions in natural language, Claude generates and runs constrained SQL, results come back summarized. This also directly serves the reimbursement-justification use case: outcome trends by program, by clinician, by payer, exportable for Medicaid audits.

---

## Phased plan for ACC (proof of concept)

1. **Compliance groundwork** — sign the AWS BAA; verify/execute Monday Enterprise BAA, Google Workspace BAA, pdf.co BAA; decide the Calendly replacement; resolve the n8n license question; issue the ChatGPT acceptable-use policy.
2. **Stand up the environment** — Terraform clinic module: VPC, n8n, Postgres, chat UI, Bedrock, logging. Deploy for ACC.
3. **Migrate automations** — port Make.com scenarios to n8n one workflow family at a time (intake → consents → insurance verification → scheduling → discharge), now able to pass PHI through them freely.
4. **Roll out AI** — chat interface to clinicians with clinical prompt templates; then the automation-embedded Claude steps with clinician review gates.
5. **Productize** — extract everything ACC-specific into tfvars/workflow parameters, write the onboarding runbook, and validate replication speed by doing a dry-run "clinic #2" deploy into a fresh account.

---

## Caveat for the business model

A BAA-covered toolchain is necessary but not sufficient — each clinic still needs its own risk analysis, access policies, and training to be HIPAA-compliant. Position the offering as **"HIPAA-eligible infrastructure + automations"** rather than "we make you HIPAA-compliant," and consider partnering with a compliance attorney for the contractual templates to be reused across clinics.

---

## Sources

- [n8n Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)
- [n8n license use cases](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case)
- [n8n isolation docs](https://docs.n8n.io/hosting/configuration/configuration-examples/isolation/)
- [Multi-tenant n8n strategies](https://www.wednesday.is/writing-articles/building-multi-tenant-n8n-workflows-for-agency-clients)
- [n8n licensing overview (Commercial, Embed, Sustainable Use)](https://www.fatcamel.ai/blog/n8n-licensing-101-understanding-commercial-embed-and-sustainable-use-licenses)
- [Anthropic BAA policy](https://privacy.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers)
- [Anthropic API data retention](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)
- [AWS Bedrock security & compliance](https://aws.amazon.com/bedrock/security-compliance/)
- [AWS re:Post — Bedrock Anthropic models & HIPAA](https://repost.aws/questions/QUszPnXyW0RHyJkSt_Th3mcg/aws-bedrock-anthropic-foundational-models-hipaa-compliance)
- [AWS HIPAA gen-AI guidance](https://aws.amazon.com/blogs/industries/hipaa-compliance-for-generative-ai-solutions-on-aws/)
- [monday.com HIPAA support doc](https://support.monday.com/hc/en-us/articles/360006506699-monday-com-and-HIPAA)
- [monday.com BAA](https://monday.com/l/privacy/hipaa-baa/)
- [Calendly HIPAA status (Paubox)](https://www.paubox.com/blog/is-calendly-hipaa-compliant)
- [Cal.com HIPAA-compliant scheduling](https://cal.com/scheduling/healthcare)
- [Make.com HIPAA status (Paubox)](https://www.paubox.com/blog/integromat-hipaa-compliant)

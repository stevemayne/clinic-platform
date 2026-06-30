# Recommendations: ACC HIPAA-Compliant Automation, AI & Operations Platform

**Prepared:** 16 June 2026
**Scope:** Response to the Andrews Counseling and Consulting (ACC) brief — a HIPAA-compliant, replicable platform for Medicaid-serving behavioral health clinics: automations (Make.com → self-hosted n8n), per-clinic data isolation, HIPAA-compliant AI (Claude) for clinicians and automations, billing/clearinghouse integration, EHR strategy, and a future de-identified cross-clinic data co-op.

---

## TL;DR

1. **Run one n8n instance per clinic, not one multi-tenant instance.** n8n has no true multi-tenancy — instance-per-clinic is the only hard isolation, and it satisfies the data-portability requirement for free.
2. **Resolve the n8n licensing question before scaling.** The Sustainable Use License prohibits hosting n8n as a paid service for clients. Structure each clinic as the licensee of its own instance and bill for services, or buy an Embed license.
3. **Use AWS as the compliance umbrella, with Claude via Amazon Bedrock.** One AWS BAA covers compute, storage, *and* Claude inference. Define the whole per-clinic stack in Terraform so onboarding a new clinic is `terraform apply` with new variables.
4. **Treat the orchestration layer — n8n + Monday + Claude — as the "change-absorption layer."** This is the strategic core: when Medicaid policy shifts (≈ every 3 years), you re-author workflows in days rather than waiting on an EHR vendor's roadmap. Own it, don't rent it — that is the cost-predictability story.
5. **For the EHR, lead with API quality. Healthie (GraphQL, API-first) is the strongest technical fit; Tebra is the pragmatic lower-cost outpatient option; Kipu only if ACC is SUD/residential; AdvancedMD if billing depth dominates.**
6. **For billing, OfficeAlly is a viable clearinghouse** — it exposes a JSON/SOAP/SFTP API and X12 276/277 claim-status transactions, supports Medicaid, and lets n8n trigger submissions and write status back to Monday. Compare it against EHR-native RCM before committing.
7. **A de-identified data co-op is feasible later** via HIPAA Expert Determination de-identification in a separate "clean room" AWS account. Park it as a phase-2 opportunity; design the data store now so it's possible.
8. **Two current vendors are silently non-compliant** beyond Make.com: Calendly (no BAA, ToS prohibits PHI) and possibly Monday.com itself (needs Enterprise + activated BAA, 25-seat minimum). Remediate in phase 1.
9. **Replace clinician ChatGPT use immediately** with a self-hosted chat UI backed by Bedrock Claude. PHI is leaving the compliance boundary today — this is the most urgent risk in the brief.

---

## Guiding principle: the orchestration layer is the moat

The expanded brief makes the real objective clear: not just "make the tools compliant," but give clinics **cost control, predictability, and the ability to adapt quickly** when Medicaid policy changes force new documentation, credentialing, and administrative volume — changes that EHRs absorb slowly or not at all.

The design answer is to keep the **change-absorption logic in a layer you own and can re-author cheaply** — n8n workflows, Monday boards, and Claude prompts — sitting *above* the systems of record (EHR, clearinghouse). When a policy changes:

- A new required field or consent → edit a workflow + a board column, not a vendor ticket.
- A new documentation rule → update a Claude prompt template.
- A new claim-scrubbing rule → add a validation step in n8n before submission.

Evaluate every component through the brief's two lenses:

| Lens | Question | Where it points |
|---|---|---|
| **Bespoke for stability/control** | Does owning this give us predictable cost and fast adaptation? | The orchestration + AI layer (n8n, prompts, the data store). Own these. |
| **Economies of scale** | Can one build serve many clinics? | The Terraform module, the workflow library, the de-id clean room, shared monitoring. Build once, amortize. |

The rule of thumb: **own the glue, rent the commodities.** Rent compute (AWS), inference (Bedrock), the EHR system-of-record, and the clearinghouse pipes — but own the workflows, prompts, and data model that encode each clinic's operations, because those are what policy change churns.

---

## The explicit question: n8n multi-tenancy

**No — a single n8n instance does not provide tenant data isolation.** n8n has no first-class multi-tenancy. Enterprise "Projects"/RBAC are access controls within one shared environment: one database, one credential store, one execution log. A misconfigured workflow or over-permissioned user can cross tenant boundaries, and a breach in one clinic's workflow is a breach of the shared instance. For PHI, that's disqualifying.

**Recommendation: one n8n instance per clinic** — its own container, encrypted Postgres database, and credential store. This delivers real data isolation, clean offboarding ("their database + their workflow JSON"), per-clinic blast radius, and simple per-clinic audit scoping. The extra infrastructure is absorbed by Terraform (below).

### Licensing (important)

Under n8n's [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/), hosting n8n for customers and charging for access is **not allowed** — that needs a commercial/Embed license. Consulting (building workflows, managing instances clients use for their own internal business purposes) **is** allowed. Safe structure: **each clinic is the licensee of its own self-hosted instance**, and your fees are for setup, automation development, and managed services. Get written confirmation from n8n or price an Embed license before signing client #2. ([n8n license use cases](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case), [licensing overview](https://www.fatcamel.ai/blog/n8n-licensing-101-understanding-commercial-embed-and-sustainable-use-licenses))

---

## Reference architecture (replicated per clinic)

```
AWS Organization (management account, AWS BAA signed)
├── Shared services account ── Terraform state, CI/CD, workflow library, monitoring
├── Clean-room account (future) ── de-identified cross-clinic analytics
└── Clinic AWS account  (e.g. acc-prod)            ← per-clinic isolation boundary
    ├── VPC (private subnets, VPC endpoints, no public DB access)
    ├── ECS Fargate: n8n (self-hosted)
    ├── ECS Fargate: chat UI (LibreChat or Open WebUI)
    ├── RDS Postgres (encrypted, KMS) — n8n DB + clinical data store
    ├── S3 (encrypted) — documents, intake PDFs
    ├── Amazon Bedrock — Claude inference (PHI never leaves AWS)
    └── CloudTrail + CloudWatch — audit logging, PHI scrubbed from logs
```

Key choices:

- **One AWS account per clinic** under AWS Organizations — the strongest isolation primitive AWS offers; trivial per-clinic billing; "take your data with you" becomes an account handover.
- **Everything in Terraform as a `clinic` module.** New clinic = new tfvars + apply.
- **n8n workflows in git as JSON**, deployed via the n8n API in CI, parameterized per clinic (Monday board IDs, emails, credential names, EHR/clearinghouse endpoints). This is the replication story for the automations.
- **HIPAA hygiene in the module:** KMS encryption at rest, TLS in transit, conservative n8n execution-data retention (keep PHI out of logs), MFA + SSO admin access, audit logging on by default, automated encrypted backups.

---

## EHR selection

The brief is right that EHR API quality should drive the choice — if you control the system of record's data flow from day one, the whole platform is cleaner. Moving clients onto a well-integrated EHR is worth it. Findings on the four candidates:

| EHR | API | BH fit | Billing/RCM | Verdict |
|---|---|---|---|---|
| **Healthie** | **API-first GraphQL with full platform parity**; ONC-certified FHIR R4 (Enterprise add-on, 4–6 wk setup) | Supports behavioral health; built for digital-health builders | Solid; API-accessible | **Strongest technical fit** if you want to build the bespoke data flow. The GraphQL API is the same one Healthie's own front end uses, so nothing is off-limits. |
| **Tebra** | SOAP API + documented FHIR resources (older style) | Purpose-built for **independent mental health** practices | Built-in RCM/billing | **Pragmatic outpatient choice** — lower cost, BH-native, and ACC already has a demo. SOAP API is dated but workable. |
| **Kipu** | HL7 + API, many BH integrations | **Dominant in SUD / addiction / residential** treatment | Integrated EMR+CRM+RCM | Choose **only if ACC is SUD/residential**. Overkill and mis-targeted for general outpatient mental health. |
| **AdvancedMD** | RESTful API + FHIR R4 read + SMART-on-FHIR OAuth2 | General; not BH-specialized | **Deepest RCM**: claim scrubbing, ERA/EOB posting, denial management | Choose **if billing depth is the priority** and you'd rather lean on native RCM than build it. Heavier/enterprise. |

**Recommendation:** Validate **Healthie** as the strategic default (API-first matches "build the data flow we need from day one"), with **Tebra** as the cost-sensitive fallback given the existing demo and BH focus. Confirm with each vendor: (1) FHIR/API tier and cost, (2) BAA, (3) whether claims can be submitted via API or only through native RCM. Reserve Kipu/AdvancedMD for clinics whose modality (SUD) or billing complexity demands them.

Sources: [Healthie API (GraphQL)](https://docs.gethealthie.com/) · [Healthie FHIR/HL7](https://help.gethealthie.com/article/1013-hl7-fhir-standards) · [Tebra API guide](https://helpme.tebra.com/Tebra_PM/12_API_and_Integration/01_Get_Started_with_Tebra_API_Integration/Tebra_API_Integration_User_Guide) · [Tebra for psychology](https://www.tebra.com/specialties/psychology) · [Kipu Health](https://www.kipuhealth.com/) · [AdvancedMD interoperability](https://www.advancedmd.com/group-practice/interoperability/)

---

## Billing & clearinghouse (OfficeAlly)

For Medicaid claims, **OfficeAlly is a workable clearinghouse for the n8n model.** It exposes JSON APIs, SOAP/MIME, and SFTP (plus an Enterprise Clearinghouse API), processes Medicare/Medicaid and all payers, and supports the standard EDI claim-status transactions. ([OfficeAlly clearinghouse](https://cms.officeally.com/clearinghouse), [EDI clearinghouse](https://cms.officeally.com/products/edi-clearinghouse))

What n8n can orchestrate against it:

- **Trigger submission from Monday** → n8n assembles the EDI **837** claim and submits via API/SFTP.
- **Track status back into Monday** → n8n polls the **276/277** claim-status transactions and updates the Monday board.
- **AI denial-checking** → ingest the **835** ERA (with CARC/RARC denial reason codes), feed the denied claim + reason into **Claude** to classify the root cause and suggest a corrected resubmission, and accumulate denial patterns into a pre-submission scrubbing checklist that runs in n8n before the next claim goes out. This is the learning loop the brief describes.

**Build-vs-buy caveat (the cost-predictability lens):** generating compliant 837s and parsing 835s is real EDI engineering. Two paths:

1. **EHR-native RCM** (Tebra/AdvancedMD/Kipu all submit claims): lower build effort, but billing cost is bundled into per-claim or % -of-collections SaaS pricing — exactly the subscription-creep the brief wants to avoid.
2. **Standalone clearinghouse (OfficeAlly) driven by n8n**: more upfront build, but flat/transaction-priced and under your control — better long-run cost predictability, and reusable across clinics.

Recommend **modeling both on a per-claim cost basis** during the OfficeAlly and EHR calls. Some clinics will bill in their EHR (the brief notes this) — support both: the n8n layer can either drive OfficeAlly directly or hand off to the EHR's RCM, depending on the clinic.

---

## Vendor compliance map

| Vendor | Status | Action |
|---|---|---|
| Make.com | Not HIPAA-compliant, no BAA | Replace with self-hosted n8n (as planned) |
| Monday.com | HIPAA **only** on Enterprise plan with BAA activated (25-seat minimum) | Verify ACC's plan; upgrade or keep PHI out of Monday (IDs/initials only, PHI in the clinic DB) |
| Calendly | **Not HIPAA-compliant**, won't sign a BAA, ToS prohibits PHI | Replace with **self-hosted Cal.diy** (Cal.com's free MIT community edition, as of April 2026) inside our HIPAA AWS env — compliance is ours, no third-party BAA needed. Optional paid commercial Cal.com license only if Teams/SSO are required. |
| Gmail / Drive / Docs | Compliant **if** Google Workspace BAA signed (free) | Confirm the Workspace BAA is executed |
| Paubox | HIPAA-compliant by design (BAA included) | Keep for patient-facing email |
| pdf.co | Advertises HIPAA compliance | Verify/execute BAA, or move PDF generation in-house in n8n |
| ChatGPT (consumer) | Not HIPAA-compliant | Replace with the Claude chat interface + written acceptable-use policy |

The Monday.com point bears repeating: if ACC isn't on Enterprise with HIPAA activated, the ops control center itself is out of compliance today, independent of the middleware problem.

Sources: [monday.com HIPAA](https://support.monday.com/hc/en-us/articles/360006506699-monday-com-and-HIPAA) · [monday.com BAA](https://monday.com/l/privacy/hipaa-baa/) · [Calendly HIPAA status](https://www.paubox.com/blog/is-calendly-hipaa-compliant) · [Cal.com healthcare](https://cal.com/scheduling/healthcare) · [Make HIPAA status](https://www.paubox.com/blog/integromat-hipaa-compliant)

---

## The AI layer

### Why Bedrock as the primary path

Claude on Amazon Bedrock is HIPAA-eligible under the **AWS BAA you already need** — one agreement covers compute, storage, and inference, and prompts/outputs never leave AWS ([AWS Bedrock security & compliance](https://aws.amazon.com/bedrock/security-compliance/), [AWS re:Post on Bedrock + Anthropic models](https://repost.aws/questions/QUszPnXyW0RHyJkSt_Th3mcg/aws-bedrock-anthropic-foundational-models-hipaa-compliance)). Keep Anthropic's first-party API (which offers a [BAA with zero data retention](https://privacy.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers)) in reserve for Anthropic-only features. For a small MSP, one BAA with one vendor is the simpler story to replicate and audit.

### Clinician chat interface (per clinic)

Self-host **LibreChat or Open WebUI** in each clinic's VPC, pointed at Bedrock Claude — same Terraform module and replication story as everything else, and cheaper to scale than per-clinic Claude Enterprise seats. You control clinic-specific prompt templates (SOAP/DAP session summaries, discharge summaries, client comms at a target reading level), with per-clinician SSO and a full usage audit trail.

### Claude in automations

n8n calls Bedrock directly. Use **Claude Opus 4.8** for clinical documentation drafting/summarization and denial analysis (high-stakes, worth the top model), and **Sonnet/Haiku** for cheap classification/routing. Candidates: intake → structured extraction → Monday + DB; session notes → draft summaries (clinician review before filing); discharge assembly; nightly analytics batches; the claim denial-learning loop above. Keep humans in the loop on anything that gets filed.

### Data layer and "chat with your data"

A **per-clinic Postgres clinical data store** is the source of truth for structured behavioral-health data; n8n syncs the reporting slice into Monday.com for native dashboards (the fixed-reports requirement). For chat-with-data, add a Claude tool-use endpoint over a **read-only replica** with row-level scoping — leadership asks in natural language, Claude generates constrained SQL, results return summarized. This directly serves reimbursement justification: outcome trends by program/clinician/payer, exportable for Medicaid audits.

---

## Future: de-identified cross-clinic data co-op ("clean room")

This is feasible and architecturally cheap to keep open as an option. HIPAA gives two de-identification routes ([HHS guidance](https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html)):

- **Safe Harbor** — remove 18 specified identifiers. Simple and cheap, but strips detail that limits analytics.
- **Expert Determination** — a qualified statistician certifies re-identification risk is "very small," using techniques (generalization, date-shifting) that **preserve far more analytic utility**. ([Safe Harbor vs Expert Determination](https://censinet.com/perspectives/hipaa-safe-harbor-vs-expert-determination))

**Recommendation:** for a benchmarking co-op, plan around **Expert Determination** (richer data, supports outcome benchmarking and AI). Mechanics:

- A separate **clean-room AWS account**; de-identification happens *as data leaves* each clinic account (you act as business associate under each clinic's BAA + a Data Use Agreement permitting de-identified aggregation). Once properly de-identified, the data is no longer PHI and can be pooled.
- Clinics get back **benchmarks against the larger sample** (e.g. "your no-show rate vs cohort," "outcome trajectories by diagnosis") — concrete value that also helps justify Medicaid reimbursement.

Treat this as **phase 2+** and demand-create it (the brief is right that appetite is unproven). The only thing needed now is to model the per-clinic data store consistently across clinics so pooling is later trivial.

---

## Costs (summary — see [COSTS.md](COSTS.md))

- **Per-client AWS resources:** ≈ **$220–650/month**, typical clinic ≈ **$335/month** (fixed infra ≈ $175 + Bedrock ≈ $160). Model choice (Opus vs Sonnet) and Multi-AZ are the big levers.
- **Shared costs** (management/CI account, workflow library dev, monitoring, future clean room, your team) amortize across clients — **effective per-client cost falls as you sign more**, which is the economies-of-scale lens in action.
- **Outside AWS:** n8n licensing, Monday Enterprise seats, EHR subscription/RCM, clearinghouse per-claim fees, Paubox, and any optional Cal.com commercial license (the self-hosted Cal.diy edition is free; its compute is in the AWS figures).

---

## Phased plan for ACC (proof of concept)

1. **Compliance groundwork** — sign AWS BAA; verify/execute Monday Enterprise, Google Workspace, pdf.co BAAs; decide Calendly replacement; resolve n8n licensing; issue ChatGPT acceptable-use policy.
2. **Stand up the environment** — Terraform `clinic` module (VPC, n8n, Postgres, chat UI, Bedrock, logging). Deploy for ACC.
3. **Migrate automations** — port Make.com scenarios to n8n by workflow family (intake → consents → insurance verification → scheduling → discharge), now PHI-safe.
4. **EHR + billing decisions** — run the Tebra and OfficeAlly calls; validate Healthie; choose EHR and billing path on a per-claim cost basis; build the claim submit/status/denial loop.
5. **Roll out AI** — clinician chat with clinical prompt templates; then automation-embedded Claude with review gates.
6. **Productize** — extract ACC-specifics into tfvars/workflow parameters, write the onboarding runbook, dry-run a "clinic #2" deploy into a fresh account.
7. **(Phase 2+)** — stand up the de-identified clean room once there's clinic demand.

---

## Open questions / next steps

- **n8n licensing** — confirm Sustainable Use vs Embed for the managed-service model before client #2.
- **Monday.com plan** — is ACC on Enterprise with HIPAA activated? Determines whether PHI can sit in Monday at all.
- **EHR** — confirm Healthie's FHIR/API tier + cost + BAA; compare to Tebra (demo already booked). Decide whether to migrate ACC.
- **Billing** — on the OfficeAlly call, get API docs, per-transaction pricing, and Medicaid enrollment process; compare against EHR-native RCM per-claim cost.
- **Data co-op** — gauge clinic appetite; defer build, preserve the option via a consistent data model.

---

## Caveat for the business model

A BAA-covered toolchain is necessary but not sufficient — each clinic still needs its own risk analysis, access policies, and training. Position the offering as **"HIPAA-eligible infrastructure + automations + clinical-ops expertise"** rather than "we make you HIPAA-compliant," and engage a compliance attorney for the reusable contractual templates (BAAs, DUAs for the co-op).

---

## Sources

- [n8n Sustainable Use License](https://docs.n8n.io/sustainable-use-license/) · [n8n license use cases](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case) · [n8n licensing overview](https://www.fatcamel.ai/blog/n8n-licensing-101-understanding-commercial-embed-and-sustainable-use-licenses) · [n8n isolation docs](https://docs.n8n.io/hosting/configuration/configuration-examples/isolation/)
- [Anthropic BAA policy](https://privacy.claude.com/en/articles/8114513-business-associate-agreements-baa-for-commercial-customers) · [Anthropic API data retention](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)
- [AWS Bedrock security & compliance](https://aws.amazon.com/bedrock/security-compliance/) · [AWS re:Post — Bedrock Anthropic & HIPAA](https://repost.aws/questions/QUszPnXyW0RHyJkSt_Th3mcg/aws-bedrock-anthropic-foundational-models-hipaa-compliance) · [AWS HIPAA gen-AI guidance](https://aws.amazon.com/blogs/industries/hipaa-compliance-for-generative-ai-solutions-on-aws/)
- [monday.com HIPAA](https://support.monday.com/hc/en-us/articles/360006506699-monday-com-and-HIPAA) · [monday.com BAA](https://monday.com/l/privacy/hipaa-baa/) · [Calendly HIPAA status](https://www.paubox.com/blog/is-calendly-hipaa-compliant) · [Cal.com healthcare](https://cal.com/scheduling/healthcare) · [Make.com HIPAA status](https://www.paubox.com/blog/integromat-hipaa-compliant)
- EHR: [Healthie API](https://docs.gethealthie.com/) · [Healthie FHIR/HL7](https://help.gethealthie.com/article/1013-hl7-fhir-standards) · [Tebra API guide](https://helpme.tebra.com/Tebra_PM/12_API_and_Integration/01_Get_Started_with_Tebra_API_Integration/Tebra_API_Integration_User_Guide) · [Tebra psychology](https://www.tebra.com/specialties/psychology) · [Kipu Health](https://www.kipuhealth.com/) · [AdvancedMD interoperability](https://www.advancedmd.com/group-practice/interoperability/)
- Billing: [OfficeAlly clearinghouse](https://cms.officeally.com/clearinghouse) · [OfficeAlly EDI clearinghouse](https://cms.officeally.com/products/edi-clearinghouse)
- De-identification: [HHS de-identification guidance](https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html) · [Safe Harbor vs Expert Determination](https://censinet.com/perspectives/hipaa-safe-harbor-vs-expert-determination)

# PlatformInit Platform Roadmap — Small-Context Task Plan

**Status:** planned platform backlog after P-CH04-T01  
**n8n:** PARKED until an explicit human resume decision  
**Canonical runtime task state:** `tasks/tracker.json`

## Why this roadmap is split this way

Zoo Code work is intentionally kept small to reduce context-window exhaustion and HTTP 400 failures.
The default task budget is one subsystem or one operator contract, normally **1–6 primary files**.
If a task grows beyond **8 unique non-state files**, crosses more than one subsystem, or needs broad
repository rereads, the Orchestrator should stop with `TASK_TOO_LARGE_SPLIT_REQUIRED` and split the
work before continuing.

Validation is **focused and changed-scope first**. Full-repository validation is allowed only when a
task explicitly requires it or a changed shared dependency invalidates earlier evidence. Passing
checks are not repeated merely for reassurance.

## Roadmap source and current-state alignment

This task plan expands the CH04.5–CH15 project roadmap into controller-sized work items. Existing
CH04.5/CH04.6 identity and CH05 Checkmk assets are treated as existing implementation to inventory,
stabilize, rationalize and validate; the roadmap does not assume they must be recreated from scratch.

The long-term chapter intent remains:

- CH04.5 Authentik identity foundation
- CH04.6 Argo CD SSO
- CH05 operator-first Checkmk operations
- CH06 security/compliance v2
- CH07 service templates/application onboarding
- CH08 multi-environment promotion
- CH09 backup/disaster recovery
- CH10 productization
- CH11 FinOps/governance
- CH12 advanced IAM
- CH13 AIOps
- CH14 internal developer platform
- CH15 customer-facing PlatformInit

## Task sizing contract

| Rule | Default |
|---|---|
| Primary changed files | 1–6 |
| Split threshold | >8 unique non-state files |
| Scope | one subsystem / one operator contract |
| Codebase reads | path-scoped indexing first |
| Validation | focused changed-scope only |
| Full repo test | explicit task requirement only |
| Repeated PASS checks | reuse evidence unless invalidated |
| Review feedback | one consolidated batch |
| Runtime mutation | human approval when required by existing safety rules |

## CH04.5

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH04.5-T01` | Inventory current Authentik foundation | Audit the existing CH04.5 Authentik assets and deprecated CH06 compatibility paths, then document the canonical identity ownership boundary without changing runtime. | `P-CH04-T01` |
| `P-CH04.5-T02` | Stabilize Authentik core deployment contract | Bound the Authentik core install to pinned chart/image inputs, secret preflight, namespace ownership, and idempotent repository-local deployment behavior. | `P-CH04.5-T01` |
| `P-CH04.5-T03` | Stabilize Authentik ingress and TLS contract | Define the Authentik ingress, certificate, hostname, and TLS ownership contract independently from identity model bootstrap. | `P-CH04.5-T02` |
| `P-CH04.5-T04` | Define identity groups and technical users contract | Normalize PlatformInit groups, technical users/service identities, provider templates, and bootstrap idempotence as a small identity-model unit. | `P-CH04.5-T03` |
| `P-CH04.5-T05` | Create CH04.5 focused validation and recovery checkpoint | Consolidate only the focused CH04.5 checks needed to prove repository contract, expected runtime health signals, and break-glass recovery notes. | `P-CH04.5-T04` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH04.6

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH04.6-T01` | Define Authentik OIDC application/provider for Argo CD | Isolate the Authentik OIDC provider/application contract for Argo CD, including issuer, redirect URI, scopes, and secret reference handling. | `P-CH04.5-T05` |
| `P-CH04.6-T02` | Define Argo CD OIDC and RBAC mapping | Configure Argo CD OIDC and group-to-role RBAC as a separate bounded task from provider creation. | `P-CH04.6-T01` |
| `P-CH04.6-T03` | Validate Argo CD login logout and fallback access | Add focused validation for SSO login, logout/session behavior, redirect correctness, and documented emergency local access without changing unrelated identity services. | `P-CH04.6-T02` |
| `P-CH04.6-T04` | Close CH04.6 identity integration checkpoint | Produce a compact CH04.6 operator handoff that records SSO ownership, known failure modes, and the exact prerequisite chain for CH05. | `P-CH04.6-T03` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH05

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH05-T01` | Inventory and rationalize current operations stack | Audit existing Checkmk, legacy Grafana/VictoriaMetrics/Loki/OpenObserve/Zabbix artifacts, and declare the current operator-first ownership model before more implementation. | `P-CH04.6-T04` |
| `P-CH05-T02` | Stabilize Checkmk GitOps runtime and storage contract | Bound Checkmk runtime manifests, persistent paths, ingress ownership, and Argo CD lifecycle into one small GitOps contract. | `P-CH05-T01` |
| `P-CH05-T03` | Stabilize Checkmk trusted-header SSO boundary | Define and validate Authentik forwardAuth, Traefik middleware, auth-shim, and X-Remote-User trust boundaries without mixing in host discovery. | `P-CH05-T02` |
| `P-CH05-T04` | Stabilize Checkmk agent install and host discovery | Isolate Linux agent installation, port/access assumptions, host registration, and service discovery from dashboard customization. | `P-CH05-T03` |
| `P-CH05-T05` | Define Checkmk operations service model | Define the minimum actionable service checks for host, storage, Kubernetes/platform endpoints, certificates, and backup readiness without adding dashboard noise. | `P-CH05-T04` |
| `P-CH05-T06` | Tune operations entry point and alert noise | Create a minimal WARN/CRIT-first landing experience and remove known stale/non-actionable noise as a separate UX task. | `P-CH05-T05` |
| `P-CH05-T07` | Create CH05 runtime validation and recovery checkpoint | Consolidate focused checks that distinguish backend, auth-shim, Traefik/AuthentiK, agent, and service-model failures, plus recovery/fallback notes. | `P-CH05-T06` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH06

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH06-T01` | Define security v2 threat model and ADR set | Translate CH06 goals into explicit threat boundaries and lightweight decisions for secrets, policy, scanning, audit, and runtime security before implementing tools. | `P-CH05-T07` |
| `P-CH06-T02` | Implement SOPS age GitOps secret contract | Implement the selected lightweight GitOps secret workflow with age key separation, repository rules, and operator documentation; do not introduce Vault unless the ADR chooses it. | `P-CH06-T01` |
| `P-CH06-T03` | Define Kubernetes RBAC baseline | Create namespace/service-account/RBAC minimums for platform components and document privileged exceptions separately from NetworkPolicy. | `P-CH06-T02` |
| `P-CH06-T04` | Define namespace and NetworkPolicy baseline | Create a small default network-isolation policy model with explicit ingress/egress exceptions for platform namespaces. | `P-CH06-T03` |
| `P-CH06-T05` | Implement Kyverno baseline policies | Implement only the first high-value admission policies: privileged workload control, image/tag rules, and required metadata, with an audit-first rollout. | `P-CH06-T04` |
| `P-CH06-T06` | Add focused image and dependency scanning | Add repository/manifest image scanning with Trivy or the ADR-selected scanner, scoped to changed artifacts and pinned severity policy. | `P-CH06-T05` |
| `P-CH06-T07` | Define Kubernetes audit and security evidence flow | Define minimal audit-log/security evidence capture and retention suitable for a single-node cost-conscious platform without building a heavy SIEM. | `P-CH06-T06` |
| `P-CH06-T08` | Create CH06 compliance checkpoint | Build a compact PASS/WARN/FAIL security checkpoint that aggregates existing focused evidence without re-running unrelated expensive checks. | `P-CH06-T07` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH07

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH07-T01` | Define service metadata and ownership contract | Define the minimum metadata every onboarded application must declare: name, owner, environment, data class, ingress, SSO, monitoring, backup, and recovery intent. | `P-CH06-T08` |
| `P-CH07-T02` | Define standard application manifest layout | Choose and document the base Kustomize/Helm layout for a small application without adding ingress, identity, or monitoring details yet. | `P-CH07-T01` |
| `P-CH07-T03` | Create ingress and TLS onboarding template | Create reusable application ingress/certificate patterns that consume CH04 conventions and avoid application-specific copy-paste. | `P-CH07-T02` |
| `P-CH07-T04` | Create optional Authentik onboarding template | Create the application SSO integration template separately from the base app template so non-SSO apps do not inherit unnecessary identity complexity. | `P-CH07-T03` |
| `P-CH07-T05` | Create monitoring logging and backup onboarding metadata | Define lightweight hooks/metadata for Checkmk, optional logging, and CH09 backup classification without implementing the later backup system here. | `P-CH07-T04` |
| `P-CH07-T06` | Create application onboarding validator | Add a focused validator that checks the service metadata and generated manifest contract for one app without running full platform validation. | `P-CH07-T05` |
| `P-CH07-T07` | Onboard one reference application | Use the templates to onboard one small non-critical reference app and record the exact golden-path steps without expanding into a developer portal. | `P-CH07-T06` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH08

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH08-T01` | Define environment registry and naming contract | Define dev/staging/production environment identifiers, domains, project mapping, and resolver inputs independently from promotion workflows. | `P-CH07-T07` |
| `P-CH08-T02` | Define environment secret and token isolation | Define per-environment GitHub Environment, Hetzner token, DNS token, and secret ownership boundaries without changing secret values. | `P-CH08-T01` |
| `P-CH08-T03` | Create Argo CD environment overlay contract | Define how GitOps manifests vary by environment while preserving common base ownership and preventing accidental production targeting. | `P-CH08-T02` |
| `P-CH08-T04` | Define promotion artifact and revision contract | Define what is promoted between environments: immutable Git revision/tag/artifact references, not rebuilt ad-hoc content. | `P-CH08-T03` |
| `P-CH08-T05` | Create promotion gates and focused smoke checks | Define pre/post-promotion gates and small environment-specific smoke checks without full platform retesting on every promotion. | `P-CH08-T04` |
| `P-CH08-T06` | Document promotion rollback and rebuild recovery | Document revert/rebuild behavior for failed promotion, including when to roll back Git versus rebuild the disposable node. | `P-CH08-T05` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH09

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH09-T01` | Classify platform state and recovery sources | Classify each critical component as Git-rebuildable, secret-recoverable, database/stateful, or disposable before choosing backup tooling. | `P-CH08-T06` |
| `P-CH09-T02` | Define backup destination retention and encryption contract | Choose backup destination, encryption, retention, naming, and verification rules suitable for the single-node cost model. | `P-CH09-T01` |
| `P-CH09-T03` | Implement PostgreSQL backup and restore primitive | Create a reusable PostgreSQL dump/restore primitive with verification using non-production/local test data only. | `P-CH09-T02` |
| `P-CH09-T04` | Define Authentik and Checkmk state recovery | Document and script the minimum component-specific state needed beyond Git for Authentik and Checkmk recovery. | `P-CH09-T03` |
| `P-CH09-T05` | Add backup health monitoring | Expose backup freshness/failure signals to the operator layer without building a new dashboard stack. | `P-CH09-T04` |
| `P-CH09-T06` | Run and document a bounded DR drill contract | Define the full restore drill procedure, evidence format, RPO/RTO measurement, and human approval gates; actual destructive drill execution remains separately approved. | `P-CH09-T05` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH10

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH10-T01` | Define PlatformInit install profiles | Define Minimal, Standard, Full, and Customer profile composition with explicit dependencies and resource expectations. | `P-CH09-T06` |
| `P-CH10-T02` | Define profile-driven installer orchestration | Design the user-facing installer/workflow entrypoint that resolves a profile into CH01-CH09 actions while preserving human approval gates. | `P-CH10-T01` |
| `P-CH10-T03` | Create component version and compatibility matrix | Create a versioned component/support matrix for Ubuntu, k3s, Argo CD, Traefik, cert-manager, Authentik, and Checkmk. | `P-CH10-T02` |
| `P-CH10-T04` | Define release artifact packaging | Define what constitutes a PlatformInit release artifact and how it maps to a validated Git revision without creating releases automatically. | `P-CH10-T03` |
| `P-CH10-T05` | Define upgrade and compatibility policy | Document supported upgrade paths, breaking-change handling, and when rebuild is preferred over in-place migration. | `P-CH10-T04` |
| `P-CH10-T06` | Create operator handbook and support matrix | Consolidate installation, recovery chain, common diagnostics, support boundaries, and profile differences into an operator-facing handbook. | `P-CH10-T05` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH11

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH11-T01` | Define resource tagging and ownership standard | Define mandatory cloud/DNS/GitOps resource tags and ownership metadata for environment, component, owner, lifecycle, and cost attribution. | `P-CH10-T06` |
| `P-CH11-T02` | Create cost and resource inventory report | Define a lightweight inventory/cost report for Hetzner hosts/volumes and related platform resources without introducing a billing platform. | `P-CH11-T01` |
| `P-CH11-T03` | Define orphan resource detection and cleanup gate | Create read-only orphan detection first and document human-approved cleanup flow for stale hosts, volumes, DNS records, and artifacts. | `P-CH11-T02` |
| `P-CH11-T04` | Define production change approval governance | Define which actions require manual approval, evidence, reviewer roles, and recovery notes as PlatformInit moves toward customer/production use. | `P-CH11-T03` |
| `P-CH11-T05` | Define periodic access and ownership review | Define a lightweight recurring review of GitHub environments, cloud project ownership, Authentik admin groups, and break-glass identities. | `P-CH11-T04` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH12

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH12-T01` | Define advanced IAM group and role matrix | Expand Authentik groups into a documented platform/application role matrix without changing every application in one task. | `P-CH11-T05` |
| `P-CH12-T02` | Standardize application role mapping | Define reusable OIDC/proxy claim-to-role mapping patterns for onboarded applications. | `P-CH12-T01` |
| `P-CH12-T03` | Define break-glass account lifecycle | Define creation, storage, use, audit, rotation, and validation of emergency local/admin access separately from everyday SSO. | `P-CH12-T02` |
| `P-CH12-T04` | Define service account lifecycle | Define technical identity ownership, credential rotation, allowed flows, and decommissioning for automation/service accounts. | `P-CH12-T03` |
| `P-CH12-T05` | Define MFA session and access-review policy | Define MFA/session requirements and periodic entitlement review for sensitive platform roles without implementing a full IAM governance suite. | `P-CH12-T04` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH13

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH13-T01` | Define AIOps privacy and execution boundary | Define what operational data may be sent to AI providers, redaction rules, human approval boundaries, and prohibited autonomous actions. | `P-CH12-T05` |
| `P-CH13-T02` | Build alert summarization prototype | Create a small prototype that turns a bounded Checkmk alert/event payload into a concise operator summary without taking action. | `P-CH13-T01` |
| `P-CH13-T03` | Build incident timeline and RCA-candidate prototype | Create a prototype that orders supplied evidence into a timeline and suggests clearly-labelled root-cause candidates. | `P-CH13-T02` |
| `P-CH13-T04` | Build runbook recommendation prototype | Map alert/incident categories to existing runbooks and safe diagnostic next steps before considering generated remediation. | `P-CH13-T03` |
| `P-CH13-T05` | Define AIOps evaluation and cost checkpoint | Define a small evaluation set, usefulness/hallucination criteria, token/cost tracking, and human acceptance gate for AIOps features. | `P-CH13-T04` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH14

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH14-T01` | Define service catalog schema | Turn CH07 service metadata into the first internal service-catalog schema with owner, repo, environment, health, docs, and dependencies. | `P-CH13-T05` |
| `P-CH14-T02` | Create golden-path template generator | Create a bounded generator for the standard application skeleton without yet provisioning external services. | `P-CH14-T01` |
| `P-CH14-T03` | Automate CI bootstrap for generated services | Add the minimum CI/validation workflow template for generated services as a separate task from GitOps registration. | `P-CH14-T02` |
| `P-CH14-T04` | Automate GitOps registration for generated services | Create the declarative Argo CD registration pattern for a generated service without auto-merging or deploying to production. | `P-CH14-T03` |
| `P-CH14-T05` | Automate operations security and docs onboarding hooks | Connect generated service metadata to monitoring, security checks, runbook/doc links, and backup classification without building the UI yet. | `P-CH14-T04` |
| `P-CH14-T06` | Build minimal developer portal MVP | Build or select the thinnest portal surface that can list catalog services and launch/refer to golden-path actions; avoid a broad portal framework migration. | `P-CH14-T05` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## CH15

| Task | Title | Bounded deliverable | Depends on |
|---|---|---|---|
| `P-CH15-T01` | Define customer-facing product boundary | Define exactly what PlatformInit includes, excludes, and guarantees for a customer/project deployment, based on the stabilized profiles. | `P-CH14-T06` |
| `P-CH15-T02` | Define customer onboarding and handover package | Create the customer-facing input checklist, install handoff, credential ownership transfer, operator docs, and acceptance checklist. | `P-CH15-T01` |
| `P-CH15-T03` | Create security and compliance statement | Create a factual customer-facing security statement derived from implemented CH06/CH11/CH12 controls without claiming certifications not held. | `P-CH15-T02` |
| `P-CH15-T04` | Define support SLO and service-boundary model | Define realistic support windows, SLO/SLA terminology, incident ownership, backup/restore expectations, and exclusions for a small platform offering. | `P-CH15-T03` |
| `P-CH15-T05` | Define demo environment contract | Define a reproducible demo environment/profile and reset procedure that shows core PlatformInit value without containing customer or production data. | `P-CH15-T04` |
| `P-CH15-T06` | Define packaging pricing and delivery options | Create an initial technical packaging model for self-hosted and managed delivery, including cost inputs and upgrade/support boundaries; no external publication is performed. | `P-CH15-T05` |

### Completion rule

Each task closes independently through implementation → focused review → OWASP/security gate → Release Manager. Do not combine adjacent rows into a single implementation task just because they belong to the same chapter.

## n8n parked-track policy

The existing n8n backlog is preserved, but the track is parked while PlatformInit is the active focus.
No n8n task should be started until an explicit human resume decision is recorded through roadmap
maintenance. Parking is not deletion and is not completion.

## Immediate next task

After P-CH04-T01 is merged, the first platform task is:

`P-CH04.5-T01 — Inventory current Authentik foundation`

This is intentionally an inventory/rationalization task, not a redeployment. It should use the
existing identity assets and produce a compact canonical ownership map before any further CH04.5
changes.

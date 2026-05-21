---
name: platforminit-architecture-map
description: Use when a task touches PlatformInit architecture, CH boundaries, roadmap, component choice, or operating model.
---


# PlatformInit Architecture Map Skill

## Mission

Help agents reason like a PlatformInit platform architect.

## Core model

PlatformInit is not a generic Kubernetes playground. It is a deterministic single-node platform bootstrap system:

```text
fresh VPS
→ host lifecycle
→ host baseline
→ k3s
→ ingress/TLS
→ Argo CD
→ Authentik
→ Checkmk operations
→ security/compliance
→ app onboarding
→ productization
```

## Chapter boundaries

| Chapter | Boundary |
|---|---|
| CH01 | Host creation, rebuild, bootstrap, access, storage layout |
| CH02 | OS baseline, hardening, drift, FIM/AIDE |
| CH03 | k3s single-node Kubernetes |
| CH04 | Traefik, cert-manager, Cloudflare DNS-01, Argo CD |
| CH04.5 | Authentik identity foundation |
| CH04.6 | Argo CD SSO |
| CH05 | Operator-first operations monitoring |
| CH06 | Security/compliance v2 |
| CH07 | Service templates/app onboarding |
| CH08 | Environment promotion |
| CH09 | Backup/DR/reliability |
| CH10-CH15 | Productization, governance, IAM, AIOps, IDP, customer-facing |

## Decision rules

- If a change crosses chapters, call it out.
- If a component adds persistent state, require backup/recovery thought.
- If a workflow mutates infrastructure, require recovery path.
- If a new UI is added, require Authentik/SSO position.
- If a new workload is long-running in cluster, prefer Argo CD ownership.
- If cost/complexity rises, justify it against single-node scope.

## Anti-patterns

- "Enterprise" additions before foundation stability.
- Manual kubectl drift as a normal deployment method.
- Dashboards that do not answer operator questions.
- Secrets hidden in docs, examples, or artifacts.

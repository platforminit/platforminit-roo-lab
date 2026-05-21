# PlatformInit Architect Rules

## Mission

Design the system before implementation. Preserve the PlatformInit architecture, roadmap, and lessons learned.

## Architectural priorities

1. Deterministic rebuild over fragile in-place repair.
2. Single-node, resource-conscious scope until the roadmap explicitly changes.
3. GitOps ownership for long-running Kubernetes workloads.
4. Operator-first monitoring over telemetry sprawl.
5. Secret boundaries and project-scoped environments.
6. Minimal operational noise.
7. CH01-CH15 chapter boundaries.

## Decision workflow

For every architectural decision:

```text
Decision:
Context:
Options considered:
Chosen option:
Why:
Rejected options:
Risk:
Validation:
Rollback/recovery:
Affected chapters:
```

## Current preferred directions

- CH01-CH05 foundation must stay stable and reproducible.
- CH05 direction is Checkmk Community with Authentik/Traefik trusted-header SSO.
- CH06 should start with diagnostics/evidence and security baseline design, not heavy auto-remediation.
- n8n should be standalone on its own small host/project when capacity allows; for lab work, keep scope explicit.
- Full productization CH10-CH15 must wait until lower layers are reproducible.

## Anti-patterns

- Adding components because they are interesting.
- Creating dashboards without operator decision value.
- Mixing host lifecycle, cluster security, identity, and productization in one patch.
- Letting AI generate broad rewrites.
- Treating archived memory as current source of truth.

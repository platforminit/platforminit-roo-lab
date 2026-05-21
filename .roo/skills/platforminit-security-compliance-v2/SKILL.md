---
name: platforminit-security-compliance-v2
description: Use when designing CH06 security/compliance, secrets, RBAC, policy, image scanning, or audit workflows.
---


# PlatformInit Security & Compliance v2 Skill

## CH06 philosophy

Start with evidence and policy design. Do not jump straight to heavy auto-remediation.

## Candidate technologies

| Area | Candidate |
|---|---|
| Secrets | SOPS/age, Sealed Secrets, Vault |
| Policy | Kyverno, OPA Gatekeeper |
| Scanning | Trivy |
| Benchmark | kube-bench |
| Runtime | Falco |
| Audit | Kubernetes audit logs |

## Recommended initial posture

For single-node PlatformInit, prefer lightweight, GitOps-friendly decisions:

1. secret inventory and leak prevention;
2. RBAC/namespace review;
3. privileged pod inventory;
4. image tag/pinning review;
5. policy proof-of-concept;
6. read-only evidence workflow;
7. only then enforcement.

## Security review must check

- hardcoded secrets;
- overly broad tokens;
- command injection;
- unsafe deletes;
- Authentik/OIDC/header trust;
- TLS misconfiguration;
- mutable image tags;
- unpinned third-party actions;
- artifact leakage.

# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.6-T03 — Validate Argo CD SSO login logout and fallback contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-6-sso-validation` |
| Scope | `platform-identity-sso` |
| Dependencies | P-CH04.6-T02 |
| Next actor | `platforminit-orchestrator` |

Stabilize focused validation and operator documentation for OIDC login, logout/session behavior, redirect correctness and emergency local access without changing unrelated identity services.

### Acceptance criteria

- [ ] focused validation covers expected OIDC login, redirect and RBAC contract
- [ ] logout/session behavior and emergency local access are explicitly documented
- [ ] repository-only validation remains distinct from any human-approved live SSO test

### Allowed files

- `platform/identity/validate/ch04-6-validate-argocd-sso.sh`
- `platform/identity/docs/ch04-6-argocd-sso-runbook.md`
- `docs/**`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.6-T03 --actor platforminit-orchestrator`

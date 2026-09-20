# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.6-T01 — Audit the existing Authentik OIDC provider contract for Argo CD

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-6-oidc-contract-audit` |
| Scope | `platform-identity-sso` |
| Dependencies | P-CH04.5-T05 |
| Next actor | `platforminit-orchestrator` |

Treat the existing CH04.6 implementation as reference-state to verify and harden, not as greenfield work; make provider/application, issuer, redirect, scope and secret-reference ownership explicit.

### Acceptance criteria

- [ ] the existing Authentik provider/application contract for Argo CD is explicit and current
- [ ] issuer, redirect URI, scopes and secret references are validated without exposing secret values
- [ ] the task reuses the existing implementation instead of recreating a parallel OIDC path

### Allowed files

- `platform/identity/scripts/ch04-6-enable-argocd-sso.sh`
- `platform/identity/integrations/argocd/**`
- `platform/identity/docs/ch04-6-argocd-sso-runbook.md`
- `platform/identity/validate/ch04-6-validate-argocd-sso.sh`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.6-T01 --actor platforminit-orchestrator`

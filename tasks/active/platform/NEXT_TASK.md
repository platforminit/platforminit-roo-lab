# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.6-T02 — Preserve identity ownership during Argo CD SSO reconciliation

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-6-preserve-identity-ownership` |
| Scope | `platform-identity-sso` |
| Dependencies | P-CH04.6-T01 |
| Next actor | `platforminit-orchestrator` |

Fix the known CH04.6 consumer behavior that can clear CH04.5-managed Authentik group attributes and keep group/RBAC reconciliation idempotent.

### Acceptance criteria

- [ ] CH04.6 group reconciliation preserves CH04.5 managed ownership attributes
- [ ] Argo CD group-to-role mapping remains deterministic and does not broaden privilege
- [ ] focused validation covers repeat reconciliation and ownership preservation

### Allowed files

- `platform/identity/scripts/ch04-6-enable-argocd-sso.sh`
- `platform/identity/validate/ch04-6-validate-argocd-sso.sh`
- `platform/identity/docs/ch04-6-argocd-sso-runbook.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.6-T02 --actor platforminit-orchestrator`

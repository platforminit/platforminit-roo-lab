# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.6-T04 — Close the CH04.6 identity integration checkpoint

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-6-checkpoint` |
| Scope | `platform-identity-sso` |
| Dependencies | P-CH04.6-T03 |
| Next actor | `platforminit-orchestrator` |

Produce a compact operator checkpoint for the existing Argo CD SSO integration, including ownership, known failure modes, recovery/fallback and the exact prerequisite chain for CH05.

### Acceptance criteria

- [ ] CH04.6 ownership and support boundaries are summarized without duplicating implementation docs
- [ ] known failure modes and break-glass recovery are actionable
- [ ] the CH05 prerequisite chain points to the current Checkmk operations architecture

### Allowed files

- `platform/identity/docs/**`
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

`python3 tools/task_controller/taskctl.py start P-CH04.6-T04 --actor platforminit-orchestrator`

# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T01 — Inventory current Authentik foundation

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-authentik-inventory` |
| Scope | `platform-identity` |
| Dependencies | P-CH04-T01 |
| Next actor | `platforminit-orchestrator` |

Audit the existing CH04.5 Authentik assets and deprecated CH06 compatibility paths, then document the canonical identity ownership boundary without changing runtime.

### Acceptance criteria

- [ ] existing CH04.5 Authentik assets and CH06 compatibility paths are inventoried
- [ ] canonical identity ownership and deprecated compatibility boundaries are documented
- [ ] no runtime mutation is performed

### Allowed files

- `platform/identity/**`
- `docs/**`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.5-T01 --actor platforminit-orchestrator`

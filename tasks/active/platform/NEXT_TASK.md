# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T04 — Define identity groups and technical users contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-identity-model` |
| Scope | `platform-identity` |
| Dependencies | P-CH04.5-T03 |
| Next actor | `platforminit-orchestrator` |

Normalize PlatformInit groups, technical users/service identities, provider templates, and bootstrap idempotence as a small identity-model unit.

### Acceptance criteria

- [ ] PlatformInit groups and technical identities have explicit ownership
- [ ] provider templates and bootstrap behavior are deterministic
- [ ] re-running identity bootstrap does not duplicate managed objects

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

`python3 tools/task_controller/taskctl.py start P-CH04.5-T04 --actor platforminit-orchestrator`

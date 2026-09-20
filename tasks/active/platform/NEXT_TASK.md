# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T04A — Align identity taxonomy with current Checkmk operations contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-checkmk-identity-alignment` |
| Scope | `platform-identity` |
| Dependencies | P-CH04.5-T04 |
| Next actor | `platforminit-orchestrator` |

Replace retired Zabbix/OpenObserve desired-state identity semantics with the current CH05 Checkmk/PlatformInit Operations contract while preserving deterministic CH04.5 ownership.

### Acceptance criteria

- [ ] retired Zabbix/OpenObserve groups are absent from active CH04.5 desired state and bootstrap memberships
- [ ] the canonical identity model defines the current operations group consumed by CH05 without inventing unsupported Checkmk role mappings
- [ ] focused identity contract validation and active CH04.5 documentation agree with the updated taxonomy

### Allowed files

- `platform/identity/groups/platforminit-groups.yaml`
- `platform/identity/users/bootstrap-technical-users.yaml`
- `platform/identity/docs/ch04-5-identity-foundation.md`
- `platform/identity/docs/ch04-5-identity-model-contract.md`
- `platform/identity/validate/ch04-5-validate-identity-model-contract.sh`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.5-T04A --actor platforminit-orchestrator`

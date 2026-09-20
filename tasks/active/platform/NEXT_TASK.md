# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T04B — Make CH05 consume the canonical operations identity

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch05-identity-consumer` |
| Scope | `platform-observability-sso` |
| Dependencies | P-CH04.5-T04A |
| Next actor | `platforminit-orchestrator` |

Remove parallel CH05 ownership of the Authentik operations group so the Checkmk SSO path consumes the CH04.5 canonical identity model instead of creating a competing group definition.

### Acceptance criteria

- [ ] CH05 Checkmk SSO reconciliation requires or reuses the canonical operations group instead of creating a parallel identity owner
- [ ] no active CH05 SSO path creates Zabbix/OpenObserve groups or depends on retired operations identities
- [ ] focused validation proves the Authentik to Traefik to auth-shim consumer boundary without runtime mutation

### Allowed files

- `platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh`
- `platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh`
- `platform/observability/checkmk/README.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.5-T04B --actor platforminit-orchestrator`

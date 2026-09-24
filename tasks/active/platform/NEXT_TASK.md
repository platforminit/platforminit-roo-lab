# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH05-T03 — Harden the Checkmk trusted-header trust boundary

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch05-trusted-header-hardening` |
| Scope | `platform-observability-security` |
| Dependencies | P-CH05-T02 |
| Next actor | `platforminit-orchestrator` |

Keep Authentik forwardAuth and the nginx trusted-header bridge, but remove bypass paths and minimize identity metadata so only the intended Traefik to auth-shim to pod-local Checkmk path is trusted.

### Acceptance criteria

- [ ] the Checkmk backend is not exposed through a cluster Service path that bypasses the auth-shim
- [ ] network policy or an equivalent bounded control restricts the auth-shim ingress to the intended Traefik path and any required agent receiver exposure is explicitly justified
- [ ] only identity headers required by the Checkmk bridge are forwarded and client-supplied authentication headers cannot become trusted upstream identity

### Allowed files

- `platform/observability/manifests/**`
- `platform/observability/validate/**`
- `platform/observability/checkmk/README.md`
- `docs/ch05-operations-monitoring-design.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH05-T03 --actor platforminit-orchestrator`

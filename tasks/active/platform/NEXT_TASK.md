# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T03 — Stabilize Authentik ingress and TLS contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-authentik-ingress-tls` |
| Scope | `platform-identity` |
| Dependencies | P-CH04.5-T02 |
| Next actor | `platforminit-orchestrator` |

Define the Authentik ingress, certificate, hostname, and TLS ownership contract independently from identity model bootstrap.

### Acceptance criteria

- [ ] Authentik hostname, ingress, certificate, and TLS ownership are explicit
- [ ] identity-model bootstrap is not coupled into ingress/TLS reconciliation
- [ ] focused repository validation covers the ingress/TLS contract

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

`python3 tools/task_controller/taskctl.py start P-CH04.5-T03 --actor platforminit-orchestrator`

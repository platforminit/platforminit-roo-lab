# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T02 — Stabilize Authentik core deployment contract

| Field | Value |
|---|---|
| Status | `in_progress` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-authentik-core-contract` |
| Scope | `platform-identity` |
| Dependencies | P-CH04.5-T01 |
| Next actor | `platforminit-deepseek-coder` |

Bound the Authentik core install to pinned chart/image inputs, secret preflight, namespace ownership, and idempotent repository-local deployment behavior.

### Acceptance criteria

- [ ] core deployment inputs are pinned or explicitly bounded
- [ ] secret and namespace preflight fails safely before mutation
- [ ] repository-local deployment behavior is idempotent and documented

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

`python3 tools/task_controller/taskctl.py submit P-CH04.5-T02 --actor platforminit-deepseek-coder`

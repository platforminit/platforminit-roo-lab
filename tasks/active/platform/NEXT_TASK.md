# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH03-T01 — Define k3s single-node install and validation contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch03-k3s-install-validation` |
| Scope | `platform` |
| Dependencies | P-CH02-T02 |
| Next actor | `platforminit-orchestrator` |

Define and implement single-node k3s install, kubeconfig, data-dir, service exposure, and reboot survival validation for the platform track.

### Acceptance criteria

- [ ] k3s install script exists and is idempotent
- [ ] kubeconfig is accessible post-install
- [ ] data-dir follows /srv contract
- [ ] service exposure works via Traefik
- [ ] reboot survival is validated
- [ ] validation script exists and passes

### Allowed files

- `platform/cluster/**`
- `docs/k3s-*.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime, GitHub secrets, or GitHub environments
- do not expose secret values

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH03-T01 --actor platforminit-orchestrator`

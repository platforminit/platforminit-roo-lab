# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04-T01 — Define platform services GitOps contract (Traefik, cert-manager, Argo CD)

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-platform-services-gitops-contract` |
| Scope | `platform` |
| Dependencies | P-CH03-T01 |
| Next actor | `platforminit-orchestrator` |

Define and implement Traefik LoadBalancer exposure, cert-manager with Cloudflare DNS-01, and Argo CD bootstrap as the GitOps control plane for the platform track.

### Acceptance criteria

- [ ] Traefik LoadBalancer exposes services on ports 80/443
- [ ] cert-manager issues Let's Encrypt certificates via Cloudflare DNS-01
- [ ] Argo CD is bootstrapped and manages its own ApplicationSet
- [ ] Platform services are deployed via Argo CD, not manual kubectl
- [ ] Validation scripts exist for each component

### Allowed files

- `platform/cluster/addons/**`
- `platform/cluster/manifests/**`
- `platform/cluster/validate/**`
- `platform/cluster/README.md`
- `docs/**`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime, GitHub secrets, or GitHub environments
- do not expose secret values

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04-T01 --actor platforminit-orchestrator`

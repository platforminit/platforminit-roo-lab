# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH05-T02 — Define the CH05 stable and rehearsal GitOps source contract

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch05-gitops-source-contract` |
| Scope | `platform-observability-gitops` |
| Dependencies | P-CH05-T01 |
| Next actor | `platforminit-orchestrator` |

Make the GitOps source boundary explicit so stable deployments may use platforminit-platform while roo-lab rehearsal can prove the tested repository and revision instead of silently reconciling another source.

### Acceptance criteria

- [ ] stable and rehearsal repository/revision choices are explicit and deterministic
- [ ] roo-lab rehearsal validation fails if Argo CD is actually syncing an unintended stable source
- [ ] AppProject source allowlisting is bounded to the intended PlatformInit repositories without implicit source switching

### Allowed files

- `platform/observability/argocd/**`
- `platform/observability/scripts/ch05-register-operations-stack.sh`
- `platform/observability/validate/**`
- `.github/workflows/deploy-05-operations-monitoring.yml`
- `.github/workflows/deploy-05-operations-diagnostics.yml`
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

`python3 tools/task_controller/taskctl.py start P-CH05-T02 --actor platforminit-orchestrator`

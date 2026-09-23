# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH05-T01 — Verify the current Checkmk GitOps runtime and retired-stack boundary

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch05-checkmk-reference-state` |
| Scope | `platform-observability` |
| Dependencies | P-WF-T14 |
| Next actor | `platforminit-orchestrator` |

Treat the existing Checkmk implementation as the current operational reference, verify runtime/storage/GitOps ownership, and keep Zabbix/OpenObserve/Vector references historical or negative-guard only.

### Acceptance criteria

- [ ] active CH05 runtime and storage ownership resolve to Checkmk Community under Argo CD
- [ ] retired Grafana/VictoriaMetrics/Loki and Zabbix/OpenObserve/Vector paths are not active deployment choices
- [ ] current operator documentation and focused validation agree on the Checkmk reference-state

### Allowed files

- `platform/observability/**`
- `docs/ch05-*.md`
- `README.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH05-T01 --actor platforminit-orchestrator`

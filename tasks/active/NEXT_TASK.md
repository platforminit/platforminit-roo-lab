# PlatformInit task dashboard

Generated from `tasks/tracker.json`. Do not edit manually.

`tasks/tracker.json` is the only authoritative task registry and mutable task state.

| Track | Current / next | Status | Branch |
|---|---|---|---|
| `platform` | `P-CH04-T01` — Define platform services GitOps contract (Traefik, cert-manager, Argo CD) | `pending` | `batch/platform-ch04-platform-services-gitops-contract` |
| `n8n` | `N8N-CH01-T01` — Validate n8n consumption of shared CH01 host lifecycle | `pending` | `batch/n8n-ch01-shared-host-lifecycle` |

Use `python3 tools/task_controller/taskctl.py next --check` for drift detection.

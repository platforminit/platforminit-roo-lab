# n8n task view

Generated from `tasks/tracker.json`. Do not edit manually.

## N8N-CH01-T01 — Validate n8n consumption of shared CH01 host lifecycle

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `n8n` |
| Branch | `batch/n8n-ch01-shared-host-lifecycle` |
| Scope | `shared-foundation` |
| Dependencies | P-CH01-T01, P-CH01-T02 |
| Next actor | `platforminit-orchestrator` |

Validate that the n8n track consumes shared CH01 host lifecycle with standalone constraints.

### Acceptance criteria

- [ ] n8n host lifecycle uses shared CH01 contracts
- [ ] project=n8n resolves n8n environment and token
- [ ] effective volume layout is none
- [ ] no attached volume is required

### Allowed files

- `docs/roo-lab/N8N_ROADMAP.md`
- `.roo/skills/platforminit-n8n-standalone/SKILL.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not create k3s for n8n host
- do not target production/customer scope

### Controller transition

`python3 tools/task_controller/taskctl.py start N8N-CH01-T01 --actor platforminit-orchestrator`

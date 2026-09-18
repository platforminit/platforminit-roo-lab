# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T07 — Create standalone n8n roadmap and task registry

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t07-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T06 |
| Next actor | `platforminit-orchestrator` |

Move the preserved parked n8n backlog into its own roadmap and canonical parked registry.

### Acceptance criteria

- [ ] n8n roadmap lives outside the PlatformInit roadmap
- [ ] n8n task registry is separate from tasks/tracker.json
- [ ] PlatformInit controller cannot start n8n tasks

### Allowed files

- `n8n/**`
- `docs/n8n/**`
- `docs/roo-lab/**`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T07 --actor platforminit-orchestrator`

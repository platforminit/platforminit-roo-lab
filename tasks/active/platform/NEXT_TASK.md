# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T06 — Detach n8n from PlatformInit canonical task state

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t06-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T05 |
| Next actor | `platforminit-orchestrator` |

Remove n8n tasks and track selection from PlatformInit canonical queue and generated views.

### Acceptance criteria

- [ ] tasks/tracker.json contains only PlatformInit tasks
- [ ] PlatformInit next-task flow has no n8n branch
- [ ] historical shared-foundation references remain documentation only

### Allowed files

- `tasks/**`
- `.roo/commands/**`
- `tools/platforminit_mcp/**`
- `scripts/orchestrator/**`
- `docs/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T06 --actor platforminit-orchestrator`

# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T01 — Enforce fresh-child lifecycle handoffs

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t01-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-CH04.5-T02 |
| Next actor | `platforminit-orchestrator` |

Make every implementation, review, security, and release stage a fresh Zoo child task with compact handoff only.

### Acceptance criteria

- [ ] all lifecycle stage changes use native Zoo new_task
- [ ] child completion returns concise evidence and resulting controller state
- [ ] orchestrator reloads MCP delivery context after every child

### Allowed files

- `.roomodes`
- `.roo/commands/**`
- `docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T01 --actor platforminit-orchestrator`

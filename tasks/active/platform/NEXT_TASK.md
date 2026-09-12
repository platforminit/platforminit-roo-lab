# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T03 — Shrink MCP delivery context budget

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t03-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T02 |
| Next actor | `platforminit-orchestrator` |

Reduce delivery-context payload size and remove cross-project branching from the PlatformInit MCP.

### Acceptance criteria

- [ ] PlatformInit MCP is platform-only
- [ ] changed-scope default and hard cap are bounded for small tasks
- [ ] delivery context returns only stage-critical fields

### Allowed files

- `.roo/mcp.json`
- `tools/platforminit_mcp/**`
- `docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T03 --actor platforminit-orchestrator`

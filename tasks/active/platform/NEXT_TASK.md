# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T02 — Verify MCP access across every Zoo mode

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t02-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T01 |
| Next actor | `platforminit-orchestrator` |

Add static and runtime smoke coverage proving every PlatformInit mode can access the PlatformInit MCP after fresh-child mode changes.

### Acceptance criteria

- [ ] every PlatformInit mode declares MCP access
- [ ] MCP health/get_active_task smoke path is documented and testable
- [ ] mode changes do not depend on conversation-carried context

### Allowed files

- `.roomodes`
- `.roo/mcp.json`
- `.roo/commands/**`
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

`python3 tools/task_controller/taskctl.py start P-WF-T02 --actor platforminit-orchestrator`

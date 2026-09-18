# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T08 — Smoke-test fresh-child delivery pipeline

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t08-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T07 |
| Next actor | `platforminit-orchestrator` |

Verify the compact implementation-review-security-release route without broad reads or full-repo validation.

### Acceptance criteria

- [ ] fresh child is used for every specialist stage
- [ ] MCP context is available after each handoff
- [ ] handoff payload remains bounded and no stale stage is executed

### Allowed files

- `.roomodes`
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

`python3 tools/task_controller/taskctl.py start P-WF-T08 --actor platforminit-orchestrator`

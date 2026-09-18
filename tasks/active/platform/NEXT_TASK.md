# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T05 — Enforce micro-task sizing

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t05-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T04 |
| Next actor | `platforminit-orchestrator` |

Make the small-context file budget enforceable instead of prompt-only.

### Acceptance criteria

- [ ] target is 1-3 primary product files
- [ ] 4-5 primary files require an explicit warning
- [ ] more than 5 non-state files blocks submit with TASK_TOO_LARGE_SPLIT_REQUIRED

### Allowed files

- `tools/task_controller/**`
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

`python3 tools/task_controller/taskctl.py start P-WF-T05 --actor platforminit-orchestrator`

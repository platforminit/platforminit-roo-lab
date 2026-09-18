# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T04 — Reuse unchanged validation evidence

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `chore/p-wf-t04-workflow` |
| Scope | `workflow-tooling` |
| Dependencies | P-WF-T03 |
| Next actor | `platforminit-orchestrator` |

Define source/evidence fingerprint reuse so unchanged passing validators are not rerun at release.

### Acceptance criteria

- [ ] submit records a deterministic source fingerprint
- [ ] release reuses passing validator evidence when the fingerprint is unchanged
- [ ] changed source invalidates reuse and runs only required focused validators

### Allowed files

- `tools/task_controller/**`
- `docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T04 --actor platforminit-orchestrator`

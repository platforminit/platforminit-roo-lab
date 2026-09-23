# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T14 — Define the continuous project memory lifecycle

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `feat/p-wf-t14-project-memory-lifecycle` |
| Scope | `workflow-memory` |
| Dependencies | P-WF-T13 |
| Next actor | `platforminit-orchestrator` |

Establish a safe reviewed lifecycle for converting accepted task/review/security outcomes into bounded project-memory candidates and promoting them without turning memory into task state or hidden agent state.

### Acceptance criteria

- [ ] release flow defines when a completed task may emit bounded project-memory candidates from approved evidence
- [ ] candidate and promotion rules require source provenance, schema validation, deduplication, and explicit advisory-only semantics
- [ ] raw transient logs and secrets are never copied into project memory and retrieval ignores unpromoted candidates
- [ ] the lifecycle remains compatible with a later evidence-distillation feature without broadening current task state authority

### Allowed files

- `tools/platforminit_mcp/memory.py`
- `.roo/rules-platforminit-release-manager/rules.md`
- `docs/roo-lab/RAG_FUTURE.md`
- `tasks/**`

### Required validators

- `python3 -m py_compile tools/platforminit_mcp/memory.py`
- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T14 --actor platforminit-orchestrator`

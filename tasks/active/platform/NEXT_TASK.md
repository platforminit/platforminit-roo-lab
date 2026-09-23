# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T13 — Integrate bounded memory retrieval into Zoo child startup

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `feat/p-wf-t13-zoo-memory-usage` |
| Scope | `workflow-memory` |
| Dependencies | P-WF-T12 |
| Next actor | `platforminit-orchestrator` |

Make relevant framework/project memory part of the normal small-context Zoo workflow after authoritative delivery context and before broad source/history reads.

### Acceptance criteria

- [ ] every PlatformInit Zoo specialist starts from health and get_delivery_context, then requests bounded get_relevant_memory before broad historical reads
- [ ] mode/rule text keeps memory explicitly advisory and lower priority than current source and taskctl state
- [ ] static mode validation fails when a PlatformInit mode loses the bounded memory bootstrap contract

### Allowed files

- `.roomodes`
- `.roo/rules.md`
- `tools/platforminit_mcp/validate_mode_access.py`
- `tasks/**`

### Required validators

- `python3 tools/platforminit_mcp/validate_mode_access.py --runtime`
- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T13 --actor platforminit-orchestrator`

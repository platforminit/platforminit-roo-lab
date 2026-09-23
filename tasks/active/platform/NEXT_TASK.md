# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T10 — Add memory CI and runtime smoke coverage

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `feat/p-wf-t10-memory-ci` |
| Scope | `workflow-memory` |
| Dependencies | P-CH04.6-T04 |
| Next actor | `platforminit-orchestrator` |

Make the Zoo memory subsystem a first-class tested MCP contract so CI fails when memory parsing, retrieval, tool exposure, or bounded-input behavior regresses.

### Acceptance criteria

- [ ] Task integrity CI compiles and runs focused tests for the memory subsystem
- [ ] get_relevant_memory is required by MCP static validation and exercised by runtime smoke
- [ ] invalid memory-tool inputs fail as controlled bounded JSON-RPC errors without host-path leakage

### Allowed files

- `.github/workflows/task-integrity.yml`
- `tools/platforminit_mcp/validate_mode_access.py`
- `tools/platforminit_mcp/test_memory.py`
- `tasks/**`

### Required validators

- `python3 -m unittest tools.platforminit_mcp.test_memory -v`
- `python3 tools/platforminit_mcp/validate_mode_access.py --runtime`
- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T10 --actor platforminit-orchestrator`

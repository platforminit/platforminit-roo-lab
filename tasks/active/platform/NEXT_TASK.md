# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T12 — Implement deterministic memory supersession

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `feat/p-wf-t12-memory-supersession` |
| Scope | `workflow-memory` |
| Dependencies | P-WF-T11 |
| Next actor | `platforminit-orchestrator` |

Make supersedes operational so active replacement records suppress obsolete active records deterministically instead of relying on manual status edits.

### Acceptance criteria

- [ ] active records suppress every record ID they explicitly supersede before ranking
- [ ] supersession chains are deterministic and cycles or malformed self-supersession fail closed
- [ ] focused tests prove superseded facts cannot reappear in bounded retrieval while historical/deprecated records remain non-active context

### Allowed files

- `tools/platforminit_mcp/memory.py`
- `tools/platforminit_mcp/test_memory.py`
- `tasks/**`

### Required validators

- `python3 -m unittest tools.platforminit_mcp.test_memory -v`
- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate runtime infrastructure, secrets, or GitHub environments
- do not expose secret values
- do not run full-repository validation unless explicitly required

### Controller transition

`python3 tools/task_controller/taskctl.py start P-WF-T12 --actor platforminit-orchestrator`

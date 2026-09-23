# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-WF-T11 — Harden project memory relevance ranking

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `feat/p-wf-t11-memory-ranking` |
| Scope | `workflow-memory` |
| Dependencies | P-WF-T10 |
| Next actor | `platforminit-orchestrator` |

Fix the v1 retrieval scoring so project scope is only a ranking preference for already relevant records and cannot qualify zero-overlap records into bounded results.

### Acceptance criteria

- [ ] a project-scope bonus never makes a zero-overlap record eligible for a non-empty query
- [ ] task/component exact matches and lexical overlap remain deterministic and bounded
- [ ] focused tests cover irrelevant project records, tie-breaking, empty-query baseline, and maxItems limits

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

`python3 tools/task_controller/taskctl.py start P-WF-T11 --actor platforminit-orchestrator`

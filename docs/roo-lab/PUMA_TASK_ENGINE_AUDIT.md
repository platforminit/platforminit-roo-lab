# Project Puma task-engine audit and PlatformInit gap map

This document records the read-only audit performed against `platforminit/projectpuma` `dev` before the PlatformInit task-engine refactor.

Project Puma was used as a reference only. No Project Puma files were modified.

## Audited Project Puma behavior

The current Puma implementation uses:

- `project/tasks.json` as the single authoritative mutable task tracker;
- `tools/task-runner/taskctl.mjs` as the controller for validation, selection, lifecycle transitions, generated views, evidence gates, and task closure;
- `next_task.md` and `docs/tasks/MVP_BACKLOG.md` as generated read-only views;
- `tools/task-runner/evidence-policy.mjs` for bounded evidence/review report policy;
- `tools/puma-mcp/context.mjs` + `server.mjs` for compact task/changed-scope/quality context;
- Roo custom modes that load compact delivery context first and treat tracker state as authoritative.

The audited Puma lifecycle is:

```text
pending
  -> in_progress
  -> needs_test
  -> needs_review
  -> ready_to_close
  -> done
```

Puma additionally supports `blocked`. Test/review failures return the task to implementation. Only the Puma Orchestrator may close a ready task, and passing independent test/review records are required. Generated-view drift is validated. Dependencies, duplicate task IDs, invalid statuses, cycles, and multiple active tasks are rejected.

Puma's submit step runs an affected preflight. Passing adversarial test runs task gates and records a quality fingerprint; completion can reuse that passing gate only when the source/test fingerprint remains unchanged.

## PlatformInit pre-refactor gap map

| Area | Before refactor | Puma reference | Migration decision |
|---|---|---|---|
| Mutable state | duplicated in `tasks/status/*.json` and `tasks/roadmap/*.json` | one tracker | move to `tasks/tracker.json` |
| Current pointer | duplicated and synchronized defensively | derived from tracker status/order | derive runnable task from state/dependencies/order |
| NEXT_TASK | root plus per-track files, with stale competing active files | generated views only | keep dashboard + per-track generated views only |
| Legacy active context | `CURRENT_ACTIVE_TASKS.md`, `NEXT_TASK_AGENT_LAYER.md`, `ACTIVE_AGENT_CONTEXT.md` could appear authoritative | no competing current-task source | remove stale active sources |
| Lifecycle | start/close scripts primarily mutate pointer/status | controller-owned state machine | add `taskctl.py` transitions |
| Review evidence | Roo prose verdicts | tracker-recorded independent gates | record reviewer + OWASP reports/verdicts in tracker workflow state |
| Completion | close script writes two state files | controller checks legal state/gates | Release Manager-only `taskctl complete` |
| Drift validation | split-brain regression guards in close script | generic generated-view validation | controller-wide integrity validation |
| Context | roles often begin from Markdown/current context | compact MCP delivery context | add repository-local compact MCP provider |
| Indexing | available to Roo but not part of task contract | path-scoped indexed search expected | make path-scoped codebase search the default discovery path |
| RAG | not defined | not authoritative task state | scaffold future retrieval boundary only |

## Intentional PlatformInit deviations

PlatformInit keeps two delivery tracks, `platform` and `n8n`, instead of Puma's single ordered MVP stream. The tracker is still singular, while runnable selection is performed per track.

PlatformInit also keeps a dedicated OWASP gate, so its lifecycle is:

```text
pending
  -> in_progress
  -> needs_review
  -> needs_security_review
  -> ready_to_close
  -> done
```

This is intentionally stricter than the audited Puma flow rather than a literal copy.

The first controller version uses task-declared validator argv lists and `git diff --check`; it does not copy Puma's quality fingerprint or evidence-matrix implementation. Those are candidate follow-up improvements, not falsely claimed parity.

## Legacy-state migration note

The old status/roadmap files are removed from active paths so they cannot compete with the canonical tracker. The canonical `P-*` tasks from the active platform order and the n8n backlog were migrated into `tasks/tracker.json`. Old `PLATFORM-*` planning entries are considered historical/superseded rather than runnable canonical tasks; their prior content remains available in Git history.

An open pre-refactor PR may still reference the removed roadmap/status paths. Such PRs must be rebased or adapted to `tasks/tracker.json` before merge rather than recreating the retired split-brain design.

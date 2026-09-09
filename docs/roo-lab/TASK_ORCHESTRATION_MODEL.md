# Multi-Track Task Orchestration Model

PlatformInit Roo Lab keeps separate `platform` and `n8n` delivery tracks, but they now share one canonical task engine.

## Authoritative state

`tasks/tracker.json` is the only authoritative task registry and mutable task state.

The following are generated/read-only views:

- `tasks/active/NEXT_TASK.md` — dashboard across tracks;
- `tasks/active/platform/NEXT_TASK.md`;
- `tasks/active/n8n/NEXT_TASK.md`.

Legacy `tasks/status/*.json`, `tasks/roadmap/*.json`, `CURRENT_ACTIVE_TASKS.md`, and `NEXT_TASK_AGENT_LAYER.md` are retired. Historical content remains recoverable from Git history; agents must not recreate those paths as active state.

## Tracks and shared foundation

- `platform`: canonical `P-*` PlatformInit work.
- `n8n`: standalone n8n work.

The n8n track consumes shared PlatformInit CH01/CH02 capabilities but diverges after the host foundation. It does not require local k3s, local Argo CD, or the main platform Checkmk runtime as prerequisites unless a later task explicitly changes that contract.

## Lifecycle

The controller owns legal transitions:

```text
pending
  -> in_progress
  -> needs_review
  -> needs_security_review
  -> ready_to_close
  -> done
```

Rework and blocker transitions are explicit:

- reviewer `request_changes` -> `in_progress`;
- OWASP `review_required` -> `in_progress`;
- reviewer/OWASP `block` -> `blocked`;
- Orchestrator-only `unblock` restores the prior legal state.

Direct completion from any state other than `ready_to_close` is illegal.

## Roles

- Orchestrator selects and starts exactly one runnable task per track.
- DeepSeek Coder implements only the task's `allowedFiles` scope and submits through the controller.
- OpenAI Reviewer records a report and verdict through `taskctl review`.
- OWASP Reviewer records a report and verdict through `taskctl security`.
- Release Manager closes only after both independent gates pass.

Generated files must never be hand-edited to change state.

## Commands

```bash
python3 tools/task_controller/taskctl.py list
python3 tools/task_controller/taskctl.py next --track platform
python3 tools/task_controller/taskctl.py next --track n8n
python3 tools/task_controller/taskctl.py validate
```

Compatibility wrappers under `scripts/orchestrator/` now delegate to `taskctl` instead of maintaining a second state machine.

## Integrity rules

`taskctl validate` detects:

- duplicate task IDs;
- invalid statuses;
- missing/self/cyclic dependencies;
- more than one active task per track;
- generated-view drift;
- obsolete legacy authoritative task artifacts;
- active branch/task mismatch unless branch checking is explicitly disabled for CI/static validation.

The CI workflow `.github/workflows/task-integrity.yml` runs lifecycle tests, tracker/generated-view integrity, Python syntax checks, and `git diff --check`.

## Context minimization, MCP, and indexing

`tools/platforminit_mcp/` exposes compact task and changed-scope context. Roo roles should prefer `get_delivery_context` or the equivalent repository-local helper before opening broad files, then use path-scoped `codebase_search` / codebase indexing for discovery.

The MCP layer is a context boundary, not another task database. It reads `tasks/tracker.json` and the current Git diff and returns only task-relevant metadata, changed files, focused-test hints, and suggested indexed-search paths.

## Future RAG

RAG is intentionally scaffolding-only in this refactor. See `docs/roo-lab/RAG_FUTURE.md`. Retrieval may later enrich architecture/runbook/history context, but `tasks/tracker.json` remains authoritative task state and generated task views remain controller-owned.

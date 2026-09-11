---
description: Load and drive the next runnable PlatformInit task
argument-hint: [platform]
mode: platforminit-orchestrator
---

Use the `platform` track. The n8n track is parked and must not be started unless a human explicitly resumes it through roadmap maintenance.

Load PlatformInit MCP `get_delivery_context` for `platform` first. Use `get_active_task` plus
`get_changed_scope` only if the compound context tool is unavailable. Do not read all of
`tasks/tracker.json`, historical roadmap material, or unrelated chapters unless the compact context
is missing or inconsistent.

If the selected task is `pending`, validate generated state with `taskctl validate --ignore-branch`,
resolve its exact branch, create/switch that branch from fresh `dev`, then start only through the
controller:

`python3 tools/task_controller/taskctl.py start <TASK-ID> --actor platforminit-orchestrator`

Drive exactly one bounded task through the Zoo Code workflow. After every child/handoff returns,
reload `get_delivery_context` and route only from authoritative controller status:

- `in_progress` -> `implementationMode`;
- `needs_review` -> `reviewMode`;
- `needs_security_review` -> `securityMode`;
- `ready_to_close` -> `releaseMode`;
- `blocked` -> report the concrete blocker and stop;
- `done` -> report the PR/closure result and the next pending platform task, but do not start it
  before the current PR is merged to `dev`.

Use a native Zoo Code handoff to the returned mode; never end with only a textual mode suggestion.
Pass only task ID, current stage, acceptance gaps, changed paths, focused evidence, unresolved risks,
and the controller transition needed for that stage.

## Small-context execution contract

- Target **1-6 primary changed files** per task.
- If the work would exceed **8 unique non-state files**, cross more than one subsystem/operator
  contract, or require broad repository rereads, stop with `TASK_TOO_LARGE_SPLIT_REQUIRED` and split
  the work instead of continuing.
- Prefer path-scoped codebase indexing/search before raw broad reads.
- Run only focused changed-scope validation required by the task. Never run full-repository tests or
  broad quality suites unless the task explicitly requires them or a changed shared dependency
  invalidates previous evidence.
- Reuse unchanged passing evidence; do not rerun checks merely for reassurance.
- Return review/test defects as one consolidated batch.
- If Zoo Code reaches context exhaustion/API 400, stop the current child and continue in a fresh
  task/handoff using compact delivery context and evidence paths; do not rebuild context by rereading
  the repository broadly.

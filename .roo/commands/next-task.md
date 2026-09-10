---
description: Load and drive the next runnable PlatformInit task
argument-hint: [platform|n8n]
mode: platforminit-orchestrator
---

Use `platform` unless the invocation explicitly names `n8n`.

Load PlatformInit MCP `get_delivery_context` for that track first. Use `get_active_task` plus
`get_changed_scope` only if the compound context tool is unavailable. Do not read all of
`tasks/tracker.json`, legacy roadmap files, or unrelated chapters unless the compact context is
missing or inconsistent.

If the selected task is `pending`, validate generated state with `taskctl validate --ignore-branch`,
resolve its exact branch, create/switch that branch from fresh `dev`, then start only through the
controller:

`python3 tools/task_controller/taskctl.py start <TASK-ID> --actor platforminit-orchestrator`

Drive exactly one task through the Zoo Code workflow. After every child/handoff returns, reload
`get_delivery_context` and route only from authoritative controller status:

- `in_progress` -> `implementationMode`;
- `needs_review` -> `reviewMode`;
- `needs_security_review` -> `securityMode`;
- `ready_to_close` -> `releaseMode`;
- `blocked` -> report the concrete blocker and stop;
- `done` -> report the PR/closure result and the next pending task, but do not start it before the
  current PR is merged to `dev`.

Use a native Zoo Code handoff to the returned mode; never end with only a textual mode suggestion.
Pass only task ID, stage, acceptance gaps, changed paths, focused evidence, unresolved risks, and the
controller transition needed for that stage.

Token/test discipline: prefer path-scoped codebase indexing over broad reads, never run full-repo
validation unless it is explicitly listed by the task, never repeat an unchanged passing check just
for reassurance, and consolidate findings before returning implementation rework.

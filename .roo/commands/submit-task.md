---
description: Submit the active PlatformInit implementation to its controller validation gate
argument-hint: <TASK-ID>
mode: platforminit-deepseek-coder
---

Load PlatformInit MCP `get_delivery_context` for the task and inspect only the returned changed scope,
acceptance criteria, and required validators. Use path-scoped codebase indexing for any missing
impact context; do not read unrelated chapters or the full tracker.

Before submission, confirm the patch stays inside `allowedFiles`, acceptance criteria have concrete
evidence, and no forbidden action was taken. Run only focused checks needed while fixing a known
failure. Do not pre-run the entire validator set merely to duplicate what the controller will run.

Submit exactly once through:

`python3 tools/task_controller/taskctl.py submit <TASK-ID> --actor <implementationMode>`

`taskctl submit` owns the required validator gate and moves the task to `needs_review` only on
success. If it fails, fix the consolidated failure set and resubmit; do not add broad/full-repo tests
unless the task explicitly requires them.

After success, return concise evidence and use a native Zoo Code handoff to the task's `reviewMode`.

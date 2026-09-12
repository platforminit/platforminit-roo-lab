---
description: Load and drive the next runnable PlatformInit task
mode: platforminit-orchestrator
---

PlatformInit only. n8n has a separate roadmap/task registry and is not part of this command.

Start with PlatformInit MCP `health`, then `get_delivery_context`. Use `get_active_task` plus
`get_changed_scope` only if the compound tool is unavailable. Do not read all of `tasks/tracker.json`,
roadmap history, prior child conversations, or unrelated chapters when compact context is sufficient.

If the selected task is `pending`, validate generated state with `taskctl validate --ignore-branch`,
create/switch the exact task branch from fresh `dev`, and start only through taskctl.

## Fresh-child lifecycle contract

Every specialist stage MUST be a native Zoo `new_task` child. Never continue implementation,
review, security, or release by merely switching mode inside the same accumulated conversation.

For each stage:

1. Reload MCP `get_delivery_context`.
2. Select exactly the controller-returned `nextMode`.
3. Start one fresh `new_task` child.
4. Pass only: task ID, current stage, acceptance gaps, changed paths, focused evidence paths,
   unresolved risks, and the required controller transition.
5. Require the child to call `attempt_completion` with the resulting controller status, the exact next
   controller transition command, and concise evidence.
6. When the child returns, discard stage conversation context and reload MCP before routing again.

Route only from authoritative status:

- `in_progress` -> implementationMode
- `needs_review` -> reviewMode
- `needs_security_review` -> securityMode
- `ready_to_close` -> releaseMode
- `blocked` -> report blocker and stop
- `done` -> report closure/PR and stop; do not auto-start the next task before merge to `dev`

## Token and task-size contract

- Target **1-3 primary non-state changed files**.
- **4-5** primary files is exceptional and should be justified in the handoff.
- **More than 5 non-state files** or more than one subsystem/operator contract => stop with
  `TASK_TOO_LARGE_SPLIT_REQUIRED` and split before continuing.
- Use path-scoped codebase search before raw reads.
- Run focused changed-scope validation only.
- Do not run full-repository validation unless the task explicitly requires it or a changed shared
  dependency invalidates previous evidence.
- Reuse unchanged passing evidence; never rerun checks only for reassurance.
- Review/security defects return as one consolidated batch in a new implementation child.
- On API 400/context exhaustion, terminate the current child and resume in a fresh child from MCP
  compact context; never rebuild the old conversation by broad rereads.

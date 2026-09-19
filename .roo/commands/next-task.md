---
description: Load and drive the next runnable PlatformInit task
mode: platforminit-orchestrator
---

PlatformInit only. n8n has a separate roadmap/task registry and is not part of this command.

## Startup gate (ordered, before any MCP task resolution)

Resolve a runnable task only from a freshly fetched `dev`. Run these steps in order and stop on the first
failure:

1. Verify WSL and the repository root: `pwd`, the WSL marker in `/proc/version`, `id -un`, and the
   expected workspace root. Stop if this is not WSL Ubuntu at `/mnt/d/SYSADMIN/platforminit-roo-lab`.
2. Inspect the working tree safely with `git status --short` and `git branch --show-current`. Treat dirty
   or unexpected files as information about in-flight work, never as something to clean up.
3. Run `git fetch origin` so no routing decision is taken on stale local refs.
4. Refresh local `dev` to `origin/dev` fast-forward-only (`git fetch origin dev` plus
   `git merge --ff-only origin/dev`), and only on a clean checkout of `dev` or a disposable worktree.
5. Never `reset --hard`, never force-push, never rebase, and never discard dirty work automatically.
6. If a safe fast-forward is not possible — dirty tree, diverged `dev`, or an in-flight feature branch
   with uncommitted work — HARD STOP with evidence. Never destroy an in-flight dirty feature branch;
   report the blocker instead of rewriting history and continue only after a human decision.
7. Only after fresh `dev` is established, call MCP `health` then `get_delivery_context` and resolve the
   runnable task. Use `get_active_task` plus `get_changed_scope` only if the compound tool is
   unavailable. Do not read all of `tasks/tracker.json`, roadmap history, prior child conversations, or
   unrelated chapters when compact context is sufficient.

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
7. A specialist child is terminal: it runs exactly this one stage, records its own controller transition
   with `taskctl`, then finishes with `attempt_completion` and terminates. It never calls `new_task`,
   never spawns a child, never switches mode to continue the lifecycle, and never hands off the next
   lifecycle stage; the orchestrator is the only next-stage routing owner. A specialist child that
   launches the next lifecycle stage itself is a runtime FAIL of the pipeline smoke, so re-run that stage
   as a fresh child instead of continuing the conversation.

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

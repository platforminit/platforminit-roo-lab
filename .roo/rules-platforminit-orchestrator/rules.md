# PlatformInit Orchestrator Rules

## Mission

Coordinate exactly one tracked PlatformInit task through its lifecycle. Do not become the coder and do not self-approve work.

## Startup gate

For initial `/next-task` resolution, establish a fresh local `dev` **before any MCP task resolution**:

1. Verify WSL Ubuntu, repository root, current branch, and working tree.
2. Treat dirty or unexpected files as in-flight work; never clean or discard them automatically.
3. Run `git fetch origin`.
4. Refresh local `dev` from `origin/dev` with fast-forward-only semantics, and only from a clean `dev` checkout or a disposable worktree.
5. Never `reset --hard`, rebase, force-push, or discard dirty work to make the refresh succeed.
6. If `dev` is dirty/diverged or an in-flight feature branch cannot be left safely, hard-stop with evidence.
7. Only after fresh `dev` is established, call MCP `health` then `get_delivery_context`, then use taskctl for authoritative transition/state checks.

The canonical ordered startup contract is `.roo/commands/next-task.md`.

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git status --short
git branch --show-current
git fetch origin
# after confirming it is safe to use a clean local dev checkout:
git switch dev
git merge --ff-only origin/dev
python3 tools/task_controller/taskctl.py validate --ignore-branch
python3 tools/task_controller/taskctl.py next --track platform
```

After a task has been started on its feature branch, do **not** return to `dev` between lifecycle stages. Reload MCP `get_delivery_context` on the active task branch after each specialist child returns and route only from that authoritative controller state.

`tasks/tracker.json` is authoritative for PlatformInit. Generated `tasks/active/**/NEXT_TASK.md` is read-only. n8n is separate and must not be selected through this controller.

## Controller flow

1. Resolve the runnable PlatformInit task and exact branch only after the fresh-`dev` startup gate.
2. Create/switch the tracker-declared branch from fresh `dev`. For newly introduced feature work, require a `feat/` branch; never create a new `batch/` branch. Existing tracker tasks with legacy `batch/` branches remain valid and must not be renamed mid-lifecycle.
3. Start only with `taskctl start <TASK> --actor platforminit-orchestrator`.
4. Reload MCP `get_delivery_context`.
5. Start exactly one fresh Zoo `new_task` child in the returned `nextMode`.
6. Pass only task ID, stage, acceptance gaps, changed paths, focused evidence paths, unresolved risks, and required controller transition.
7. Require the child to call `attempt_completion` with resulting controller status and concise evidence.
8. When the child returns, discard stage conversation context and reload MCP before routing again.
9. Rework verdicts return to the implementation actor in a fresh child.
10. Never close while review/security gates are unresolved.

## Small-context discipline

- Target 1-3 primary non-state files.
- 4-5 files is exceptional.
- Above 5 non-state files or more than one subsystem/operator contract: stop with `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- Path-scoped search before raw reads.
- No broad roadmap/history rereads.
- No full-repository validation unless explicitly required or invalidated by changed shared dependencies.
- Reuse unchanged passing evidence.

## API 400 recovery

Terminate the current child. Start a fresh child in the controller-selected mode, call MCP `health` and `get_delivery_context`, and resume only from compact evidence paths. Never reconstruct the failed context by rereading broadly.

## Hard stops

Stop and report on unapproved production/customer scope, secret exposure, branch-task mismatch, stale task metadata, generated-view drift, unavailable validation, unsafe fresh-`dev` refresh, or cross-project/n8n queue mixing.

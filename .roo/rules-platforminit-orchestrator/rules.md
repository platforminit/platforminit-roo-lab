# PlatformInit Orchestrator Rules

## Mission

Coordinate exactly one tracked PlatformInit task through its lifecycle. Do not become the coder and do not self-approve work.

## Startup gate

Load MCP `health` and `get_delivery_context` first. Use taskctl only for authoritative transition/state checks.

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
python3 tools/task_controller/taskctl.py validate --ignore-branch
python3 tools/task_controller/taskctl.py next --track platform
```

Then verify WSL, repository root, branch, and working tree. Stop on wrong root, failed WSL gate, unexpected changes, or branch-task mismatch.

`tasks/tracker.json` is authoritative for PlatformInit. Generated `tasks/active/**/NEXT_TASK.md` is read-only. n8n is separate and must not be selected through this controller.

## Controller flow

1. Resolve the runnable PlatformInit task and exact branch.
2. Create/switch the branch from fresh `dev`.
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

Stop and report on unapproved production/customer scope, secret exposure, branch-task mismatch, stale task metadata, generated-view drift, unavailable validation, or cross-project/n8n queue mixing.

# NEXT TASK — platform

## Task

- Track: `platform`
- Task ID: `P-CH02-T02`
- Chapter: `CH02`
- Title: Implement baseline profile separation
- Branch: `batch/platform-ch02-baseline-profile-separation`
- Scope: `shared-foundation`

## Goal

Separate platform-k3s and standalone-n8n baseline profiles while preserving shared hardening primitives.

## Shared foundation model

This task does not consume a shared platform dependency.

No same-track dependency is declared for this current pointer.

## Acceptance criteria

- Acceptance criteria must be refined during task execution.

## Forbidden actions

- Do not resurrect deprecated CH05 directions as active work.
- Do not expose secret values.
- Do not use Windows shell, PowerShell, CMD, Git Bash, or MobaXterm for Roo execution.
- Do not target production/customer scope unless explicitly approved.

## Required startup

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track platform
```

## Roo entrypoint

```text
Read tasks/active/platform/NEXT_TASK.md and execute the active task exactly as described.
```

## Native role handoff

PlatformInit roles must use native Roo `switch_mode` handoff.

Manual next-prompt printing is allowed only if native `switch_mode` is unavailable or blocked, and the role must explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Release Manager executor requirements

After OWASP review passes, the PlatformInit Release Manager MUST execute the full lifecycle:

1. Detect the active task ID from `tasks/status/platform.json`.
2. Verify changed files and validation evidence are complete.
3. Create a scoped implementation commit with a descriptive message.
4. Push the branch to origin.
5. Open a PR via `gh` CLI. If `gh` is unavailable, produce manual PR instructions and mark `BLOCKED_BY_TOOLING`.
6. After merge, run `./scripts/orchestrator/close-current-task.sh`.
7. Verify status/roadmap/NEXT_TASK agreement.
8. Commit and push closure metadata.
9. Start or prepare the next task.

The Release Manager MUST NOT stop at "human commit pending" unless the blocker is explicitly marked `BLOCKED_BY_PERMISSION` or `BLOCKED_BY_TOOLING`.

Forbidden phrases that must NOT appear as active contract wording:

- `final human commit/PR/merge handoff`
- `human commit pending`
- `commit recommendation` (when used as a handoff instruction)

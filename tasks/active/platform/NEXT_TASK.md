# NEXT TASK — platform

## Task

- Track: `platform`
- Task ID: `P-CH01-T02`
- Chapter: `CH01`
- Title: Implement shared start/rebuild task contract
- Branch: `batch/platform-ch01-shared-start-rebuild-contract`
- Scope: `shared-foundation`

## Goal

Make CH01 reusable by platform and n8n tracks without duplicating host lifecycle logic.

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

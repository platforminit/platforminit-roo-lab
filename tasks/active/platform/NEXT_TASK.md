# NEXT TASK — platform

## Task

- Track: `platform`
- Task ID: `P-CH01-T01`
- Chapter: `CH01`
- Title: Validate shared host lifecycle contract
- Branch: `batch/platform-ch01-host-lifecycle-contract`
- Scope: `shared-foundation`

## Goal

Validate reusable CH01 host lifecycle contract for both platform and n8n tracks.

## Shared foundation model

This task does not consume a shared platform dependency.

No same-track dependency is declared for this current pointer.

## Acceptance criteria

- development host uses platforminit-dev-01
- n8n host uses platforminit-n8n-01 when n8n track is selected
- project input controls environment and token routing
- volume_layout supports none for n8n and platform-specific layouts for platform

## Forbidden actions

- Do not resurrect deprecated CH05 directions as active work.
- Do not expose secret values.
- Do not use Windows shell, PowerShell, CMD, Git Bash, or MobaXterm for Roo execution.
- do not target production/customer scope
- do not expose secret values

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

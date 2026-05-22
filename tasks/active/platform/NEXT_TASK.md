# NEXT TASK — platform

## Task

- Track: `platform`
- Task ID: `P-CH02-T01`
- Chapter: `CH02`
- Title: Validate shared host baseline contract
- Branch: `batch/platform-ch02-host-baseline-contract`
- Scope: `shared-foundation`

## Goal

Validate CH02 baseline behavior for Kubernetes platform hosts and standalone n8n hosts.

## Shared foundation model

This task does not consume a shared platform dependency.

No same-track dependency is declared for this current pointer.

## Acceptance criteria

- baseline works for Kubernetes platform hosts
- baseline works for standalone n8n hosts without requiring k3s
- volume_layout none does not fail mount-dependent checks
- A1 access/sudo grant contract remains non-interactive

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

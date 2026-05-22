# NEXT TASK — n8n

## Task

- Track: `n8n`
- Task ID: `N8N-CH01-T01`
- Chapter: `N8N-CH01`
- Title: Validate n8n consumption of shared CH01 host lifecycle
- Branch: `batch/n8n-ch01-shared-host-lifecycle`
- Scope: `shared-foundation`

## Goal

Validate n8n as a separate standalone host track using the n8n Hetzner project, low-cost host assumptions, no attached volume by default, and /srv/n8n root-disk persistence.

## Shared foundation model

This task consumes shared PlatformInit foundation task(s): P-CH01-T01, P-CH01-T02

No same-track dependency is declared for this current pointer.

## Acceptance criteria

- n8n host lifecycle uses shared CH01 workflow/contracts
- project=n8n resolves n8n environment and token
- host naming resolves platforminit-n8n-01 (current example — derived from platform/projects/n8n.yaml server_prefix + default index)
- effective volume layout is none
- no attached Hetzner volume is required for standalone n8n baseline

## Forbidden actions

- Do not resurrect deprecated CH05 directions as active work.
- Do not expose secret values.
- Do not use Windows shell, PowerShell, CMD, Git Bash, or MobaXterm for Roo execution.
- do not create k3s for n8n host
- do not use platform CH03-CH05 as n8n prerequisites
- do not target production/customer scope

## Required startup

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track n8n
```

## Roo entrypoint

```text
Read tasks/active/n8n/NEXT_TASK.md and execute the active task exactly as described.
```

## Native role handoff

PlatformInit roles must use native Roo `switch_mode` handoff.

Manual next-prompt printing is allowed only if native `switch_mode` is unavailable or blocked, and the role must explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

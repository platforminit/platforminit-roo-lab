# Multi-Track Task Orchestration Model

PlatformInit Roo Lab uses separate task tracks with shared foundation dependencies.

## Tracks

- `platform`: PlatformInit CH01-CH15 roadmap.
- `n8n`: standalone n8n roadmap.

## Shared foundation

The n8n roadmap is separate, but it consumes shared PlatformInit foundation capabilities:

- CH01 host lifecycle
- CH02 host baseline

This avoids duplicating host lifecycle and baseline logic for the n8n host.

## Divergence

After CH01/CH02, n8n diverges from the platform track:

- no local k3s prerequisite
- no local Argo CD prerequisite
- no local platform Checkmk runtime prerequisite
- standalone Docker Compose runtime
- Caddy TLS/proxy
- PostgreSQL
- `/srv/n8n` persistence

## NEXT_TASK files

- `tasks/active/platform/NEXT_TASK.md`
- `tasks/active/n8n/NEXT_TASK.md`

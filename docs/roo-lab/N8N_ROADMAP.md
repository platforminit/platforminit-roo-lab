# n8n Standalone Roadmap

The n8n roadmap is separate from the main PlatformInit CH01-CH15 platform roadmap.

## Direction

n8n is a standalone runtime track, not part of the main single-node k3s PlatformInit platform path.

Default assumptions:

- separate Hetzner project: `n8n`;
- low-cost standalone host;
- root-disk-only first;
- no attached Hetzner volume by default;
- runtime path: `/srv/n8n`;
- Docker Compose + Caddy + PostgreSQL + n8n;
- no k3s dependency for MVP;
- Authentik/SSO is optional later, not an MVP blocker.

## Roadmap chapters

| Chapter | Purpose |
|---|---|
| N8N-CH01 | Host lifecycle and root-disk-only contract |
| N8N-CH02 | Standalone runtime baseline |
| N8N-CH03 | Secrets, OAuth, and webhook safety |
| N8N-CH04 | Backup and restore |
| N8N-CH05 | Job-search workflow MVP |
| N8N-CH06 | Job-search productionization |
| N8N-CH07 | Canva/document automation |
| N8N-CH08 | Monitoring and remote operations |
| N8N-CH09 | Optional SSO/Auth integration |
| N8N-CH10 | Workflow template productization |

## Active next task

Read:

```text
tasks/active/n8n/NEXT_TASK.md
```

Start:

```bash
./scripts/orchestrator/start-next-task.sh --track n8n
```

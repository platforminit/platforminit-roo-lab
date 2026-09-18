# n8n Standalone Roadmap

> **PARKED:** n8n is a separate delivery track and is not part of the PlatformInit canonical task queue.

Canonical n8n planning state lives in `n8n/tasks/tracker.json`. PlatformInit `/next-task`,
`tasks/tracker.json`, generated task views, and PlatformInit MCP must never select or mutate n8n work.

## Runtime direction

- separate Hetzner project: `n8n`;
- low-cost standalone host;
- root-disk-only first;
- no attached Hetzner volume by default;
- runtime path: `/srv/n8n`;
- Docker Compose + Caddy + PostgreSQL + n8n;
- no k3s dependency for MVP;
- Authentik/SSO is optional later, not an MVP blocker.

## External prerequisites

n8n may consume stable PlatformInit infrastructure contracts as external references, especially the
shared CH01 host-lifecycle primitives and CH02 hardening primitives. Those references are not mutable
cross-project task dependencies and must not cause PlatformInit controller state to select n8n work.

## Roadmap

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

## Registry contract

Canonical n8n task state is [`n8n/tasks/tracker.json`](../../n8n/tasks/tracker.json). Its schema,
ownership boundary, parking semantics, chapter coverage, and verification recipe are documented in
[`n8n/tasks/README.md`](../../n8n/tasks/README.md).

The registry is not a second PlatformInit queue. It is never read or selected by
`python3 tools/task_controller/taskctl.py`, PlatformInit `/next-task`, generated PlatformInit task
views, or PlatformInit MCP; the PlatformInit controller is authoritative for `tasks/tracker.json` only.

## Resume rule

Resuming n8n requires an explicit human decision and a dedicated n8n lifecycle/controller change.
Do not resume it through PlatformInit `taskctl`, `/next-task`, or PlatformInit MCP.

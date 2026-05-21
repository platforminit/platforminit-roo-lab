# PlatformInit Memory Baseline — Curated Interpretation

## Purpose

This file is a curated interpretation of the uploaded `ChatGPTMemory.json`.

The raw uploaded memory is intentionally not used as an active agent source. It contained historical and superseded items that can confuse agents.

Agent-facing context is split into:

```text
docs/roo-lab/context/ACTIVE_AGENT_CONTEXT.md
docs/roo-lab/context/DEPRECATED_COMPONENTS.md
docs/roo-lab/context/ChatGPTMemory.curated-20260520.json
```

Agents must not blindly treat every raw memory task as active. Older CH05 Zabbix/OpenObserve tasks are superseded by the later Checkmk direction, the CH01-CH15 roadmap, and the current repo snapshot.

## Stable facts to preserve

- Active dev host: `platforminit-dev-01`.
- Do not use `deprecated long-form development host alias`.
- Hetzner project model:
  - `development` is active dev/test.
  - `n8n` is reserved for self-hosted n8n.
  - `platforminit` is later production/customer-facing scope.
  - `default` is legacy.
- Project-scoped secrets:
  - `HCLOUD_TOKEN_DEVELOPMENT`
  - `HCLOUD_TOKEN_N8N`
  - `HCLOUD_TOKEN_PLATFORMINIT`
- `INFRA_API_TOKEN` is legacy fallback only.
- A1 elevation remains non-interactive and audit-friendly.
- CH02 baseline compatibility depends on `/tmp/platforminit-run/ch02-remote.sh`.
- CH04.5 identity foundation moved Authentik core deployment before identity model bootstrap.
- Argo CD SSO via Authentik OIDC exists as a separate SSO binding with break-glass local admin.
- CH05 moved away from raw Grafana telemetry UX toward operator-first monitoring.

## Treat as historical/superseded unless repo confirms otherwise

Older memory entries mention:

- Zabbix + Vector + OpenObserve as a planned CH05 replacement.
- active Zabbix validation tasks.
- Checkmk logout 401 as open.

These are not automatically active tasks. The current repo and latest human direction should decide whether they are still relevant.

## Active strategic direction


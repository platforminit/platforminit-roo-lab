# Deprecated and Superseded Components

## Purpose

This file prevents agent confusion by explicitly separating historical experiments from the current PlatformInit direction.

If a component or task is listed here, agents must not revive it as active work unless the human explicitly asks for an architect decision to re-open it.

## Superseded CH05 directions

The following are historical or superseded as the primary CH05 direction:

- Grafana/VictoriaMetrics/Loki/Alloy as the primary operator UI.
- Raw telemetry-heavy dashboard-first operations model.
- Zabbix + Vector + OpenObserve as the planned CH05 replacement.
- Active Zabbix Agent2 model as the current CH05 release gate.
- OpenObserve SSO as a required core default path.

Current CH05 direction:

- Checkmk Community.
- Authentik SSO via Traefik forwardAuth.
- Checkmk trusted header auth using `X-Remote-User`.
- Host/service model focused on WARN/CRIT operator clarity.

## Historical-but-useful components

These may remain useful as optional future tracks, but are not active defaults:

| Component | Current interpretation |
|---|---|
| Grafana | useful for advanced dashboards later, not primary CH05 UX |
| Loki | possible future log backend, not immediate core requirement |
| Vector | possible future log collector, not active CH05 default |
| OpenObserve | optional searchable logs track, not mandatory core path |
| Zabbix | historical experiment; do not implement new CH05 around it by default |

## Superseded tasks from raw memory

Treat these raw-memory tasks as historical/superseded unless re-opened explicitly:

- `TASK-20260513-OBS-REDESIGN` — Zabbix + Vector + OpenObserve redesign.
- `TASK-20260514-CH05-ZABBIX-ACTIVE-002` — active Zabbix model validation.
- `MEM-20260513-OBS-ARCH` — old Zabbix/Vector/OpenObserve preference.
- `MEM-20260514-CH05-ZABBIX-ACTIVE` — active Zabbix Agent2 direction.
- `MEM-20260516-CH05-CHECKMK-LOGOUT-401` — treat as historical unless reproduced on the current repo/host.

## Deprecated names and scopes

- Do not use `deprecated long-form development host alias`; use `platforminit-dev-01`.
- Do not prefer `INFRA_API_TOKEN`; use project-scoped tokens.
- Do not use the legacy `default` Hetzner project for new active work.
- Do not use Windows CMD, PowerShell, Git Bash, MobaXterm, or `vscode-remote://` launchers for Roo execution.

## Peximed lessons that apply here

- Do not let old task files silently override current architecture.
- Do not assume a frontend/backend stack from stale prompts.
- Do not run task-by-task PR churn.
- Do not start review before coder batch scope is complete.
- Do not let OWASP/security reviewer implement changes during read-only review.
- Do not proceed after stale/unknown validation state.
- Do not edit broad files without a targeted scope.

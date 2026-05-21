---
name: platforminit-n8n-standalone
description: Use when working on n8n host architecture, root-disk-only layout, Docker Compose, Caddy, PostgreSQL, Gmail workflows, or automation scope.
---


# PlatformInit n8n Standalone Skill

## Direction

n8n should not become a mini duplicate of the full PlatformInit cluster.

Preferred first model:

```text
small Hetzner host
root disk only
Docker Compose
Caddy
PostgreSQL
n8n
/srv/n8n
```

## Avoid initially

- k3s on n8n host
- local monitoring stack
- heavy SSO/Vault dependency before runtime is stable
- attached volume unless storage need is proven

## Validation

- container health
- Caddy TLS route
- PostgreSQL persistence
- `/srv/n8n` ownership
- reboot survival
- backup/export basics
- Gmail OAuth constraints documented

## Risk notes

- Browser-authenticated job sites may require Playwright/browser automation.
- Gmail OAuth scopes and offline access can fail due consent/app configuration.
- n8n workflows need human-review buckets for uncertain classification.

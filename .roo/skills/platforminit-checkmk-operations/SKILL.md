---
name: platforminit-checkmk-operations
description: Use when working on CH05 Checkmk, operations monitoring, Authentik forwardAuth, trusted-header SSO, or WARN/CRIT views.
---


# PlatformInit Checkmk Operations Skill

## Direction

CH05 is operator-first. The goal is not to collect everything; it is to answer:

1. What broke?
2. Where?
3. How urgent?
4. What should I check next?

## Preferred CH05 model

- Checkmk Community
- `operations` namespace
- `checkmk.sysadminhomelab.hu`
- Authentik forwardAuth via Traefik
- trusted header auth with `X-Remote-User`
- native admin fallback documented
- host: `platforminit-dev-01`
- agent discovery
- WARN/CRIT-first operations entry point

## Lessons

- Grafana dashboards can be technically correct and still operationally poor.
- Public HTTP 500 with Checkmk often indicates Traefik/forwardAuth/outpost failure, not backend Checkmk failure.
- Backend, auth-shim, Traefik, and Authentik must be isolated separately.
- Validation must check runtime state, not only workflow success.

## Evidence checklist

- Checkmk pod status
- direct backend response
- auth-shim response
- Traefik route/access log
- Authentik outpost log
- trusted header behavior
- discovered services count
- WARN/CRIT view state

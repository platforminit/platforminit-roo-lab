# n8n CX23 standalone host architecture

## Scope

This document defines the first n8n host implementation for PlatformInit.

The target is a small single-purpose host, not a Kubernetes platform:

```text
CX23 / Ubuntu 24.04 / Docker Compose / Caddy / n8n / PostgreSQL
```

## Decisions

| Topic | Decision |
|---|---|
| Hetzner project | `n8n` |
| Host type | CX23 |
| Attached volume | No |
| Runtime | Docker Compose |
| Reverse proxy | Caddy |
| TLS | Caddy ACME over HTTP/HTTPS |
| Database | PostgreSQL container |
| n8n persistence | `/srv/n8n/data` bind mount |
| DB persistence | `/srv/n8n/postgres` bind mount |
| k3s | No |
| Local observability stack | No |
| Initial auth | n8n built-in login |
| Later auth | Optional Authentik/SSO track if licensing and integration model justify it |

## Why no k3s

For one n8n instance on a CX23, k3s adds storage, ingress, lifecycle and memory
overhead without solving the immediate deployment problem. The simpler design is
more suitable for a single-purpose automation host.

## Why no attached volume

The first iteration keeps cost and operational complexity low. Data is stored on
the CX23 root disk under `/srv/n8n`. Backup/restore must be implemented before
this becomes a production dependency.

## Initial workflow sequence

```text
01 - Create or Rebuild Host
01.1 - Host Bootstrap
01.2 - Sync Host Access Tooling
02 - Apply Host Baseline
N8N - Deploy Standalone Runtime
```

Use the existing CH01/CH02 host foundation and the new n8n runtime workflow.


## Host lifecycle volume contract

For the `n8n` project, `01 - Create or Rebuild Host` must resolve `volume_layout=project-default` to `none`. The CX23 n8n host is root-disk-only: no Hetzner Volume should be created, attached, mounted, or expected by bootstrap/baseline workflows.

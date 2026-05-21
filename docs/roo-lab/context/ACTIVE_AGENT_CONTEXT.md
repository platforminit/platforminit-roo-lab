# PlatformInit Active Agent Context

## Purpose

This is the primary agent-facing context file for `platforminit-roo-lab`.

Agents must prefer this file over raw memory dumps, old handovers, deprecated architecture notes, or historical experiment notes.

## Current repository role

`platforminit-roo-lab` is a full-access development rehearsal controller for PlatformInit workflows.

It may modify or break the development environment, especially `platforminit-dev-01`, but it must never target production/customer scope unless the human explicitly changes the mission.

## Current active platform direction

- Single-node, cost-conscious, deterministic rebuild platform.
- Hetzner Cloud + Ubuntu host foundation.
- GitHub Actions for host/provisioning/bootstrap workflows.
- k3s as single-node Kubernetes.
- Argo CD as GitOps owner for long-running cluster workloads.
- Traefik ingress.
- cert-manager + Let's Encrypt.
- Cloudflare DNS-01.
- Authentik for SSO/OIDC/forwardAuth.
- Checkmk Community for CH05 operator-first monitoring.
- CH06 should start as diagnostics/evidence/security baseline design, not broad auto-remediation.

## Current host and environment facts

- Active dev host: `platforminit-dev-01`.
- Forbidden stale name: `deprecated long-form development host alias`.
- Main/default branch convention: `dev`.
- Lab validation branch: `batch/roo-lab-first-validation`.
- WSL root: `/mnt/d/SYSADMIN/platforminit-roo-lab`.
- Stable recovery source: `/mnt/d/SYSADMIN/platforminit-platform`.
- GitHub environments expected by copied workflows: `development`, `n8n`.
- Repo-visible org secrets are allowed by name only; never print values.

## Active project scopes

| Scope | Status | Meaning |
|---|---|---|
| `development` | active | platform dev/test environment |
| `n8n` | active/planned | standalone n8n host/runtime workflow scope |
| `platforminit` | future | customer-facing/production scope after later roadmap phases |
| `default` | legacy | do not prefer for new work |

## Active tasks for agents

1. Validate the Roo agent operating layer before infrastructure execution.
2. Ensure project custom modes and skills are discoverable.
3. Preserve WSL-only operation and branch safety.
4. Keep raw memory and deprecated components out of active execution context.
5. Stabilize CH01 storage/volume-layout behavior, especially root-disk-only `n8n` mode.
6. Preserve CH01-CH05 as a reproducible foundation.
7. Treat CH05 as Checkmk/operator-first, not Grafana/Zabbix-first.
8. Prepare CH06 Security & Compliance v2 as an evidence-first diagnostics baseline.

## Decision boundaries

- Historical memory can explain how we got here, but it must not define the active plan.
- Claude-generated skill material is scaffolding only, not source of truth.
- Peximed lessons are process lessons, not PlatformInit architecture.
- Deprecated components can be mentioned in migration/history docs, but must not become active tasks without architect approval.

## First validation run policy

The first Roo execution after applying this layer must be validation-only:

- no Hetzner changes;
- no Cloudflare changes;
- no Kubernetes changes;
- no Authentik changes;
- no Checkmk changes;
- no CH01-CH05 workflow runs.

It should only validate repository structure, mode loading, skill discovery, branch state, WSL state, GitHub environments, and secret-name visibility.

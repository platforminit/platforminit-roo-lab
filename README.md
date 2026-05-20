# PlatformInit Platform

Turn a fresh VPS into a production-ready single-node platform with deterministic automation.

This repository is the PlatformInit monorepo for the DevOps Homelab / PlatformInit roadmap. It provisions a Hetzner Cloud host, bootstraps a hardened Ubuntu baseline, installs k3s, enables ingress/TLS/GitOps services, deploys identity, and adds a lightweight operations layer.

## Current platform model

| Layer | Purpose |
|---|---|
| CH01 / 01.x | host lifecycle, bootstrap and host access tooling |
| CH02 / 02.x | host baseline, drift checks, OS security and file integrity |
| CH03 | single-node k3s cluster installation |
| CH04 | platform services: ingress, TLS and Argo CD |
| CH04.5 | identity foundation: Authentik, identity namespace, groups, technical users and validation |
| CH04.6 | Argo CD SSO integration with Authentik |
| CH05 | operations monitoring: Checkmk Community with Authentik trusted-header SSO |
| CH06 | reserved for future Security & Compliance v2 roadmap; not active in current lifecycle |

## User-facing workflow order

| Order | Workflow | Artifact required |
|---:|---|---|
| 0 | `00 - Build Platform Artifacts` | none |
| 1 | `01 - Create or Rebuild Host` | none |
| 2 | `01.1 - Host Bootstrap` | none |
| 3 | `01.2 - Sync Host Access Tooling` | none |
| 4 | `02 - Apply Host Baseline` | `host-baseline-release-*` |
| 5 | `02.1 - Drift Check` | host-baseline artifact where requested |
| 6 | `02.3 - OS Security Check` | host-baseline artifact where requested |
| 7 | `02.4 - OS Security Apply` | host-baseline artifact where requested |
| 8 | `02.5 - File Integrity Check` | host-baseline artifact where requested |
| 9 | `02.5.1 - Initialize AIDE Database` | host-baseline artifact where requested |
| 10 | `02.5.2 - Run AIDE Check` | host-baseline artifact where requested |
| 11 | `03 - Install Kubernetes Cluster` | `cluster-release-*` |
| 12 | `04 - Enable Platform (Ingress, TLS, ArgoCD)` | `platform-services-release-*` |
| 13 | `04.5 - Deploy Identity Foundation` | `identity-release-*` |
| 14 | `04.6 - Enable Argo CD SSO` | `identity-release-*` |
| 15 | `05 - Operations Monitoring` | `observability-release-*` |
| 16 | `05.D - Operations Diagnostics` | `observability-release-*` |

Each CH05 workflow accepts the producing build workflow run ID and the specific artifact ID from `00 - Build Platform Artifacts`.

Only two CH05 workflow files remain in `.github/workflows/`: `05 - Operations Monitoring` and `05.D - Operations Diagnostics`. The former numbered CH05 implementation workflows were removed from the Actions sidebar; their behavior is now executed by the consolidated workflows through the existing CH05 scripts and validators.

## Active environment contract

| Item | Current value |
|---|---|
| Provider | Hetzner Cloud |
| Active project | `development` |
| Development host | `platforminit-dev-01` |
| Base domain | `sysadminhomelab.hu` |
| Kubernetes | single-node k3s |
| Public operational UI | Checkmk Community |
| Public identity UI | Authentik |

Deprecated development host aliases must not be used; the only valid development host contract is `platforminit-dev-01`.

## CH05 operations monitoring

CH05 is now a minimal Checkmk Community based operations layer. The previous Grafana/VictoriaMetrics/Loki/Alloy proof and the later Zabbix/OpenObserve/Vector proof are retired from the active lifecycle.

```text
Checkmk Community -> host/service/state operator console
Authentik         -> SSO gate through Traefik forwardAuth
Nginx auth-shim   -> X-authentik-* to X-Remote-User header bridge
Argo CD           -> owns runtime deployment
```

CH05.5, CH05.7, CH05.6 and CH05.4 have a stable Checkmk checkpoint tagged as `ch05-checkmk-stable-2026-05-16`. The `graph_recipe` UI error was diagnosed with `05.8D - Diagnose Checkmk Graph Rendering` and fixed by preserving `Content-Type` in the Checkmk auth-shim. CH05.8D now also collects dashboard AJAX and session/CSRF diagnostics for the empty built-in dashboard selector and invalid-CSRF save symptoms. CH05.8 configures a Checkmk-native PlatformInit Alert Manager landing page backed by the built-in Host & service problems dashboard and applies a noise policy for transient k3s/containerd overlay filesystem services. CH05.8B reconciles remaining alert noise by clearing stale failed systemd states for known bootstrap/FIM units, refreshing the Checkmk agent cache, running full discovery reconcile, and validating that Check_MK Discovery and known stale systemd failures are no longer active Alert Manager problems.

### CH05 workflow UX

Operator-facing CH05 workflow surface is intentionally small:

| Workflow | Purpose |
|---|---|
| `05 - Operations Monitoring` | runs one selected CH05 operation or the full reconcile chain |
| `05.D - Operations Diagnostics` | collects agent, graph, dashboard, session and CSRF diagnostics |

`05 - Operations Monitoring` supports these actions:

```text
full_reconcile
register_stack
reconcile_prereqs
sync_stack
enable_sso
provision_model
install_agent_discovery
configure_entrypoint
configure_dashboards
clean_alert_noise
validate
```

`full_reconcile` runs the stable end-to-end CH05 sequence:

```text
05 Register Operations Stack
05.1 Reconcile Operations Prerequisites
05.2 Sync Operations Stack
05.3 Enable Checkmk Trusted-Header SSO
05.5 Provision Checkmk Operations Model
05.7 Install Checkmk Agent and Discover Services
05.6 Configure Checkmk Operations Entry Point
05.8 Configure Checkmk Operations Dashboards
05.8B Clean Checkmk Alert Noise
05.4 Validate Operations Stack
```

Public operations WebUI:

| URL | Purpose | Login |
|---|---|---|
| `https://checkmk.<PLATFORM_BASE_DOMAIN>/cmk/` | operational host/service/state console | Authentik forwardAuth + Checkmk trusted header |

After CH04, CH05 runtime resources are Argo CD-owned. GitHub Actions only register the Argo CD Application, reconcile prerequisite secrets/identity bindings, request sync/refresh, and validate. The public ingress is part of the GitOps-owned operations stack and uses production certificates for browser-trusted WebUIs.

Removed as default components:

- Grafana
- VictoriaMetrics
- VMAgent
- VMAlert
- Alertmanager
- Loki
- Alloy
- Zabbix
- OpenObserve
- Vector
- provisioned Grafana/Zabbix dashboards


## CH05 GitOps ownership rule

After CH04 has installed Argo CD, CH05 must not deploy long-running application resources through SSH scripts. The ownership boundary is:

```text
GitHub Actions -> short bootstrap / secrets / Authentik API / Argo CD sync request / validation
Argo CD        -> Deployments, DaemonSets, Services, Ingresses, PVCs, ConfigMaps
```

This prevents long workflow timeouts, sudo grant expiry, SSH session fragility and untracked runtime drift.

## Storage contract

k3s must use:

```text
/srv/data/k3s
```

The old fallback to `/srv/k3s` or `/var/lib/rancher/k3s` is treated as legacy/stale state. Use the CH03 validation output and host storage audit commands when troubleshooting disk growth.

## Identity and SSO

Identity is deployed early in the lifecycle.

| Workflow | Binding | Notes |
|---|---|---|
| `04.5 - Deploy Identity Foundation` | Authentik core | required before app SSO |
| `04.6 - Enable Argo CD SSO` | Argo CD → Authentik | GitOps UI login |
| `05 - Operations Monitoring` action `enable_sso` | Checkmk trusted-header SSO via Authentik forwardAuth | identity binding only; no app rollout |


CH05 workflow privilege contract:

```text
A1 mode: observability
Allowed privileged entrypoint: /tmp/platforminit-run/ch05-remote.sh *
```

CH05 workflows must not use generic `sudo -l` validation or ad-hoc runner names. The A1 grant is command-scoped and non-interactive.

## Privilege model

- `01 - Create or Rebuild Host` provisions the machine and injects the automation key for initial root access.
- `01.1 - Host Bootstrap` creates `devops` and `itadmin`, disables root login and password auth, and installs the scoped privilege helper.
- `01.2 - Sync Host Access Tooling` updates the host-side grant tooling without rebuilding the host.
- `A1 - Access Elevation` is the approval-gated elevation path for time-bound workflow sudo.
- `devops` should not have standing sudo.

## Branch model

| Branch | Purpose |
|---|---|
| `main` | release-ready baseline |
| `staging` | pre-release validation |
| `dev` | active integration branch |
| `feat/*` / `fix/*` | isolated delivery branches |

Recommended branch for this refactor:

```bash
git checkout dev
git checkout -b feat/ch05-checkmk-community-operations-layer
```

## Documentation index

| Area | Document |
|---|---|
| Secrets | `docs/secrets-reference.md` |
| Multi-project routing | `docs/multi-project-routing.md` |
| Host discovery and volume layout | `docs/multi-project-host-discovery-and-volume-layout.md` |
| Day-2 operations | `docs/day2-ops.md` |
| Release model | `docs/release-model.md` |
| CH05 operations monitoring design | `docs/ch05-operations-monitoring-design.md` |
| CH05 Checkmk migration runbook | `docs/ch05-checkmk-migration-runbook.md` |
| CH05 Checkmk operations dashboards | `docs/ch05-checkmk-operations-dashboards.md` |
| CH05 Argo CD refactor runbook | `docs/ch05-argocd-operations-refactor-runbook.md` |
| Checkmk monitoring | `platform/observability/checkmk/README.md` |
| External host monitoring backlog | `platform/observability/external-hosts/README.md` |
| Platform rationalization and open issues | `docs/platforminit-rationalization-open-issues.md` |

## Principles

- deterministic infrastructure
- immutable rebuild preference
- GitOps-first platform ownership
- no hardcoded secrets
- no standing sudo for runtime automation users
- public UIs only where they provide operator value
- Authentik login required for public WebUIs
- low-resource single-node defaults
- clear operator alerts over raw telemetry dashboards


See `docs/ssh-maxstartups-and-workflow-retry.md` for the SSH MaxStartups and workflow retry contract.

### CH05 storage contract

CH05 observability data is intentionally kept separate from the generic k3s local-path storage tree:

```text
/srv/data/k3s              -> k3s runtime and container runtime data
/srv/data/k3s/storage      -> generic local-path PVC storage
/srv/observability/data    -> CH05 observability persistent data
```

Checkmk uses a static Retain hostPath PV under `/srv/observability/data/checkmk`. See `docs/ch05-observability-storage-contract.md`.

## n8n standalone host

The repository includes a lightweight standalone n8n host track for the `n8n`
Hetzner project. It targets a CX23 Ubuntu 24.04 VPS with Docker Compose, Caddy,
n8n and PostgreSQL. It intentionally avoids k3s, attached Hetzner Volumes and a
local observability stack for the first iteration.

Main workflow:

```text
N8N - Deploy Standalone Runtime
```

Design note: `docs/n8n-cx23-standalone-architecture.md`.

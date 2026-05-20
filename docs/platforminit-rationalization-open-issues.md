# PlatformInit rationalization and open issues

This document tracks the next simplification pass after the CH05 Checkmk operations layer was stabilized and the CH05 GitHub Actions UX was reduced to two operator-facing entrypoints.

The goal is not to add new features first. The goal is to reduce operator friction, remove duplicated workflows, document remaining known issues, and keep the platform path understandable as the roadmap expands toward CH06 and the standalone n8n host track.

## Current known-good checkpoint

| Area | Status |
|---|---|
| CH05 Checkmk operations layer | Stable |
| Checkmk trusted-header SSO | Working |
| Checkmk logout through Authentik | Working |
| Checkmk session / CSRF behavior | Working after preserving selected WebUI headers |
| Checkmk graph rendering | Working after preserving `Content-Type` |
| Native Checkmk agent discovery | Working |
| Alert Manager view | Working through Checkmk Host & service problems dashboard |
| Alert noise cleanup | Working |
| CH05 workflow UX | Consolidated to `05 - Operations Monitoring` and `05.D - Operations Diagnostics` |

Known checkpoint tags:

```text
ch05-checkmk-stable-2026-05-16
ch05-checkmk-alertmanager-stable-2026-05-17
```

## Operator-facing workflow surface target

The long-term workflow surface should distinguish between operator entrypoints and implementation internals.

| Layer | Current state | Target state |
|---|---|---|
| Build | `00 - Build Platform Artifacts` | Keep as explicit build/release artifact producer |
| Host lifecycle | `01`, `01.1`, `01.2` | Consolidate later into one `01 - Host Lifecycle` workflow with action input |
| Host baseline / security | many `02.x` workflows | Consolidate later into one `02 - Host Baseline` and one `02.D - Host Diagnostics` workflow |
| Kubernetes / platform | `03`, `04`, `04.5`, `04.6` | Consider one `04 - Platform Enablement` workflow after CH05 pattern is proven |
| Operations | `05`, `05.D` | Current target state achieved |
| n8n standalone host | `N8N - Deploy Standalone Runtime` plus existing host workflows | Keep lightweight; do not introduce k3s or local observability on n8n host |
| Day-2 patching | `A2 - Security Patching` | Keep as system-level Day-2 workflow; later fold into CH06 reporting |
| Access elevation | `A1 - Access Elevation` | Keep explicit and approval-gated; avoid hiding privilege grants completely |

## Open issues and rationalization backlog

### P0 — Host lifecycle must support `volume_layout=none` cleanly

Observed issue: the n8n host is intended to be a CX23 standalone container host with no attached Hetzner Volume, but the host lifecycle path still attempted a volume attach when the workflow was run with defaults.

Likely root cause: project defaults in `platform/projects/n8n.yaml` declare `volumes.layout: none`, but `01 - Create or Rebuild Host` still relies on the manually selected workflow input default, which is currently `single`. The project registry is not yet authoritative for host lifecycle defaults.

Required direction:

```text
01 - Create or Rebuild Host
  project=n8n
  default server_type=cx23
  default volume_layout=none
  skip all volume create/attach/wait/mount context expectations
```

Acceptance criteria:

- creating `platforminit-n8n-01` with project `n8n` does not create or attach any Hetzner Volume unless explicitly requested;
- `volume_summary` is empty for `volume_layout=none`;
- downstream host context still writes sane paths for container bind mounts under `/srv/n8n`;
- existing development/platforminit split-volume behavior remains unchanged.

### P0 — n8n host track should remain deliberately small

Current decision:

| Decision | Value |
|---|---|
| Server type | Hetzner CX23 |
| Volume | no attached Hetzner Volume |
| Runtime | Docker Compose |
| Reverse proxy | Caddy |
| Database | PostgreSQL container |
| Persistence | host-local bind mounts under `/srv/n8n` |
| k3s | no |
| local observability stack | no |
| monitoring | later as central Checkmk target |

Open implementation gaps:

- fix host lifecycle `volume_layout=none` handling;
- confirm `platforminit-n8n-01` labels resolve correctly through `resolve-target-host`;
- validate first runtime deploy after host bootstrap/baseline;
- add a minimal backup/restore workflow before putting valuable workflows/data on the host;
- later register n8n host in central Checkmk rather than deploying a local monitoring stack.

### P1 — CH01/CH02 GitHub Actions UX is too granular

CH05 was rationalized successfully. CH01/CH02 still expose many operator workflows:

```text
01 - Create or Rebuild Host
01.1 - Host Bootstrap
01.2 - Sync Host Access Tooling
02 - Apply Host Baseline
02.1 - Drift Check
02.3 - OS Security Check
02.4 - OS Security Apply
02.5 - File Integrity Check
02.5.1 - Initialize AIDE Database
02.5.2 - Run AIDE Check
```

Target direction:

```text
01 - Host Lifecycle
  action=create|rebuild|bootstrap|sync_access|full_reconcile

02 - Host Baseline
  action=apply|drift_check|security_check|security_apply|fim_check|full_reconcile

02.D - Host Diagnostics
  mode=baseline|security|fim|all
```

Do not remove the underlying scripts yet. First add consolidated wrappers, prove them, then remove granular workflow files from `.github/workflows` so they no longer clutter the Actions sidebar.

### P1 — A2 Security Patching belongs to Day-2 system-level operations

A2 should not be mixed with CH06 too early. It is best treated as a host-level Day-2 operation:

```text
A2 = package updates, security updates, reboot-required detection, patch report
CH06 = broader Security & Compliance v2 evidence, policy and audit layer
```

Future CH06 should consume A2 outputs rather than replace A2.

### P1 — CH06 naming conflict must be cleaned up before implementation

Historical work used CH06-like naming for identity compatibility / Argo CD SSO flows. Current roadmap reserves CH06 for Security & Compliance v2.

Required direction:

```text
06 - Security & Compliance
06.D - Security Diagnostics
```

Initial CH06 should be diagnostic-first and evidence-focused, not remediation-heavy.

Suggested first CH06 scope:

- host patch/reboot posture;
- SSH/sudo hardening evidence;
- UFW evidence;
- k3s security baseline checks;
- ingress/TLS/auth policy validation;
- AIDE/FIM health and stale failure cleanup;
- Kubernetes secret inventory summary;
- downloadable PASS/WARN/FAIL evidence bundle.

### P1 — Artifact ID ergonomics remain high-friction

Many workflows still require manual `artifact_run_id` and `artifact_id` inputs from `00 - Build Platform Artifacts`.

This is explicit and safe, but not operator-friendly.

Potential improvement:

```text
artifact_source=manual|latest_successful_for_branch
artifact_run_id=<required only for manual>
artifact_id=<required only for manual>
```

Start with diagnostics or low-risk validate actions before applying this to mutating workflows.

### P2 — Documentation needs active vs historical separation

The docs directory now contains active runbooks, retired CH05 design notes, and investigation material. This is useful history but increasingly noisy.

Recommended structure:

```text
docs/current/
  active operator runbooks and architecture contracts

docs/history/
  retired Grafana/Zabbix/OpenObserve/Vector experiments

docs/diagnostics/
  one-off diagnostic methodology and artifact interpretation
```

Do not move files immediately without a separate docs cleanup pass. First record the target structure, then move files in one scoped PR.

### P2 — Checkmk `Checkmk dashboard` remains low-value

The built-in Main and Host & service problems dashboards are useful. The built-in Checkmk dashboard currently appears empty or low-value for this deployment.

Decision:

- do not treat the empty Checkmk self-monitoring dashboard as a blocker;
- keep PlatformInit operator landing on Host & service problems / Alert Manager;
- revisit only if Checkmk site self-monitoring becomes a real requirement.

## Recommended next work order

1. Fix `01 - Create or Rebuild Host` so project `n8n` truly uses `volume_layout=none` without volume lifecycle side effects.
2. Complete the first clean n8n host bootstrap and runtime deploy on `platforminit-n8n-01`.
3. Add n8n backup/restore before real production use.
4. Consolidate CH01/CH02 workflow UX using the proven CH05 pattern.
5. Start CH06 with a diagnostic-only Security & Compliance scope document and evidence workflow.

## Current non-goals

- Do not add k3s to the n8n host in the first iteration.
- Do not deploy a separate monitoring stack to the n8n host.
- Do not re-open the retired Grafana/VictoriaMetrics/Loki or Zabbix/OpenObserve designs unless there is a new, explicit requirement.
- Do not replace Checkmk trusted-header SSO with native Checkmk SAML while using the Community image.

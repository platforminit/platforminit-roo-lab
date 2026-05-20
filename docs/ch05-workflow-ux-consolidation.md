# CH05 workflow UX consolidation

CH05 reached a stable Checkmk checkpoint with working trusted-header SSO, native Linux agent discovery, dashboard rendering, Alert Manager view and alert-noise cleanup.

During stabilization, the implementation was split into many numbered workflows. That was useful for debugging, but it made the GitHub Actions UI too noisy for day-to-day operation.

## Operator-facing workflows

Use these workflows from the GitHub Actions UI:

| Workflow | Purpose |
|---|---|
| `05 - Operations Monitoring` | run one selected CH05 operation or the full reconcile chain |
| `05.D - Operations Diagnostics` | collect diagnostic bundles without changing runtime state, except when explicitly enabling a discovery probe |

## `05 - Operations Monitoring` actions

| Action | Internal step |
|---|---|
| `full_reconcile` | runs the full stable CH05 sequence |
| `register_stack` | registers/updates the Argo CD operations application |
| `reconcile_prereqs` | reconciles prerequisites/secrets required by the operations layer |
| `sync_stack` | syncs the Argo CD-owned operations stack |
| `enable_sso` | reconciles Checkmk trusted-header SSO with Authentik |
| `provision_model` | provisions the PlatformInit Checkmk host/service model |
| `install_agent_discovery` | installs/validates the Checkmk Linux agent and native discovery |
| `configure_entrypoint` | configures the Checkmk entrypoint/start experience |
| `configure_dashboards` | configures the Checkmk Alert Manager dashboard landing |
| `clean_alert_noise` | reconciles remaining Checkmk alert noise |
| `validate` | runs the final operations stack validation |

## `full_reconcile` order

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

## Diagnostics modes

| Mode | Diagnostic bundle |
|---|---|
| `agent_discovery` | Checkmk Linux agent, TCP datasource and native discovery diagnostics |
| `graph_dashboard_session` | Checkmk graph rendering, dashboard AJAX, session and CSRF diagnostics |
| `all` | runs both diagnostic bundles |

## Implementation workflow status

The granular numbered CH05 workflow files were removed from `.github/workflows/` so they no longer appear in the GitHub Actions sidebar. The consolidated workflows run the same validated CH05 scripts and validators directly from the released observability artifact.

This reduces the daily operator choice to two workflows while keeping targeted actions available through the `action` and `diagnostic_mode` inputs.

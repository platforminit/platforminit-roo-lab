# Identity Layer Refactor

Identity is an early platform lifecycle layer.

## Current model

| Workflow | Purpose |
|---|---|
| `04.5 - Deploy Identity Foundation` | Deploy Authentik and bootstrap PlatformInit identity groups |
| `04.6 - Enable Argo CD SSO` | Configure Argo CD OIDC login through Authentik |
| `05.3 - Enable Checkmk Trusted-Header SSO` | Configure native app SSO for CH05 Zabbix/OpenObserve through Authentik; no proxy-only forward-auth |

## Deprecated model

The old Grafana SSO path was removed from the active lifecycle when CH05 moved to Zabbix + Vector + OpenObserve.

Do not add new Grafana SSO workflows to the default PlatformInit lifecycle.

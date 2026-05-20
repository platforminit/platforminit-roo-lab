# CH05 - Operations Monitoring

PlatformInit CH05 now uses a minimal Checkmk Community based monitoring layer.

## Architecture

```text
Checkmk Community  -> host/service/state operator console
Authentik          -> SSO gate via Traefik forwardAuth
Nginx auth-shim    -> maps approved Authentik sessions to X-Remote-User
Argo CD            -> owns runtime deployment
```

The retired Zabbix / Vector / OpenObserve implementation has been purged from the active CH05 lifecycle.

## Public endpoint

| URL | Purpose | Auth |
|---|---|---|
| `https://checkmk.<PLATFORM_BASE_DOMAIN>/cmk/` | PlatformInit operations console | Authentik forwardAuth + Checkmk trusted header |

## Workflow lifecycle

```text
00 - Build Platform Artifacts
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.2 - Sync Operations Stack
05.3 - Enable Checkmk Trusted-Header SSO
05.4 - Validate Operations Stack
05.5 - Provision Checkmk Operations Model
05.7D - Diagnose Checkmk Agent Discovery
05.7 - Install Checkmk Agent and Discover Services
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
05.8D - Diagnose Checkmk Graph Rendering
05.8 - Configure Checkmk Operations Dashboards
05.8B - Clean Checkmk Alert Noise
```

## Operator-facing workflow UX

CH05 now exposes two operator-facing workflows:

| Workflow | Purpose |
|---|---|
| `05 - Operations Monitoring` | one selected operation or the full stable reconcile chain |
| `05.D - Operations Diagnostics` | diagnostic-only bundles for agent discovery, graph rendering, dashboard AJAX and session/CSRF issues |

The granular CH05 implementation workflows are reusable internal steps. Keep them available for the consolidated workflows, but do not use them as the normal operator UX.

## Storage contract

```text
/srv/observability/data/checkmk -> Checkmk site data (/omd/sites)
```

The generic k3s runtime paths remain unchanged:

```text
/srv/data/k3s
/srv/data/k3s/storage
/srv/platforminit
```

## SSO contract

Checkmk Community/Raw is protected through Authentik forwardAuth. Authentik returns `X-authentik-*` headers. The in-pod auth shim maps approved sessions to the deterministic Checkmk local user for the first Community/Raw SSO proof:

```text
X-Remote-User: cmkadmin
X-Remote-Original-User: <authentik username>
X-Remote-Name: <authentik display name>
X-Remote-Email: <authentik email>
X-Remote-Groups: <authentik groups>
```

Checkmk must have **Authenticate users by incoming HTTP requests** enabled for full trusted-header login. The first implementation keeps local `cmkadmin` as break-glass.


## Operator UX contract

CH05.5 creates the visible host/service model. CH05.6 configures the operator start experience so the Checkmk UI opens on the PlatformInit all-hosts state view instead of the default onboarding page or an empty dashboard selector.

Current CH05.6 entrypoint:

```text
view.py?view_name=allhosts
```

CH05.7 native Checkmk agent discovery is part of the stable checkpoint after the TCP agent tag fix and first-run PEND validation adjustment. Checkmk graph rendering is fixed by preserving `Content-Type` through the nginx auth-shim. CH05.8 then configures the operator dashboard landing experience on Checkmk-native dashboards and drill-down views.

- Checkmk logout is routed through the public Authentik `/if/flow/default-invalidation-flow/` logout flow so users do not remain silently logged in after leaving Checkmk.

### CH05.7 root-cause note

The 05.7D artifact showed that raw TCP access to the host agent worked, but `cmk -D platforminit-dev-01` still reported `Agent mode: No agent` and `cmk -d` returned empty output. The fix is to keep CH05.5 on the stable synthetic service model while writing the host with explicit raw Checkmk agent tags: `cmk-agent|tcp|prod|lan`. The `tcp` tag is required so Checkmk treats the host as a normal TCP agent target instead of a piggyback/PING-only object.


### 2026-05-16 diagnostic finding

The CH05.7D artifact confirmed that the host is now a real TCP Checkmk agent target: `cmk -D` shows a TCP agent on `62.238.5.243:6556`, `cmk -d platforminit-dev-01` returns Linux agent sections, and `cmk --debug -vvn` fetches/parses data via the TCP datasource. Do not add pre-discovery assertions that expect native Linux service status lines before `cmk -I` has created autochecks.


### CH05 graph_recipe fix

The CH05.8D artifact showed Checkmk WebUI graph rendering requests failing in `ajax_render_graph_content.py` with `KeyError: graph_recipe`. The fix keeps `proxy_pass_request_headers off` for security, but explicitly preserves `Content-Type` so Checkmk can parse JSON/AJAX POST bodies.

## CH05.8 operations dashboards

`05.8 - Configure Checkmk Operations Dashboards
05.8B - Clean Checkmk Alert Noise` promotes the built-in Checkmk `Host & service problems` dashboard as the PlatformInit Alert Manager landing page. This keeps the UI Checkmk-native while giving operators a focused page containing current actionable problem states instead of historical events or OK rows.

Primary start URL:

```text
dashboard.py?name=simple_problems&owner=
```

Secondary validated dashboard/drill-down routes:

```text
dashboard.py?name=main&owner=
dashboard.py?name=checkmk&owner=
view.py?view_name=hoststatus&host=platforminit-dev-01
view.py?view_name=host_graphs&host=platforminit-dev-01&site=cmk
view.py?view_name=allhosts
view.py?view_name=allservices
view.py?view_name=svcproblems
```

The workflow also applies a conservative operations noise policy: transient k3s/containerd overlay rootfs filesystem services matching `^Filesystem /run/k3s/containerd/.*/rootfs$` are ignored and discovery is reconciled, because those mounts disappear whenever pods restart and should not dominate the alert view.

### CH05.8D dashboard/session diagnostics

`05.8D - Diagnose Checkmk Graph Rendering` also collects dashboard and session diagnostics. This is used when built-in dashboards return HTTP 200 but render an empty selector/spinner, or when Checkmk form saves fail with `Invalid CSRF token` behind the trusted-header auth-shim.

The diagnostic compares direct Checkmk backend access with the auth-shim path, captures dashboard route output, candidate AJAX references, cookie jars, CSRF/session markers, and Checkmk logs. It is read-only and does not submit save actions.


### Session / CSRF note

Checkmk trusted-header SSO still requires normal Checkmk WebUI session cookies for dashboard AJAX and CSRF-protected WATO form submissions. The auth-shim keeps `proxy_pass_request_headers off`, but explicitly preserves `Cookie`, `Accept`, `X-Requested-With`, `Referer`, `Origin`, and `Content-Type` while continuing to strip `Authorization` and unlisted request headers. CH05.3 owns the `auth_by_http_header = 'X-Remote-User'` setting in `global.mk`.


## CH05.8B alert noise cleanup

`05.8B - Clean Checkmk Alert Noise` is the follow-up after the Alert Manager dashboard is visible. It does not create a new dashboard; it cleans the remaining noisy problem sources so the built-in `Host & service problems` dashboard remains useful.

The workflow:

- resets stale failed systemd states for known bootstrap/FIM units such as `cloud-init-hotplugd.service` and `dailyaidecheck.service`;
- refreshes the Checkmk agent cache from the deterministic host IPv4/TCP 6556 path;
- runs a full Checkmk discovery reconcile with the transient k3s/containerd filesystem ignore policy still active;
- fails if `Check_MK Discovery` remains WARN/CRIT/UNKNOWN after reconcile;
- fails if the known stale systemd units still appear as active Checkmk problems after reset;
- updates `/omd/sites/cmk/local/share/platforminit/checkmk-alert-manager-current.txt`.

If a reset unit immediately fails again, CH05.8B intentionally fails rather than hiding the problem. That case should be fixed in the relevant host baseline layer, for example CH02/FIM for `dailyaidecheck`.

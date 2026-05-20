# CH05 Checkmk Community Migration Runbook

## Purpose

This runbook replaces the retired CH05 Zabbix/OpenObserve/Vector proof with a simpler operator-first monitoring layer:

```text
Checkmk Community -> host/service/state operations console
Authentik         -> SSO via Traefik forwardAuth
Nginx auth-shim   -> X-authentik-* to X-Remote-User header bridge
```

The goal is to restore the straightforward CheckMK/Nagios-like workflow:

```text
HOST -> SERVICE -> STATE -> DETAIL
```

## WSL + VS Code branch flow

Run from WSL inside the repository checkout:

```bash
git checkout dev
git pull --ff-only

git checkout -b feat/ch05-checkmk-community-operations-layer
code .
```

## Purge the old CH05 runtime layer

These commands remove the old CH05 runtime objects and keep the rest of the platform intact.

> Safety rule: move old persistent data aside first. Only delete it after the Checkmk layer is validated.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export RETIRED_DIR="/srv/observability/data/_retired-$(date -u +%Y%m%dT%H%M%SZ)"

kubectl -n argocd delete application operations-stack --ignore-not-found=true
kubectl -n argocd delete appproject operations --ignore-not-found=true

kubectl -n operations delete ingressroute --all --ignore-not-found=true
kubectl -n operations delete middleware --all --ignore-not-found=true
kubectl -n operations delete certificate --all --ignore-not-found=true
kubectl -n operations delete deployment --all --ignore-not-found=true
kubectl -n operations delete daemonset --all --ignore-not-found=true
kubectl -n operations delete statefulset --all --ignore-not-found=true
kubectl -n operations delete service --all --ignore-not-found=true
kubectl -n operations delete configmap --all --ignore-not-found=true
kubectl -n operations delete secret --all --ignore-not-found=true
kubectl -n operations delete pvc --all --ignore-not-found=true

kubectl delete pv \
  platforminit-zabbix-postgres-data \
  platforminit-openobserve-data \
  platforminit-vector-data \
  platforminit-checkmk-sites \
  --ignore-not-found=true

sudo mkdir -p "$RETIRED_DIR"
for old_path in \
  /srv/observability/data/zabbix-postgres \
  /srv/observability/data/openobserve \
  /srv/observability/data/vector \
  /srv/observability/data/checkmk
  do
    if [ -e "$old_path" ]; then
      sudo mv "$old_path" "$RETIRED_DIR/"
    fi
  done

sudo mkdir -p /srv/observability/data/checkmk
sudo chmod 0750 /srv/observability/data/checkmk
```

Optional destructive cleanup after the new layer is validated:

```bash
sudo rm -rf "$RETIRED_DIR"
```

## Deploy the new Checkmk-based CH05 layer

CH05.7 native agent discovery is currently paused. Use the `05.7D - Diagnose Checkmk Agent Discovery` workflow before attempting another install/discovery implementation. The stable baseline is 05.5 + 05.6.

Run the GitHub Actions workflows in this order:

```text
00 - Build Platform Artifacts
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.2 - Sync Operations Stack
05.3 - Enable Checkmk Trusted-Header SSO
05.4 - Validate Operations Stack
05.5 - Provision Checkmk Operations Model
05.7D - Diagnose Checkmk Agent Discovery
05.6 - Configure Checkmk Operations Entry Point
```

Use `05.4` with:

```text
validation_mode=runtime
```

Then repeat with:

```text
validation_mode=runtime_with_sso
```

## Manual Checkmk SSO activation checkpoint

Checkmk Community/Raw supports the trusted-header pattern, but Checkmk itself must trust incoming HTTP authentication.

After first deploy, log in once with the local `cmkadmin` break-glass account and enable:

```text
Setup -> General -> Global Settings -> User Interface
Authenticate users by incoming HTTP requests
Activate HTTP header authentication
```

Expected trusted header:

```text
X-Remote-User
```

The PlatformInit auth-shim maps Authentik headers as follows:

```text
X-authentik-username -> X-Remote-User
X-authentik-name     -> X-Remote-Name
X-authentik-email    -> X-Remote-Email
X-authentik-groups   -> X-Remote-Groups
```

## WSL + VS Code enterprise commit flow

```bash
git status --short
git diff --stat
git diff -- .github/workflows platform/observability docs README.md

git add \
  .github/workflows/deploy-05-operations-monitoring.yml \
  .github/workflows/deploy-05-operations-diagnostics.yml \
  README.md \
  docs/ch05-workflow-ux-consolidation.md \
  docs/ch05-checkmk-migration-runbook.md
```

## Acceptance criteria

```text
https://checkmk.<base-domain>/cmk/ opens through Traefik
Unauthenticated browser is redirected to Authentik
Authenticated request reaches Checkmk
Checkmk local cmkadmin login remains available as break-glass
operations-stack Argo CD application is Synced/Healthy
/srv/observability/data/checkmk is the only CH05 persistent data path
```


## CH05.8D graph_recipe diagnostic and fix

The service graph UI error was investigated through the diagnostic-only workflow:

```text
05.8D - Diagnose Checkmk Graph Rendering
```

Observed symptom:

```text
Loading graph failed: (Status: 1)
'graph_recipe'
```

The diagnostic artifact showed Checkmk graph AJAX requests failing because the auth-shim stripped `Content-Type` from JSON POST requests. The fix explicitly preserves `Content-Type` while keeping broad request-header stripping.


## CH05.8 - Configure Checkmk Operations Dashboards

Run after the graph Content-Type fix and stable CH05.5/05.7/05.6/05.4 checkpoint.

```text
00 - Build Platform Artifacts
05.8 - Configure Checkmk Operations Dashboards
```

This workflow sets the PlatformInit Alert Manager start page to Checkmk's built-in Host & service problems dashboard (`dashboard.py?name=simple_problems&owner=`), validates main/checkmk dashboards plus host/service drill-down routes, and applies a targeted noise policy for transient k3s/containerd overlay rootfs filesystem services. It does not change the Checkmk runtime deployment or native service discovery beyond reconciling discovery after the disabled-service rule is written.

## CH05.8D dashboard/session/CSRF diagnostics

If Checkmk dashboards render an empty selector/spinner or UI saves fail with `Invalid CSRF token`, run:

```text
05.8D - Diagnose Checkmk Graph Rendering
```

The workflow now collects direct-backend versus auth-shim dashboard probes, candidate AJAX references, session cookie continuity and CSRF/token markers without performing any save action. Use the artifact before changing the auth-shim cookie/session policy.


### Session / CSRF note

Checkmk trusted-header SSO still requires normal Checkmk WebUI session cookies for dashboard AJAX and CSRF-protected WATO form submissions. The auth-shim keeps `proxy_pass_request_headers off`, but explicitly preserves `Cookie`, `Accept`, `X-Requested-With`, `Referer`, `Origin`, and `Content-Type` while continuing to strip `Authorization` and unlisted request headers. CH05.3 owns the `auth_by_http_header = 'X-Remote-User'` setting in `global.mk`.


## CH05.8B - Clean Checkmk Alert Noise

Run after CH05.8 if the Alert Manager dashboard is working but still contains known non-actionable bootstrap/discovery noise.

```text
00 - Build Platform Artifacts
05.8B - Clean Checkmk Alert Noise
```

Expected effects:

- stale failed states for configured systemd units are reset on the host;
- Checkmk cache is refreshed from the deterministic TCP agent path;
- service discovery is fully reconciled from cache;
- transient k3s/containerd rootfs filesystem services remain ignored;
- `Check_MK Discovery` should no longer appear as a WARN/CRIT/UNKNOWN problem;
- if `cloud-init-hotplugd.service` or `dailyaidecheck.service` still fails immediately, the workflow fails and provides systemd/journal context.

Do not use CH05.8B to hide real failures. It is a cleanup/reconcile layer after the Alert Manager dashboard is functional.


## CH05 workflow UX consolidation

After the Checkmk Alert Manager checkpoint, CH05 is operated through two workflows:

```text
05 - Operations Monitoring
05.D - Operations Diagnostics
```

Use `05 - Operations Monitoring` with `action=full_reconcile` for a complete CH05 reconciliation. Use individual actions only for targeted recovery. Use `05.D - Operations Diagnostics` for agent-discovery or graph/dashboard/session diagnostic bundles.

The former granular implementation workflow files were removed from `.github/workflows/` so they no longer appear in the GitHub Actions sidebar. Their behavior is now available through the consolidated workflow action inputs.
